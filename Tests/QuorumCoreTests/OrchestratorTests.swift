import XCTest
@testable import QuorumCore

final class OrchestratorTests: XCTestCase {

    /// The primary suite: a multi-topic run exercising complete / spend-wall / inconclusive /
    /// budget-skip in one run, asserting the report, the filed notes, and the run totals.
    func testMultiTopicRun() async throws {
        let project = try makeTempProject()
        let clock = TestClock(now: fixedStart)
        let config = standardRun(project: project, runCap: 100,
                                   perTopicCap: Decimal(string: "0.50")!, timeout: .seconds(300),
                                   deadline: fixedStart.addingTimeInterval(100), preset: .standard)
        let topics = [
            Topic(id: "t1", question: "Rust async runtimes compared"),
            Topic(id: "t2", question: "SQLite write-ahead logging internals"),
            Topic(id: "t3", question: "Kubernetes pod eviction policies"),
            Topic(id: "t4", question: "GraphQL schema federation patterns"),
        ]
        let exec = FakeExecutor([
            "t1": FakeExecutor.completing(),
            "t2": FakeExecutor.spendWall(cost: Decimal(string: "0.60")!),
            // t3 pushes the clock past the run time budget so t4 can't start
            "t3": FakeExecutor.inconclusive(advance: clock, by: .seconds(200)),
        ])
        let power = SpyPower(), notifier = SpyNotifier(), store = DiskFindingsStore()

        let report = await runBatch(config: config, topics: topics, executor: exec,
                                    clock: clock, store: store, power: power, notifier: notifier)

        // --- per-topic outcomes ---
        XCTAssertEqual(report.entries.count, 4)
        XCTAssertEqual(report.entries[0].status, .complete)
        XCTAssertEqual(report.entries[1].status, .haltedSpend)
        XCTAssertEqual(report.entries[2].status, .inconclusive)
        XCTAssertEqual(report.entries[3].status, .skipped)

        // topic 1 came back with verified citations and filed a fresh note
        XCTAssertTrue(report.entries[0].confidenceSummary.contains("high"))
        XCTAssertEqual(report.entries[0].noteAction, .created)
        XCTAssertNotNil(report.entries[0].notePath)
        // topic 2 halted but still handed back flagged partial findings (and still filed them)
        XCTAssertEqual(report.entries[1].headline, "Partial before spend halt")
        XCTAssertEqual(report.entries[1].sourcesConsulted, 3)
        XCTAssertNotNil(report.entries[1].note)
        // topic 4 skipped, not run, not filed
        XCTAssertNil(report.entries[3].notePath)
        XCTAssertNil(report.entries[3].noteAction)

        // --- run totals stayed under the cap ---
        XCTAssertLessThanOrEqual(report.totalCostUSD, config.runSpendCapUSD)
        XCTAssertTrue(report.stayedUnderCap)
        // 0.10 (t1) + 0.60 (t2) + 0.05 (t3)
        XCTAssertEqual(report.totalCostUSD, Decimal(string: "0.75")!)

        // --- files: 3 notes filed in the brain; per-run digest + transcripts in the run dir; t4 not filed ---
        let runs = store.listRuns(projectURL: project)
        XCTAssertEqual(runs.count, 1)
        let runFiles = try FileManager.default.contentsOfDirectory(atPath: runs[0].path)
        XCTAssertTrue(runFiles.contains("digest.md"))
        XCTAssertEqual(runFiles.filter { $0.hasSuffix(".transcript.md") }.count, 3, "one transcript per topic that ran")

        let notes = try noteFiles(in: project)
        XCTAssertEqual(notes.count, 3, "one note per topic that ran (t1, t2, t3); t4 was skipped")

        // --- power asserted then released; one notification ---
        XCTAssertEqual(power.prevented, 1)
        XCTAssertEqual(power.allowed, 1)
        XCTAssertEqual(notifier.count, 1)
    }

    /// The moat, end-to-end: re-running a near-duplicate topic *extends* the same note instead of
    /// duplicating it (stories 30–31). One note on disk, second entry reports `.extended`.
    func testCompoundingExtendsExistingNoteAcrossRuns() async throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        func run(_ q: String, id: String, at t: TimeInterval) async -> RunReport {
            await runBatch(config: standardRun(project: project, deadline: nil),
                           topics: [Topic(id: id, question: q)], executor: FakeExecutor([:]),
                           clock: TestClock(now: fixedStart.addingTimeInterval(t)),
                           store: store, power: SpyPower(), notifier: SpyNotifier())
        }

        let first = await run("Postgres index types and when to use them", id: "r1", at: 0)
        XCTAssertEqual(first.entries[0].noteAction, .created)
        XCTAssertEqual(try noteFiles(in: project).count, 1)

        // A clearly-overlapping follow-up a day later → extend, not a second file.
        let second = await run("Postgres index types performance tradeoffs", id: "r2", at: 86_400)
        XCTAssertEqual(second.entries[0].noteAction, .extended)
        XCTAssertEqual(try noteFiles(in: project).count, 1, "the topic deepened into ONE note, not two")

        // The single note now carries two dated sections and bumped its run count.
        let noteText = try String(contentsOf: try XCTUnwrap(noteFiles(in: project).first), encoding: .utf8)
        let datedSections = noteText.split(separator: "\n").filter { $0.hasPrefix("## ") && $0.contains("—") }
        XCTAssertEqual(datedSections.count, 2, "two dated sections")
        XCTAssertTrue(noteText.contains("runs: 2"))
    }

    /// Run spend cap halts the running topic AND stops the queue; the rest become skipped.
    func testRunCapStopsTheWholeRun() async throws {
        let project = try makeTempProject()
        let clock = TestClock(now: fixedStart)
        let config = standardRun(project: project, runCap: Decimal(string: "1.00")!,
                                   perTopicCap: Decimal(string: "5.00")!, // high, so only the run cap can trip
                                   timeout: .seconds(300), deadline: nil, preset: .draft)
        let topics = [Topic(id: "a", question: "A"), Topic(id: "b", question: "B"), Topic(id: "c", question: "C")]
        let exec = FakeExecutor([
            "a": FakeExecutor.completing(cost: Decimal(string: "0.50")!),
            "b": FakeExecutor.spendWall(cost: Decimal(string: "0.80")!), // 0.50 + 0.80 crosses the 1.00 run cap
        ])
        let report = await runBatch(config: config, topics: topics, executor: exec, clock: clock,
                                    store: DiskFindingsStore(), power: SpyPower(), notifier: SpyNotifier())

        XCTAssertEqual(report.entries[0].status, .complete)
        XCTAssertEqual(report.entries[1].status, .haltedSpend)
        XCTAssertEqual(report.entries[2].status, .skipped)
        XCTAssertEqual(report.entries[1].note, "hit the run spend cap — findings incomplete")
    }

    /// Manual Stop (cancelling the run Task): the in-flight topic hands back a partial, the rest skip.
    func testManualStopKeepsPartialAndSkipsRest() async throws {
        let project = try makeTempProject()
        let clock = TestClock(now: fixedStart)
        let config = standardRun(project: project, deadline: nil)
        let signal = Signal()
        let topics = [Topic(id: "run", question: "In flight"), Topic(id: "next", question: "Never starts")]
        let exec = FakeExecutor(["run": FakeExecutor.parksAfterSignaling(signal)])
        let store = DiskFindingsStore()

        let task = Task {
            await runBatch(config: config, topics: topics, executor: exec, clock: clock,
                           store: store, power: SpyPower(), notifier: SpyNotifier())
        }
        await signal.wait()   // topic 1 is now running and parked
        task.cancel()         // pull the cord manually
        let report = await task.value

        XCTAssertEqual(report.entries[0].status, .haltedManual)
        XCTAssertEqual(report.entries[0].headline, "Work in progress")   // partial preserved
        XCTAssertEqual(report.entries[1].status, .skipped)
        XCTAssertEqual(report.entries[1].note, "stopped manually before this topic ran")

        // a partial digest still landed on disk (story 51)
        let runs = store.listRuns(projectURL: project)
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: runs[0].path).contains("digest.md"))
    }

    /// No run time budget (a plain "Run Now") → nothing is skipped.
    func testRunNowNoDeadlineRunsEverything() async throws {
        let project = try makeTempProject()
        let clock = TestClock(now: fixedStart)
        let config = standardRun(project: project, deadline: nil)
        let topics = [Topic(id: "x", question: "X"), Topic(id: "y", question: "Y")]
        let report = await runBatch(config: config, topics: topics,
                                    executor: FakeExecutor([:]), clock: clock,
                                    store: DiskFindingsStore(), power: SpyPower(), notifier: SpyNotifier())
        XCTAssertEqual(report.entries.map(\.status), [.complete, .complete])
    }

    // MARK: helpers

    private func noteFiles(in brain: URL) throws -> [URL] {
        let dir = brain.appendingPathComponent("Quorum/notes")
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
    }
}

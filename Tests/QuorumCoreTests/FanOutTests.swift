import XCTest
@testable import QuorumCore

/// The fan-out contract: plan N angles → research them BLIND and in parallel → one summariser that
/// sees all → one durable note. All offline via the fakes, deterministic, no spend.
final class FanOutTests: XCTestCase {

    private func angles(_ n: Int) -> [ResearchAngle] {
        (1...n).map { ResearchAngle(id: "angle-\($0)", title: "T\($0)", prompt: "angle prompt \($0)") }
    }

    private func brainNoteFiles(in project: URL) -> [URL] {
        let notes = project.appendingPathComponent("Quorum/notes")
        return ((try? FileManager.default.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
    }

    // MARK: planning

    func testPlanAnglesReturnsRequestedCount() async throws {
        let project = try makeTempProject()
        let planner = FakeAnglePlanner(angles(5))
        let result = try await planAngles(question: "How does X work?", count: 5,
                                          config: standardRun(project: project), planner: planner,
                                          store: DiskFindingsStore(), clock: TestClock(now: fixedStart))
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(planner.calls, 1)
    }

    // MARK: fan-out + synthesis

    func testFanOutRunsAllAnglesThenSynthesizesOneNote() async throws {
        let project = try makeTempProject()
        let exec = RecordingExecutor()
        let store = DiskFindingsStore()
        let report = await runFanOut(question: "How does X work?", angles: angles(5),
                                     config: standardRun(project: project), executor: exec,
                                     clock: TestClock(now: fixedStart), store: store,
                                     power: SpyPower(), notifier: SpyNotifier())

        XCTAssertEqual(exec.researchTopics.count, 5, "all five angles ran (parallel fan-out)")
        XCTAssertNotNil(exec.synthesisTopic, "exactly one summariser ran")
        XCTAssertEqual(report.entries.count, 6, "1 synthesis + 5 angle entries")

        let synth = report.entries[0]
        XCTAssertNotNil(synth.notePath)
        XCTAssertEqual(synth.isSynthesis, true, "first entry is flagged as the synthesis")
        XCTAssertEqual(synth.noteAction, .created, "brand-new question → one created note")
        XCTAssertEqual(brainNoteFiles(in: project).count, 1, "one durable note, not five")

        // Each angle entry points at its writeup artifact, so it opens as a readable note (not just chat).
        let angleEntries = Array(report.entries.dropFirst())
        XCTAssertTrue(angleEntries.allSatisfy { $0.notePath != nil }, "angles are openable")
        XCTAssertTrue(angleEntries.allSatisfy { $0.isSynthesis != true })

        // Five angle writeups saved as run artifacts.
        let runDir = store.listRuns(projectURL: project).first!
        let artifacts = ((try? FileManager.default.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.contains("-angle-") }
        XCTAssertEqual(artifacts.count, 5)
    }

    func testAnglesAreBlindToEachOtherButSynthesisSeesAll() async throws {
        let project = try makeTempProject()
        let exec = RecordingExecutor()
        _ = await runFanOut(question: "Q", angles: angles(3), config: standardRun(project: project),
                            executor: exec, clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                            power: SpyPower(), notifier: SpyNotifier())

        // Isolation: each angle's prompt/context contains ONLY its own prompt, never a sibling's.
        let research = exec.researchTopics
        for t in research {
            for other in research where other.id != t.id {
                XCTAssertFalse(t.question.contains(other.question), "\(t.id) leaked sibling \(other.id)")
                XCTAssertFalse((t.context ?? "").contains(other.question), "\(t.id) ctx leaked \(other.id)")
            }
        }
        // The summariser DID see every angle's writeup.
        let ctx = exec.synthesisTopic?.context ?? ""
        for t in research { XCTAssertTrue(ctx.contains(t.question), "synthesis missing \(t.id)") }
    }

    func testCompoundingMergesSecondFanOutIntoExistingNote() async throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        func once(at t: TimeInterval) async -> RunReport {
            await runFanOut(question: "How does Postgres indexing work?", angles: angles(3),
                            config: standardRun(project: project), executor: RecordingExecutor(),
                            clock: TestClock(now: fixedStart.addingTimeInterval(t)), store: store,
                            power: SpyPower(), notifier: SpyNotifier())
        }
        let first = await once(at: 0)
        XCTAssertEqual(first.entries[0].noteAction, .created)
        let second = await once(at: 86_400)
        XCTAssertEqual(second.entries[0].noteAction, .merged, "same question → reconcile into the note")
        XCTAssertEqual(brainNoteFiles(in: project).count, 1, "deepened into ONE note, not duplicated")
    }

    // MARK: research templates (item 8 — a preset that shapes the synthesis deliverable)

    func testTemplateShapesSynthesisPromptButDefaultDoesNot() async throws {
        let project = try makeTempProject()

        // A template's deliverable instructions reach ONLY the summariser, not the blind angles.
        var matrix = standardRun(project: project); matrix.synthesisTemplate = .comparisonMatrix
        let e1 = RecordingExecutor()
        _ = await runFanOut(question: "Q", angles: angles(3), config: matrix, executor: e1,
                            clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                            power: SpyPower(), notifier: SpyNotifier())
        XCTAssertTrue((e1.synthesisTopic?.context ?? "").contains("COMPARISON MATRIX"),
                      "synthesis is steered toward the chosen deliverable")
        XCTAssertTrue(e1.researchTopics.allSatisfy { !($0.context ?? "").contains("COMPARISON MATRIX") },
                      "the template shapes synthesis only — angles are unaffected (same engine)")

        // Default (nil template) → no deliverable shaping injected.
        let e2 = RecordingExecutor()
        _ = await runFanOut(question: "Q", angles: angles(3), config: standardRun(project: project),
                            executor: e2, clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                            power: SpyPower(), notifier: SpyNotifier())
        let ctx = e2.synthesisTopic?.context ?? ""
        XCTAssertFalse(ctx.contains("COMPARISON MATRIX"))
        XCTAssertFalse(ctx.contains("DECISION BRIEF"))
        XCTAssertFalse(ctx.contains("LITERATURE REVIEW"))
    }

    // MARK: walls

    func testRunCapClampsEachAngleBudget() async throws {
        // runCap $6 across 3 angles + 1 synthesis = 4 slices → each ≤ $1.50, below the user's $2 cap.
        let project = try makeTempProject()
        let exec = RecordingExecutor()
        _ = await runFanOut(question: "Q", angles: angles(3),
                            config: standardRun(project: project, runCap: 6, perTopicCap: 2),
                            executor: exec, clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                            power: SpyPower(), notifier: SpyNotifier())
        for t in exec.researchTopics {
            XCTAssertEqual(t.runConfig.perTopicSpendCapUSD, Decimal(string: "1.5")!)
        }
    }

    func testManualStopHaltsInFlightAngles() async throws {
        let project = try makeTempProject()
        let signal = Signal()
        let exec = ParkingExecutor(signal)
        let task = Task {
            await runFanOut(question: "Q", angles: angles(3), config: standardRun(project: project),
                            executor: exec, clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                            power: SpyPower(), notifier: SpyNotifier())
        }
        await signal.wait()      // at least one angle is running
        task.cancel()            // user pressed Stop
        let report = await task.value
        XCTAssertEqual(report.entries.count, 4)
        let angleEntries = Array(report.entries.dropFirst())   // entry[0] is the synthesis
        XCTAssertTrue(angleEntries.allSatisfy { $0.status == .haltedManual },
                      "in-flight angles hand back a manual-stop partial")
    }

    // MARK: iterative fan-out (round 2+ on unresolved conflicts + gaps)

    func testIterativeStopsWhenDryAndResearchesTheFollowUps() async throws {
        let project = try makeTempProject()
        let exec = IterativeExecutor(roundsWithWork: 1)   // round 1 leaves work; round 2 comes back clean
        let reports = await runIterativeFanOut(question: "How does X work?", angles: angles(2),
                                               config: standardRun(project: project), executor: exec,
                                               clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                                               power: SpyPower(), notifier: SpyNotifier(), maxRounds: 5)
        XCTAssertEqual(reports.count, 2, "one follow-up round, then dry (nothing new) → stop")
        // Round 2 actually researched the conflict + gap round 1 surfaced.
        XCTAssertTrue(exec.researchPrompts.contains { $0.contains("disputed point 1") }, "conflict fed back as an angle")
        XCTAssertTrue(exec.researchPrompts.contains { $0.contains("open question 1") }, "gap fed back as an angle")
    }

    func testIterativeWritesOneMergedRoundTaggedReport() async throws {
        // The whole dive shares ONE run dir → one History row, whose report.json spans all rounds with
        // each entry tagged by the round that produced it (what the History fan diagram reads).
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let dir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        _ = await runIterativeFanOut(question: "Q", angles: angles(2),
                                     config: standardRun(project: project), executor: IterativeExecutor(roundsWithWork: 1),
                                     clock: TestClock(now: fixedStart), store: store, power: SpyPower(),
                                     notifier: SpyNotifier(), maxRounds: 5, runDir: dir)
        XCTAssertEqual(store.listRuns(projectURL: project).count, 1, "one History row for the whole multi-round dive")
        let data = try Data(contentsOf: dir.appendingPathComponent("report.json"))
        let report = try JSONDecoder().decode(RunReport.self, from: data)
        XCTAssertEqual(Set(report.entries.compactMap(\.round)), [1, 2], "entries tagged by their round")
        XCTAssertEqual(report.entries.filter { $0.isSynthesis == true }.count, 2, "one synthesis per round in the merged report")
    }

    func testIterativeSingleRoundWhenNothingUnresolved() async throws {
        let project = try makeTempProject()
        let exec = IterativeExecutor(roundsWithWork: 0)   // clean synthesis immediately
        let reports = await runIterativeFanOut(question: "Q", angles: angles(3),
                                               config: standardRun(project: project), executor: exec,
                                               clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                                               power: SpyPower(), notifier: SpyNotifier(), maxRounds: 5)
        XCTAssertEqual(reports.count, 1, "no conflicts/gaps → converged after one round")
    }

    func testIterativeRespectsMaxRoundsBackstop() async throws {
        let project = try makeTempProject()
        let exec = IterativeExecutor(roundsWithWork: 99)  // never converges on its own
        let reports = await runIterativeFanOut(question: "Q", angles: angles(2),
                                               config: standardRun(project: project, runCap: 100), executor: exec,
                                               clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                                               power: SpyPower(), notifier: SpyNotifier(), maxRounds: 3)
        XCTAssertEqual(reports.count, 3, "hard round cap stops a non-converging dive")
    }

    func testIterativeTotalSpendNeverExceedsTheOneRunCap() async throws {
        // runCap $1.00, per-round ≈ 2·$0.10 + $0.05 = $0.25. Rounds keep coming (roundsWithWork high) but
        // the SHARED cap is the wall: it stops once <$0.50 (a topic's worth) is left. Σ must stay ≤ cap.
        let project = try makeTempProject()
        let exec = IterativeExecutor(roundsWithWork: 99)
        let cap = Decimal(1)
        let reports = await runIterativeFanOut(question: "Q", angles: angles(2),
                                               config: standardRun(project: project, runCap: cap, perTopicCap: Decimal(string: "0.50")!),
                                               executor: exec, clock: TestClock(now: fixedStart),
                                               store: DiskFindingsStore(), power: SpyPower(), notifier: SpyNotifier(),
                                               maxRounds: 10)
        let total = reports.reduce(Decimal(0)) { $0 + $1.totalCostUSD }
        XCTAssertLessThanOrEqual(total, cap, "the run cap is one wall across ALL rounds")
        XCTAssertLessThan(reports.count, 10, "budget wall stopped it before the round backstop")
    }

    func testIterativeFiresExactlyOneFinishedNotification() async throws {
        let project = try makeTempProject()
        let notifier = SpyNotifier()
        _ = await runIterativeFanOut(question: "Q", angles: angles(2),
                                     config: standardRun(project: project), executor: IterativeExecutor(roundsWithWork: 2),
                                     clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                                     power: SpyPower(), notifier: notifier, maxRounds: 5)
        XCTAssertEqual(notifier.count, 1, "one dive → one ping, not one per round")
    }

    func testFollowUpAnglesMapConflictsAndGaps() {
        let out = followUpAngles(conflicts: [Conflict(claim: "X vs Y", positions: ["a: X", "b: Y"])],
                                 gaps: ["what about Z?"], alreadyAsked: [], limit: 5)
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out[0].prompt.contains("X vs Y") && out[0].prompt.contains("a: X"))
        XCTAssertTrue(out[1].prompt.contains("what about Z?"))
    }

    func testFollowUpAnglesDedupAgainstPriorRoundsAndCap() {
        let c = [Conflict(claim: "c1", positions: ["p"]), Conflict(claim: "c2", positions: ["p"])]
        let first = followUpAngles(conflicts: c, gaps: [], alreadyAsked: [], limit: 5)
        let asked = Set(first.map { normalizeSource($0.prompt) })
        let again = followUpAngles(conflicts: c, gaps: ["g1", "g2", "g3"], alreadyAsked: asked, limit: 2)
        XCTAssertTrue(again.allSatisfy { !asked.contains(normalizeSource($0.prompt)) }, "repeat conflicts dropped")
        XCTAssertEqual(again.count, 2, "capped to the limit")
    }

    func testParseGapsFromSynthesisJSON() {
        let text = "prose\n```json\n{\"headline\":\"h\",\"status\":\"complete\",\"findings\":[],\"gaps\":[\"q1\",\"  \",\"q2\"]}\n```"
        XCTAssertEqual(ResearchOutputParser.parseFinal(text).gaps, ["q1", "q2"], "gaps parsed; blanks dropped")
    }

    // MARK: backward compatibility

    func testOldReportWithoutIsSynthesisStillDecodes() throws {
        // A report.json written before `isSynthesis` existed must still load — don't break run history.
        let json = """
        {"startedAt":0,"finishedAt":1,"totalCostUSD":0,"runSpendCapUSD":20,
         "entries":[{"id":"a","question":"q","status":"complete","preset":"standard","headline":"h",
         "confidenceSummary":"1 high","sourcesConsulted":3,"costUSD":0.1,"durationSeconds":5,
         "notePath":null,"transcriptPath":null}]}
        """
        let report = try JSONDecoder().decode(RunReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertNil(report.entries[0].isSynthesis, "absent flag decodes as nil, not a failure")
    }

    // MARK: parser

    func testParseAnglesWellFormed() {
        let text = "prose\n```json\n[{\"title\":\"A\",\"prompt\":\"pa\"},{\"title\":\"B\",\"prompt\":\"pb\"}]\n```"
        let a = ResearchOutputParser.parseAngles(text)
        XCTAssertEqual(a.map(\.title), ["A", "B"])
        XCTAssertEqual(a.map(\.prompt), ["pa", "pb"])
    }

    func testParseAnglesForgivingFieldNames() {
        let a = ResearchOutputParser.parseAngles("```json\n[{\"name\":\"N\",\"question\":\"q1\"}]\n```")
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].title, "N")
        XCTAssertEqual(a[0].prompt, "q1")
    }

    func testParseAnglesMalformedIsEmptyNeverCrashes() {
        XCTAssertTrue(ResearchOutputParser.parseAngles("no json here").isEmpty)
        XCTAssertTrue(ResearchOutputParser.parseAngles("```json\n{not valid}\n```").isEmpty)
        XCTAssertTrue(ResearchOutputParser.parseAngles("```json\n[{\"title\":\"only\"}]\n```").isEmpty,
                      "an angle with no prompt is dropped")
    }
}

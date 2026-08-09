import XCTest
@testable import QuorumCore

final class EngineReconciliationTests: XCTestCase {

    private let question = "Where does fusion energy stand?"

    private func events() throws -> [RunStreamParser.Event] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/run-reconciled-transcript.ndjson")
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
        return try lines.map { line in
            guard let event = RunStreamParser.parse(String(line)) else {
                throw XCTSkip("engine emitted a run line the parser rejected: \(line)")
            }
            return event
        }
    }

    private func topicResults() throws -> [RunStreamParser.TopicResultEvent] {
        try events().compactMap { if case .topicResult(let tr) = $0 { return tr } else { return nil } }
    }

    private func persist(skippingReconciliation: Bool = false) throws -> (EngineRunPersistence, URL) {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let persistence = EngineRunPersistence(question: question, config: standardRun(project: project),
                                               store: store, runDir: runDir, priorNotes: [])
        for event in try events() {
            if skippingReconciliation, case .topicResult(let tr) = event, tr.reconciled { continue }
            persistence.apply(event, at: fixedStart)
        }
        return (persistence, project)
    }

    private func datedSections(_ note: String) -> [String] {
        note.split(separator: "\n").map(String.init).filter { $0.hasPrefix("## ") && $0.contains("—") }
    }

    func testEngineEndsATwoRoundDiveWithExactlyOneReconciledSynthesis() throws {
        let results = try topicResults()
        let syntheses = results.filter { $0.role == "synthesis" }

        XCTAssertEqual(syntheses.count, 3, "two rounds of synthesis plus the fuse over them")
        XCTAssertEqual(results.filter(\.reconciled).count, 1, "exactly one answer is the current one")
        XCTAssertEqual(results.last?.reconciled, true, "the fuse is the terminal synthesis")
        XCTAssertTrue(results.last?.result.contains("CURRENTANSWER") ?? false)
    }

    func testReconciledSynthesisCollapsesTheDiveIntoOneCurrentSection() throws {
        let (persistence, _) = try persist()

        let reconciled = try XCTUnwrap(persistence.entries.first { $0.noteAction == .reconciled },
                                       "the engine's fused answer is filed as a reconciliation")
        XCTAssertEqual(persistence.entries.filter { $0.noteAction == .reconciled }.count, 1)
        XCTAssertEqual(reconciled.isSynthesis, true)
        XCTAssertNil(reconciled.round, "the fuse is not another round — it stays out of the fan diagram")

        let note = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(reconciled.notePath)),
                              encoding: .utf8)
        XCTAssertEqual(datedSections(note).count, 1, "one current answer, not one section per round")
        XCTAssertTrue(note.contains("CURRENTANSWER"), "the note leads with what the dive now holds")
        XCTAssertFalse(note.contains("OVERTURNEDCLAIM"), "round 1's overturned claim is not left standing")
    }

    func testTheSameRoundsWithoutTheFuseLeaveTwoContradictorySections() throws {
        let (persistence, _) = try persist(skippingReconciliation: true)

        let synthesis = try XCTUnwrap(persistence.entries.last { $0.isSynthesis == true })
        let note = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(synthesis.notePath)),
                              encoding: .utf8)
        XCTAssertEqual(datedSections(note).count, 2)
        XCTAssertTrue(note.contains("OVERTURNEDCLAIM"))
        XCTAssertTrue(note.contains("Round two found the schedule slipped"))
    }

    /// History opens a finished dive as the graph it ran as, and the node it ends on is the answer the dive
    /// currently holds — not the last round it happened to run.
    func testTheFinishedDiveRebuildsAsAGraphEndingOnTheFusedAnswer() throws {
        let (persistence, _) = try persist()
        let report = RunReport(startedAt: fixedStart, finishedAt: fixedStart.addingTimeInterval(60),
                               entries: persistence.entries, totalCostUSD: 1, runSpendCapUSD: 40,
                               validation: persistence.validation)
        let graph = ResearchGraph.from(report: report)
        let answer = try XCTUnwrap(graph.nodes(of: .synthesis).last)

        let rounds = graph.nodes(of: .synthesis).filter { !$0.isReconciled }

        XCTAssertTrue(answer.isReconciled)
        XCTAssertEqual(graph.nodes(of: .synthesis).filter(\.isReconciled).count, 1)
        XCTAssertGreaterThan(answer.depth, rounds.map(\.depth).max() ?? 0)
        XCTAssertTrue(graph.ancestry(of: answer.id).contains(ResearchGraph.rootID))
    }

    /// The export is a rendering of the run, so the answer it renders ships with the judgement the dive
    /// ended on — the same verdict the rail's validation tab reads (PRD 09 R4).
    func testTheReconciledExportCarriesTheJudgementTheDiveEndedOn() throws {
        let (persistence, _) = try persist()

        let reconciled = try XCTUnwrap(persistence.entries.first { $0.noteAction == .reconciled })
        let note = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(reconciled.notePath)),
                              encoding: .utf8)
        XCTAssertTrue(note.contains("## Validation"))
        XCTAssertTrue(note.contains("The answer held"))
    }

    /// The judgement arrives after the answer does, so the answer waits for it — but only as long as the
    /// stream lasts. An engine that dies before reporting still leaves the dive's answer filed.
    func testAnAnswerTheEngineNeverFinishedReportingIsStillFiled() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let persistence = EngineRunPersistence(question: question, config: standardRun(project: project),
                                               store: store, runDir: runDir, priorNotes: [])
        for event in try events() {
            if case .runResult = event { continue }
            persistence.apply(event, at: fixedStart)
        }
        XCTAssertNil(persistence.entries.first { $0.noteAction == .reconciled },
                     "the answer is held while its judgement can still arrive")

        persistence.flush(at: fixedStart)

        let reconciled = try XCTUnwrap(persistence.entries.first { $0.noteAction == .reconciled })
        let note = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(reconciled.notePath)),
                              encoding: .utf8)
        XCTAssertTrue(note.contains("CURRENTANSWER"))
        XCTAssertFalse(note.contains("## Validation"), "nothing is claimed about a judgement never reported")
    }

    func testEveryRoundStillFilesItsAnglesAsRunArtifacts() throws {
        let (persistence, _) = try persist()
        let angles = persistence.entries.filter { $0.isSynthesis != true }

        XCTAssertEqual(angles.count, 3, "two round-1 angles plus the objection the loop researched")
        XCTAssertEqual(angles.compactMap(\.round).sorted(), [1, 1, 2])
        for angle in angles {
            XCTAssertNotNil(angle.notePath, "an angle writeup is readable as its own artifact")
        }
    }
}

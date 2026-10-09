import XCTest
@testable import QuorumCore

final class StoredRunTests: XCTestCase {

    private let questionJSON = """
    {"schema":"quorum.question/1","id":"Q1","created_at":"2026-10-09T10:00:00.000Z",
     "original_text":"Does prompt caching pay for a chat product?","resolved_text":"Does prompt caching pay for a chat product?",
     "language":"en","title":"Does prompt caching pay for a chat product","title_source":"question","run_ids":["R1"]}
    """

    private func brain(withRecord fixture: String = "mock-run.run.json", question: String? = nil,
                       runID: String = "R1", questionID: String = "Q1") throws -> (brain: URL, runDir: URL) {
        let brain = try makeTempProject()
        let questionDir = brain.appendingPathComponent("questions/\(questionID)", isDirectory: true)
        let runDir = questionDir.appendingPathComponent("runs/\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try Data(contentsOf: EngineFixtures.url("record/\(fixture)")).write(to: runDir.appendingPathComponent("run.json"))
        try Data((question ?? questionJSON).utf8).write(to: questionDir.appendingPathComponent("question.json"))
        return (brain, runDir)
    }

    private func mockRun() throws -> StoredRun {
        try XCTUnwrap(StoredRun.load(brain().runDir))
    }

    func testARunIsReadFromItsRecordAndTitledByItsQuestion() throws {
        let run = try mockRun()
        XCTAssertEqual(run.title, "Does prompt caching pay for a chat product")
        XCTAssertEqual(run.record.status, .inconclusive)
        XCTAssertEqual(run.answerTask?.id, "reconciliation")
    }

    func testARunWithoutItsQuestionFileIsTitledByItsBrief() throws {
        let (_, runDir) = try brain()
        try FileManager.default.removeItem(at: runDir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("question.json"))
        XCTAssertEqual(StoredRun.load(runDir)?.title, "Does prompt caching pay for a chat product?")
    }

    func testARecordOfAnotherSchemaIsNotReadAsThisOne() throws {
        let (_, runDir) = try brain()
        let url = runDir.appendingPathComponent("run.json")
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "quorum.run/1", with: "quorum.run/2")
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(StoredRun.load(runDir))
    }

    func testTheBrainFolderListsEveryRunNewestFirst() throws {
        let (brain, _) = try brain()
        let later = try String(contentsOf: EngineFixtures.url("record/validated.run.json"), encoding: .utf8)
            .replacingOccurrences(of: "2026-10-09T10:00:00.000Z", with: "2026-10-09T11:00:00.000Z")
        let runDir = brain.appendingPathComponent("questions/Q2/runs/R2", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try later.write(to: runDir.appendingPathComponent("run.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(BrainFolder.runs(in: brain).map(\.runDir.lastPathComponent), ["R2", "R1"])
    }

    func testAnEmptyOrMissingBrainFolderListsNothing() throws {
        XCTAssertEqual(BrainFolder.runs(in: try makeTempProject().appendingPathComponent("nowhere")), [])
    }

    func testTheBrainFolderDefaultsOutsideAnyCodeRepoAndHonoursAChosenOne() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertEqual(BrainFolder.location(stored: nil, home: home).path, "/Users/someone/Quorum")
        XCTAssertEqual(BrainFolder.location(stored: "  ", home: home).path, "/Users/someone/Quorum")
        XCTAssertEqual(BrainFolder.location(stored: "/Volumes/notes/brain", home: home).path, "/Volumes/notes/brain")
    }

    func testTheCanvasIsTheOrchestratorsOwnGraph() throws {
        let graph = try mockRun().graph
        XCTAssertEqual(graph.node(ResearchGraph.rootID)?.kind, .question)
        XCTAssertEqual(graph.nodes(of: .synthesis).map(\.id), ["synthesis", "reconciliation"])
        XCTAssertEqual(graph.answer?.id, "reconciliation")
        XCTAssertEqual(graph.node("a3")?.state, .worked(.error))
        XCTAssertEqual(graph.node("v3_coverage")?.state, .derived)
        XCTAssertEqual(graph.node("v1_coverage")?.state, .judged(objections: 1))
        XCTAssertEqual(graph.nodes(of: .source).count, 7)
        XCTAssertTrue(graph.edges(of: .corroborates).contains { $0.from == "se9e39426" })
    }

    func testANodeReadsTheTaskThatProducedItAndTheAnswerReadsTheAnswer() throws {
        let run = try mockRun()
        XCTAssertEqual(run.task(forNode: "synthesis")?.id, "synthesis.r3")
        XCTAssertEqual(run.task(forNode: "a1")?.kind, .angle)
        XCTAssertEqual(run.writeup(forNode: "reconciliation"), run.record.answer?.markdown)
    }

    func testOnlyTheAnswerWearsTheSweepsVerdictOnItsQuotes() throws {
        let run = try mockRun()
        XCTAssertEqual(run.evidence(forNode: "reconciliation")?.index.tier("a2c1"), .unsupported)
        XCTAssertEqual(run.evidence(forNode: "a2")?.index.tier("a2c1"), .supported)
        XCTAssertEqual(run.evidence(forNode: "a1")?.directory.lastPathComponent, "evidence")
    }

    func testTheValidationTabReadsTheRecordAndTheVerdictNodes() throws {
        let validation = try XCTUnwrap(try mockRun().validation)
        XCTAssertEqual(validation.rounds, 3)
        XCTAssertEqual(validation.objectionsOutstanding.count, 1)
        XCTAssertEqual(validation.byRound.map(\.number), [1, 2, 3])
        XCTAssertEqual(validation.unsupportedCitationIDs, ["a2c1"])
    }

    func testEveryNumberTheHeaderShowsIsTheEnginesStat() throws {
        let run = try mockRun()
        let header = RunHeader(run: run)
        let stats = run.record.stats
        XCTAssertEqual(header.sourcesCited, stats.sourcesCited)
        XCTAssertEqual(header.sourcesRead, stats.sourcesRead)
        XCTAssertEqual(header.sourcesLabel, "5 cited · 5 read")
        XCTAssertEqual(header.conflicts, stats.conflictsOpen)
        XCTAssertEqual(header.gaps, stats.gaps)
        XCTAssertEqual(header.angleCount, stats.tasks)
        XCTAssertEqual(header.rounds, 3)
        XCTAssertEqual(header.costUSD, Decimal(stats.costUSD))
        XCTAssertEqual(header.capUSD, 20)
        XCTAssertTrue(header.stayedUnderCap)
        XCTAssertEqual(header.durationSeconds, stats.durationS)
        XCTAssertEqual(header.trustLevel, .unchecked)
        XCTAssertTrue(header.isReconciled)
        XCTAssertEqual(header.status, .inconclusive)
        XCTAssertEqual(header.claimsSummary, "12 unchecked")
    }

    func testTheHeaderSaysWhenTheEngineStrippedAMarkerOrACheckFailed() throws {
        let run = try mockRun()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run.record)) as? [String: Any])
        var stats = try XCTUnwrap(json["stats"] as? [String: Any])
        stats["stripped_markers"] = 2
        json["stats"] = stats
        json["checks"] = [["id": "references", "name": "n", "status": "fail", "detail": "[^x] in a1 names no citation"]]
        let record = try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: json))
        let header = RunHeader(run: StoredRun(runDir: run.runDir, record: record))
        XCTAssertEqual(header.strippedMarkers, 2)
        XCTAssertEqual(header.failedChecks.map(\.id), ["references"])
    }

    func testTheLiveRailReadsWriteupsAndQuotesOffTheRecordAsItGrows() throws {
        let run = try mockRun()
        var evidence = RunEvidence()
        evidence.apply(.runStart(sessionID: "s", protocolVersion: 4, grounding: .captured, record: nil))
        evidence.absorb(run)
        let answer = try XCTUnwrap(run.graph.node("reconciliation"))
        XCTAssertEqual(evidence.writeup(for: "reconciliation"), run.record.answer?.markdown)
        XCTAssertEqual(evidence.index(for: answer).citations.count, run.record.citations.count)
        XCTAssertEqual(evidence.index(for: answer).documents.count, run.record.sources.count)
    }
}

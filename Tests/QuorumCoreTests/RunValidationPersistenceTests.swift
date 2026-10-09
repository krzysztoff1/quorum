import XCTest
@testable import QuorumCore

/// What a finished run keeps of the loop that judged it. The canvas is the reading surface for a finished
/// run as well as a live one, so the verdicts the run drew have to survive to disk — otherwise the same
/// component would show a validated run as if nobody had ever read its answer.
final class RunValidationPersistenceTests: XCTestCase {

    private func events() throws -> [RunStreamParser.Event] {
        try EngineFixtures.lines("run-validated-transcript.ndjson").compactMap { RunStreamParser.parse($0) }
    }

    private func persisted() throws -> EngineRunPersistence {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let persistence = EngineRunPersistence(question: "Where does fusion energy stand?",
                                               config: standardRun(project: project), store: store,
                                               runDir: runDir, priorNotes: [])
        for event in try events() { persistence.apply(event, at: fixedStart) }
        return persistence
    }

    private func report(_ persistence: EngineRunPersistence) -> RunReport {
        RunReport(startedAt: fixedStart, finishedAt: fixedStart.addingTimeInterval(60),
                  entries: persistence.entries, totalCostUSD: Decimal(string: "0.13")!,
                  runSpendCapUSD: 40, validation: persistence.validation)
    }

    private func liveGraph() throws -> ResearchGraph {
        var graph = ResearchGraph()
        for event in try events() { graph.apply(event) }
        return graph
    }

    func testTheReportKeepsWhatTheValidatorsFiled() throws {
        let validation = try XCTUnwrap(persisted().validation)

        XCTAssertEqual(validation.status, "validated")
        XCTAssertTrue(validation.holds)
        XCTAssertEqual(validation.rounds, 2)
        XCTAssertEqual(validation.spendUSD, Decimal(string: "0.08")!)
        XCTAssertEqual(validation.objectionsAdmitted, 1)
        XCTAssertEqual(validation.objectionsResolved, 1)
        XCTAssertEqual(validation.objectionsOutstanding, [])
    }

    func testTheReportKeepsEveryVerdictTheCanvasDrew() throws {
        let validation = try XCTUnwrap(persisted().validation)

        XCTAssertEqual(validation.verdicts.count, 8, "four validator tasks, two rounds")
        XCTAssertEqual(Set(validation.verdicts.map(\.lens)),
                       ["claim_sweep", "coverage", "conflicts", "sources"])
        XCTAssertEqual(validation.verdicts.filter { $0.round == 2 }.count, 4)
        let objecting = try XCTUnwrap(validation.verdicts.first { !$0.objections.isEmpty })
        XCTAssertEqual(objecting.lens, "coverage")
        XCTAssertEqual(objecting.objections.first?.severity, "blocking")
    }

    /// A rebuilt run and a watched one are the same graph — the verdicts included.
    func testTheRebuiltRunCarriesTheSameVerdictsTheLiveRunDrew() throws {
        let rebuilt = ResearchGraph.from(report: report(try persisted()))
        let live = try liveGraph()

        XCTAssertEqual(rebuilt.nodes(of: .verdict).map(\.id).sorted(),
                       live.nodes(of: .verdict).map(\.id).sorted())
        XCTAssertEqual(rebuilt.nodes(of: .verdict).map(\.state), live.nodes(of: .verdict).map(\.state))
        XCTAssertEqual(rebuilt.edges(of: .judges).count, live.edges(of: .judges).count)
    }

    // MARK: what the rail's validation tab reads (PRD 09 R2)

    func testTheValidationTabReadsAVerdictLedgerRoundByRound() throws {
        let rounds = try XCTUnwrap(persisted().validation).byRound

        XCTAssertEqual(rounds.map(\.number), [1, 2])
        XCTAssertEqual(rounds.map { $0.verdicts.count }, [4, 4])
        XCTAssertEqual(rounds.first?.objections.map(\.lens), ["coverage"])
        XCTAssertFalse(try XCTUnwrap(rounds.first).holds, "the round that filed a blocking objection did not")
        XCTAssertTrue(try XCTUnwrap(rounds.last).holds, "and the round that settled it did")
    }

    /// Resolved and outstanding are the two halves of the same ledger, and both are readable — an objection
    /// the loop could not settle is shipped, not dropped.
    func testTheTabSaysWhatWasSettledAndWhatStillStands() throws {
        let settled = try XCTUnwrap(persisted().validation)
        let standing = RunValidation(status: "unvalidated", holds: false, blocking: 1, spendUSD: 0, rounds: 1,
                                     objectionsAdmitted: 2, objectionsResolved: 1,
                                     objectionsOutstanding: [RunStreamParser.ObjectionEvent(
                                        lens: "sources", statement: "one weak source", severity: "blocking",
                                        followup: "find a second source for the 2025 figure")],
                                     verdicts: [], unsupportedCitationIDs: ["a2c1"])

        XCTAssertEqual(settled.objectionsResolved, 1)
        XCTAssertTrue(settled.objectionsOutstanding.isEmpty)
        XCTAssertEqual(standing.objectionsOutstanding.map(\.statement), ["one weak source"])
        XCTAssertEqual(standing.unsupportedCitationIDs, ["a2c1"])
    }

    /// A run the walls stopped keeps the quotes its claims could not stand on, so the answer it ships is
    /// read with those chips badged rather than with the failure lost between the stream and the disk.
    func testTheQuotesThatFailedTheirClaimSurviveToTheReport() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let persistence = EngineRunPersistence(question: "q", config: standardRun(project: project),
                                               store: store, runDir: runDir, priorNotes: [])
        let line = #"{"type":"run_result","status":"inconclusive","total_cost_usd":0.5,"topics":[],"validation":{"status":"validated","holds":false,"blocking":1,"spend_usd":0.08,"objections_admitted":1,"objections_resolved":0,"objections_outstanding":[],"unsupported_citations":["a2c1"],"rounds":[{"round":1}]}}"#

        persistence.apply(try XCTUnwrap(RunStreamParser.parse(line)), at: fixedStart)

        XCTAssertEqual(persistence.validation?.unsupportedCitationIDs, ["a2c1"])
    }

    /// A round wrote its own verdict into the answer it produced, and that account is the one the export
    /// ships — the store never argues with it by summarising the run over the top (PRD 09 R4).
    func testARoundsExportKeepsTheVerdictTheLoopWroteIntoIt() throws {
        let persistence = try persisted()

        let answer = try XCTUnwrap(persistence.entries.last { $0.isSynthesis == true })
        let note = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(answer.notePath)), encoding: .utf8)
        XCTAssertTrue(note.contains("## Validation"))
        XCTAssertTrue(note.contains("✓ Validated — 1 claim(s) checked"))
        XCTAssertFalse(note.contains("The answer held"), "one verdict per section, written by the loop")
    }

    func testARunWithNoValidatorLoopPersistsNoValidation() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let persistence = EngineRunPersistence(question: "q", config: standardRun(project: project),
                                               store: store, runDir: runDir, priorNotes: [])

        persistence.apply(.runResult(RunStreamParser.RunResultEvent(status: "complete", totalCostUSD: 0,
                                                                    topics: [])), at: fixedStart)

        XCTAssertNil(persistence.validation)
    }
}

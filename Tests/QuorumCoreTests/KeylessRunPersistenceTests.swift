import XCTest
@testable import QuorumCore

final class KeylessRunPersistenceTests: XCTestCase {

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func keylessRun() -> [String] {
        [
            line(["type": "run_start", "session_id": "qrun-keyless", "protocol_version": 4,
                  "grounding": "none"]),
            line(["type": "plan", "angles": [["angle_id": "a1", "title": "Angle one", "prompt": "p"]]]),
            line(["type": "topic_result", "angle_id": "a1", "role": "research", "status": "complete",
                  "result": "Body for a1.", "citations": []]),
            line(["type": "topic_result", "angle_id": "synthesis", "role": "synthesis",
                  "status": "complete", "result": "The answer.", "citations": []]),
            line(["type": "run_result", "status": "complete", "grounding": "none",
                  "total_cost_usd": 0, "topics": []]),
        ]
    }

    private func persisted() throws -> EngineRunPersistence {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let persistence = EngineRunPersistence(question: "Where does fusion energy stand?",
                                               config: standardRun(project: project), store: store,
                                               runDir: runDir, priorNotes: [])
        for text in keylessRun() {
            persistence.apply(try XCTUnwrap(RunStreamParser.parse(text)), at: fixedStart)
        }
        return persistence
    }

    private func persistedReport() throws -> RunReport {
        let persistence = try persisted()
        return RunReport(startedAt: fixedStart, finishedAt: fixedStart.addingTimeInterval(60),
                         entries: persistence.entries, totalCostUSD: 0, runSpendCapUSD: 40,
                         validation: persistence.validation)
    }

    func testAKeylessRunStaysUnvalidatedWhenItIsReadBackFromItsReport() throws {
        let report = try persistedReport()

        XCTAssertEqual(report.grounding, RunGrounding.none)
        XCTAssertNotNil(RunHeader(report: report).unvalidatedNotice)
        XCTAssertFalse(ResearchGraph.from(report: report).isValidated)
    }

    func testEveryEntryOfAKeylessRunCarriesTheTierItCouldNotCheckAgainst() throws {
        let report = try persistedReport()

        XCTAssertFalse(report.entries.isEmpty)
        for entry in report.entries {
            XCTAssertEqual(entry.evidence?.grounding, RunGrounding.none, entry.id)
            XCTAssertFalse(try XCTUnwrap(entry.evidence).isValidated, entry.id)
        }
    }

    func testTheExportedNoteOfAKeylessRunWearsTheSameNoticeTheHeaderDoes() throws {
        let answer = try XCTUnwrap(try persisted().entries.last { $0.isSynthesis == true })
        let note = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(answer.notePath)),
                              encoding: .utf8)

        XCTAssertTrue(note.contains(try XCTUnwrap(EvidenceIndex(grounding: .none).unvalidatedNotice)))
    }

    func testTheRailReadsAKeylessAnswerThroughAnIndexThatKnowsItWasNeverChecked() throws {
        let report = try persistedReport()
        let answer = try XCTUnwrap(report.entries.last { $0.isSynthesis == true })
        let evidence = ReportEvidence(report: report)

        XCTAssertEqual(evidence.reading(for: answer.id)?.index.isValidated, false)
    }

    func testARunThatCapturedNothingButCouldHaveStillWritesNoEvidence() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let persistence = EngineRunPersistence(question: "q", config: standardRun(project: project),
                                               store: store, runDir: runDir, priorNotes: [])
        let captured = keylessRun().map { $0.replacingOccurrences(of: "\"grounding\":\"none\"",
                                                                  with: "\"grounding\":\"captured\"") }
        for text in captured {
            persistence.apply(try XCTUnwrap(RunStreamParser.parse(text)), at: fixedStart)
        }

        XCTAssertFalse(persistence.entries.isEmpty)
        for entry in persistence.entries { XCTAssertNil(entry.evidence, entry.id) }
    }
}

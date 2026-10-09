import XCTest
@testable import QuorumCore

final class PersistedRoundTests: XCTestCase {

    private func findings(_ id: String, marker: String, writeup: String) -> TopicFindings {
        TopicFindings(id: id, status: .complete, preset: .standard, headline: "H \(id)",
                      findings: [Finding(claim: "c", sources: ["https://nature.com/x"], confidence: .high,
                                         citationIDs: [marker])],
                      sourcesConsulted: 1, costUSD: 0, duration: .seconds(0), writeupMarkdown: writeup,
                      transcript: "", note: nil,
                      evidence: EvidenceIndex(citations: [
                        Citation(id: marker, sourceID: "s1", quote: "latency fell 40%",
                                 start: 1, end: 17, match: .exact, page: 4)]))
    }

    private let registry = EvidenceIndex(documents: [
        SourceDocument(sourceID: "s1", url: "https://nature.com/x", title: "Nature", contentType: .pdf,
                       snapshotPath: "sources/s1.md")])

    func testPersistedRoundCarriesEvidenceOntoEveryEntryAndItsNote() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)

        let entries = persistFanOutRound(
            synthesis: findings("synthesis", marker: "a1c1", writeup: "Reconciled [^a1c1]."),
            angleFindings: [findings("a1", marker: "c1", writeup: "Angle body [^c1].")],
            angleTitles: ["Latency"], question: "Do cold starts fall?", config: standardRun(project: project),
            store: store, runDir: runDir, priorNotes: [], round: 1, at: fixedStart, evidence: registry)

        XCTAssertEqual(entries.count, 2)
        for e in entries {
            XCTAssertEqual(e.evidence?.documents.map(\.sourceID), ["s1"],
                           "every entry resolves its markers against the run-wide registry")
        }
        XCTAssertEqual(entries[0].evidence?.citation("a1c1")?.match, .exact)
        XCTAssertEqual(entries[1].evidence?.citation("c1")?.match, .exact)

        let note = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(entries[0].notePath)), encoding: .utf8)
        XCTAssertTrue(note.contains("[^a1c1]: [Nature](https://nature.com/x)"),
                      "the durable note names the captured source, not just the quote")
    }

    func testASecondRoundOnTheSameQuestionDeepensTheSameNoteInsteadOfDuplicatingIt() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        func file(at offset: TimeInterval) throws -> [RunReport.TopicEntry] {
            let start = fixedStart.addingTimeInterval(offset)
            let runDir = try store.makeRunDirectory(projectURL: project, startedAt: start)
            return persistFanOutRound(
                synthesis: findings("synthesis", marker: "a1c1", writeup: "Reconciled [^a1c1]."),
                angleFindings: [findings("a1", marker: "c1", writeup: "Angle body [^c1].")],
                angleTitles: ["Latency"], question: "How does Postgres indexing work?",
                config: standardRun(project: project), store: store, runDir: runDir, priorNotes: [],
                round: 1, at: start, evidence: registry)
        }

        XCTAssertEqual(try file(at: 0).first?.noteAction, .created)
        XCTAssertEqual(try file(at: 86_400).first?.noteAction, .merged, "same question → reconcile into the note")
        let notes = project.appendingPathComponent("Quorum/notes")
        let files = try FileManager.default.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertEqual(files.count, 1, "deepened into ONE note, not duplicated")
    }

    func testOldReportWithoutIsSynthesisStillDecodes() throws {
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
}

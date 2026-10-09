import XCTest
@testable import QuorumCore

final class EngineAngleTranscriptTests: XCTestCase {

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func toolUse(_ angle: String, query: String) -> String {
        line(["type": "assistant", "angle_id": angle,
              "message": ["content": [["type": "tool_use", "name": "web_search", "input": ["query": query]]]]])
    }

    private func run() -> [String] {
        [
            line(["type": "run_start", "session_id": "qrun-t", "protocol_version": 4, "grounding": "none"]),
            line(["type": "plan", "angles": [["angle_id": "a1", "title": "Architektura", "prompt": "p1"],
                                              ["angle_id": "a2", "title": "ROI", "prompt": "p2"],
                                              ["angle_id": "a3", "title": "Prawo", "prompt": "p3"]]]),
            toolUse("a1", query: "doordash two tower"),
            toolUse("a2", query: "instacart ads revenue"),
            toolUse("a1", query: "uber eats ranking"),
            toolUse("synthesis", query: "reconcile"),
            line(["type": "topic_result", "angle_id": "a1", "role": "research", "status": "complete",
                  "result": "Body for a1.", "citations": []]),
            line(["type": "topic_result", "angle_id": "a2", "role": "research", "status": "complete",
                  "result": "Body for a2.", "citations": []]),
            line(["type": "topic_result", "angle_id": "a3", "role": "research", "status": "complete",
                  "result": "Body for a3.", "citations": []]),
            line(["type": "topic_result", "angle_id": "synthesis", "role": "synthesis", "status": "complete",
                  "result": "The answer.", "citations": []]),
            line(["type": "run_result", "status": "complete", "grounding": "none", "total_cost_usd": 0,
                  "topics": []]),
        ]
    }

    private func persistedEntries() throws -> [RunReport.TopicEntry] {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let persistence = EngineRunPersistence(question: "Zrób research", config: standardRun(project: project),
                                               store: store, runDir: runDir, priorNotes: [])
        for text in run() {
            persistence.apply(try XCTUnwrap(RunStreamParser.parse(text)), raw: text, at: fixedStart)
        }
        persistence.flush(at: fixedStart)
        return persistence.entries
    }

    private func transcript(_ entry: RunReport.TopicEntry) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(entry.transcriptPath)), encoding: .utf8)
    }

    func testEveryEntryHasNoTranscriptOrItsOwnDistinctTranscriptFile() throws {
        let entries = try persistedEntries()
        XCTAssertEqual(entries.count, 4)
        var seen = Set<String>()
        for entry in entries {
            guard let path = entry.transcriptPath else { continue }
            XCTAssertNotEqual(path, entry.notePath, "\(entry.question) aliased its note as a transcript")
            XCTAssertTrue(path.hasSuffix(".transcript.md"), path)
            XCTAssertTrue(seen.insert(path).inserted, "\(path) is shared")
        }
    }

    func testAnEngineAngleKeepsTheToolActivityItStreamed() throws {
        let entries = try persistedEntries()
        let architecture = try XCTUnwrap(entries.first { $0.question == "Architektura" })
        let log = try transcript(architecture)
        XCTAssertTrue(log.contains("doordash two tower"), log)
        XCTAssertTrue(log.contains("uber eats ranking"), log)
        XCTAssertFalse(log.contains("instacart ads revenue"), "another angle's activity leaked in")

        let roi = try XCTUnwrap(entries.first { $0.question == "ROI" })
        XCTAssertTrue(try transcript(roi).contains("instacart ads revenue"))
    }

    func testAnAngleThatStreamedNothingSaysSoRatherThanPointingAnywhere() throws {
        let law = try XCTUnwrap(try persistedEntries().first { $0.question == "Prawo" })
        XCTAssertNil(law.transcriptPath)
    }

    func testTheSynthesisTranscriptIsItsOwnStream() throws {
        let synthesis = try XCTUnwrap(try persistedEntries().first { $0.isSynthesis == true })
        let log = try transcript(synthesis)
        XCTAssertTrue(log.contains("reconcile"), log)
        XCTAssertFalse(log.contains("doordash two tower"))
    }
}

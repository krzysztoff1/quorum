import XCTest
@testable import QuorumCore

final class RunEvidenceTests: XCTestCase {

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func document(_ id: String, angle: String, url: String) -> String {
        line(["type": "document", "angle_id": angle,
              "document": ["source_id": id, "url": url, "title": url, "content_type": "html",
                           "text_length": 100, "byte_size": 100, "page_offsets": []]])
    }

    private func fold(_ lines: [String]) -> RunEvidence {
        var evidence = RunEvidence()
        for line in lines {
            guard let event = RunStreamParser.parse(line) else { continue }
            evidence.apply(event)
        }
        return evidence
    }

    private func node(_ id: String, kind: GraphNodeKind = .inquiry) -> GraphNode {
        GraphNode(id: id, kind: kind, title: id, state: .worked(.complete))
    }

    private func storedRun() throws -> StoredRun {
        let record = try JSONDecoder().decode(RunRecord.self,
                                              from: Data(contentsOf: EngineFixtures.url("record/validated.run.json")))
        return StoredRun(runDir: URL(fileURLWithPath: "/brain/questions/Q/runs/R"), record: record)
    }

    func testASourceTheStreamAnnouncedReachesTheRailBeforeTheRecordDoes() {
        let evidence = fold([document("s3", angle: "a1", url: "https://example.com/a")])
        XCTAssertEqual(evidence.index(for: node("a1")).document("s3")?.host, "example.com")
        XCTAssertNil(evidence.writeup(for: "a1"))
    }

    func testARunThatCapturedNothingHandsTheRailAnUnvalidatedIndex() {
        let evidence = fold([line(["type": "run_start", "session_id": "s", "protocol_version": 4, "grounding": "none"])])
        XCTAssertFalse(evidence.index(for: node("a1")).isValidated)
    }

    func testTheRecordGivesTheRailEveryWriteupAndQuoteTheEngineSettled() throws {
        let run = try storedRun()
        var evidence = fold([document("s99c25034", angle: "a1", url: "https://ex.test/a1")])
        evidence.absorb(run)
        XCTAssertEqual(evidence.writeup(for: "a1"), run.record.tasks.first { $0.id == "a1" }?.writeup)
        XCTAssertEqual(evidence.writeup(for: "synthesis"), run.record.answer?.markdown)
        XCTAssertEqual(evidence.index(for: node("synthesis", kind: .synthesis)).citation("a1c1")?.match, .exact)
        XCTAssertEqual(evidence.index(for: node("a1")).documents.count, run.record.sources.count)
    }

    func testAnEventTheRailHasNoUseForSaysSoRatherThanRedrawingIt() {
        var evidence = RunEvidence()
        let activity = line(["type": "stream_event", "angle_id": "a1", "event": ["type": "ping"]])
        XCTAssertFalse(evidence.apply(RunStreamParser.parse(activity)!))
        XCTAssertTrue(evidence.apply(RunStreamParser.parse(document("s1", angle: "a1", url: "https://x.test"))!))
    }

    func testANodeTheRunSaidNothingAboutReadsAsNothingRatherThanCrashing() throws {
        var evidence = RunEvidence()
        evidence.absorb(try storedRun())
        XCTAssertNil(evidence.writeup(for: "ghost"))
    }
}

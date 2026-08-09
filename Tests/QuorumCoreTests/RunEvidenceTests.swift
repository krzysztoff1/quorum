import XCTest
@testable import QuorumCore

/// What the rail beside the canvas reads: the writeup a node produced and the quotes behind it, folded out
/// of the same live stream the graph is folded from. A running angle has no report on disk yet, so without
/// this the canvas could only ever show plain markdown — the reader and the run would tell two stories.
final class RunEvidenceTests: XCTestCase {

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func citation(_ id: String, source: String, quote: String,
                          match: String = "exact") -> [String: Any] {
        ["id": id, "source_id": source, "quote": quote, "start": 0, "end": quote.count, "match": match]
    }

    private func document(_ id: String, angle: String, url: String) -> String {
        line(["type": "document", "angle_id": angle,
              "document": ["source_id": id, "url": url, "title": url, "content_type": "html",
                           "text_length": 100, "byte_size": 100, "page_offsets": []]])
    }

    private func topicResult(_ id: String, role: String = "research", writeup: String,
                             citations: [[String: Any]]) -> String {
        line(["type": "topic_result", "angle_id": id, "role": role, "status": "complete",
              "result": writeup, "citations": citations])
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

    private let writeup = "Prices rose 12% in 2025.[^c1]"

    func testAFinishedAnglesWriteupAndItsQuotesReachTheRailWhileTheRunIsStillGoing() {
        let evidence = fold([
            document("s3", angle: "a1", url: "https://example.com/pricing"),
            topicResult("a1", writeup: writeup,
                        citations: [citation("c1", source: "s3", quote: "rose 12%")])
        ])

        XCTAssertEqual(evidence.writeup(for: "a1"), writeup)
        let index = evidence.index(for: node("a1"))
        XCTAssertEqual(index.citation("c1")?.quote, "rose 12%")
        XCTAssertEqual(index.document("s3")?.url, "https://example.com/pricing")
        XCTAssertTrue(index.displayMatch("c1").isVerified)
    }

    func testAnAnglesCitationIdsMeanNothingNextDoor() {
        let evidence = fold([
            topicResult("a1", writeup: writeup, citations: [citation("c1", source: "s3", quote: "a1's quote")]),
            topicResult("a2", writeup: writeup, citations: [citation("c1", source: "s4", quote: "a2's quote")])
        ])

        XCTAssertEqual(evidence.index(for: node("a1")).citation("c1")?.quote, "a1's quote")
        XCTAssertEqual(evidence.index(for: node("a2")).citation("c1")?.quote, "a2's quote")
    }

    func testTheAnswerIsBackedByEveryAnglesRegistryBecauseItReusesTheirQuotes() {
        let evidence = fold([
            document("s3", angle: "a1", url: "https://example.com/pricing"),
            topicResult("a1", writeup: writeup, citations: [citation("c1", source: "s3", quote: "rose 12%")]),
            topicResult("synthesis-1", role: "synthesis", writeup: "The answer.[^a1c1]",
                        citations: [citation("a1c1", source: "s3", quote: "rose 12%")])
        ])

        let index = evidence.index(for: node("synthesis-1", kind: .synthesis))
        XCTAssertEqual(index.citation("a1c1")?.sourceID, "s3")
        XCTAssertEqual(index.citation("c1")?.quote, "rose 12%", "the angle's own id still resolves under the answer")
        XCTAssertEqual(index.document("s3")?.url, "https://example.com/pricing")
    }

    func testAVerdictReadsTheSameEvidenceAsTheAnswerItJudged() {
        let evidence = fold([
            document("s3", angle: "a1", url: "https://example.com/pricing"),
            topicResult("a1", writeup: writeup, citations: [citation("c1", source: "s3", quote: "rose 12%")])
        ])

        XCTAssertEqual(evidence.index(for: node("coverage-1", kind: .verdict)).citation("c1")?.quote, "rose 12%")
    }

    func testASourceOneAngleCapturedStillResolvesForTheAngleThatQuotedIt() {
        let evidence = fold([
            document("s3", angle: "a1", url: "https://example.com/pricing"),
            topicResult("a2", writeup: writeup, citations: [citation("c1", source: "s3", quote: "rose 12%")])
        ])

        XCTAssertEqual(evidence.index(for: node("a2")).document("s3")?.url, "https://example.com/pricing",
                       "a document is content-addressed and shared; only citation ids are an angle's own")
    }

    func testARunThatCapturedNothingHandsTheRailAnUnvalidatedIndex() {
        let evidence = fold([
            line(["type": "run_start", "session_id": "s", "protocol_version": 4, "grounding": "none"]),
            topicResult("a1", writeup: writeup, citations: [citation("c1", source: "s3", quote: "rose 12%")])
        ])

        let index = evidence.index(for: node("a1"))
        XCTAssertFalse(index.isValidated)
        XCTAssertFalse(index.displayMatch("c1").isVerified,
                       "a run with no snapshot to check against cannot hand out a verified chip")
    }

    func testTheRunWideRegistryLandsWhenTheRunFinishes() {
        let evidence = fold([
            line(["type": "run_result", "status": "complete", "total_cost_usd": 1,
                  "documents": [["source_id": "s9", "url": "https://example.com/late", "title": "Late",
                                 "content_type": "html", "text_length": 1, "byte_size": 1,
                                 "page_offsets": []]],
                  "topics": [["angle_id": "a1", "role": "research", "status": "complete", "result": writeup,
                              "citations": [citation("c1", source: "s9", quote: "rose 12%")]]]])
        ])

        XCTAssertEqual(evidence.index(for: node("a1")).document("s9")?.displayTitle, "Late")
        XCTAssertEqual(evidence.writeup(for: "a1"), writeup)
    }

    func testAnEventTheRailHasNoUseForSaysSoRatherThanRedrawingIt() {
        var evidence = RunEvidence()
        let activity = line(["type": "stream_event", "angle_id": "a1", "event": ["type": "ping"]])

        XCTAssertFalse(evidence.apply(RunStreamParser.parse(activity)!))
        XCTAssertTrue(evidence.apply(RunStreamParser.parse(
            topicResult("a1", writeup: writeup, citations: []))!))
    }

    func testANodeTheRunSaidNothingAboutReadsAsNothingRatherThanCrashing() {
        let evidence = fold([topicResult("a1", writeup: writeup, citations: [])])

        XCTAssertNil(evidence.writeup(for: "a2"))
        XCTAssertTrue(evidence.index(for: node("a2")).citations.isEmpty)
    }
}

import XCTest
@testable import QuorumCore

/// The fan-out-in-TS seam: the engine's `run` command must emit a stream the Swift `RunStreamParser`
/// reduces to the angle + synthesis findings the app files. This replays
/// the engine's checked-in golden run transcript and asserts the reduction — if the engine changes its
/// run output shape, this fails.
final class EngineRunTranscriptTests: XCTestCase {

    private func lines() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/run-transcript.ndjson")
        return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
    }

    func testRunTranscriptReducesToAnglesAndSynthesis() throws {
        let all = try lines()
        XCTAssertFalse(all.isEmpty)

        var sawRunStart = false
        var plannedAngles = 0
        var perAngleActivity = 0
        var angleFindings: [TopicFindings] = []
        var synthesis: TopicFindings?
        var runResultTopics = 0

        for line in all {
            guard let ev = RunStreamParser.parse(line) else {
                XCTFail("engine emitted a run line the parser rejected: \(line)"); continue
            }
            switch ev {
            case .runStart: sawRunStart = true
            case .plan(let angles): plannedAngles = angles.count
            case .activity: perAngleActivity += 1
            case .topicResult(let tr):
                if tr.role == "synthesis" { synthesis = tr.toFindings() }
                else { angleFindings.append(tr.toFindings()) }
            case .runResult(let rr): runResultTopics = rr.topics.count
            default: break
            }
        }

        XCTAssertTrue(sawRunStart, "run must announce itself")
        XCTAssertEqual(plannedAngles, 2)
        XCTAssertGreaterThanOrEqual(perAngleActivity, 2, "per-angle live stream must route by angle_id")
        XCTAssertEqual(angleFindings.count, 2)
        XCTAssertTrue(angleFindings.allSatisfy { $0.status == .complete })
        XCTAssertTrue(angleFindings.allSatisfy { !$0.findings.isEmpty }, "each angle's fenced json survives parsing")
        XCTAssertNotNil(synthesis)
        XCTAssertEqual(synthesis?.status, .complete)
        XCTAssertEqual(runResultTopics, 3, "2 angles + 1 synthesis")
        // These angles ran on the BYOK engine → their sessions are synthetic (chat seeds, not --resume).
        XCTAssertTrue(angleFindings.allSatisfy { ($0.usage?.provider ?? "") != "anthropic" })
    }

    /// The PRD 03 field-name seam. `engine/fixtures/run-transcript.ndjson` is recorded from the engine
    /// itself, so decoding it here pins two codebases together: rename `source_id`, `content_type`,
    /// `page_offsets`, `match` or the nesting on either side and this fails instead of the app silently
    /// rendering citations that resolve to nothing.
    func testEngineTranscriptCarriesEvidenceTheParserCanResolve() throws {
        var documents: [SourceDocument] = []
        var topicEvidence: [EvidenceIndex] = []
        var runEvidence = EvidenceIndex()
        var markerIDs: Set<String> = []

        for line in try lines() {
            switch RunStreamParser.parse(line) {
            case .document(let angleID, let doc):
                XCTAssertFalse(angleID.isEmpty, "a captured document names the angle that fetched it")
                documents.append(doc)
            case .topicResult(let tr):
                topicEvidence.append(tr.evidence)
                markerIDs.formUnion(CitationMarkers.ids(in: tr.result))
            case .runResult(let rr):
                runEvidence = rr.evidence
            default: break
            }
        }

        XCTAssertFalse(documents.isEmpty, "the engine announces each source it captures")
        XCTAssertTrue(documents.allSatisfy { !$0.sourceID.isEmpty && !$0.url.isEmpty },
                      "source_id/url survive the snake_case boundary")
        XCTAssertFalse(runEvidence.documents.isEmpty, "run_result carries the deduped registry")

        let citations = topicEvidence.flatMap(\.citations)
        XCTAssertFalse(citations.isEmpty, "topic_result carries resolved citations")
        XCTAssertFalse(markerIDs.isEmpty, "the engine's writeups carry per-sentence markers")

        let index = runEvidence.merging(EvidenceIndex(documents: documents, citations: citations))
        for id in markerIDs {
            guard let citation = index.citation(id) else {
                XCTFail("marker [^\(id)] resolves to no citation — the reader would show a dead chip"); continue
            }
            XCTAssertFalse(citation.quote.isEmpty, "\(id) carries the quote it was verified against")
            XCTAssertNotNil(index.document(for: citation),
                            "\(id) names a source_id present in the run registry")
        }
        for citation in citations where citation.isVerified {
            XCTAssertNotNil(citation.snapshotRange, "a verified quote carries the span to highlight")
        }
    }
}

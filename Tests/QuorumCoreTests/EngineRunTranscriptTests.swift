import XCTest
@testable import QuorumCore

/// The fan-out-in-TS seam: the engine's `run` command must emit a stream the Swift `RunStreamParser`
/// reduces to the angle + synthesis findings the app files. This replays
/// the engine's checked-in golden run transcript and asserts the reduction — if the engine changes its
/// run output shape, this fails.
final class EngineRunTranscriptTests: XCTestCase {

    private func lines() throws -> [String] {
        try EngineFixtures.lines("run-transcript.ndjson")
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

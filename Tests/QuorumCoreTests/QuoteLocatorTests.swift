import XCTest
@testable import QuorumCore

final class QuoteLocatorTests: XCTestCase {

    private func snapshot(_ name: String) throws -> String {
        try String(contentsOf: EngineFixtures.mockSource(name), encoding: .utf8)
    }

    private func citation(_ quote: String, _ span: Range<Int>?, match: QuoteMatch = .exact) -> Citation {
        Citation(id: "c1", sourceID: "s1", quote: quote,
                 start: span?.lowerBound, end: span?.upperBound, match: match)
    }

    private func recorded(_ id: String) throws -> (Citation, String) {
        let transcript = EngineFixtures.mockRun
        var citations: [String: Citation] = [:]
        var documents: [String: SourceDocument] = [:]
        for line in try String(contentsOf: transcript, encoding: .utf8).split(whereSeparator: \.isNewline) {
            switch RunStreamParser.parse(String(line)) {
            case .document(_, let document):
                documents[document.sourceID] = document
            case .topicResult(let topic):
                for citation in topic.evidence.citations { citations[citation.id] = citation }
            default:
                break
            }
        }
        let citation = try XCTUnwrap(citations[id], "the demo transcript no longer records \(id)")
        let document = try XCTUnwrap(documents[citation.sourceID])
        let name = URL(fileURLWithPath: try XCTUnwrap(document.snapshotPath)).lastPathComponent
        return (citation, try snapshot(name))
    }

    func testExactCitationHighlightsItsQuoteAtTheEnginesOffsets() throws {
        let (citation, text) = try recorded("a1c1")
        let found = QuoteLocator.passages(for: citation, in: text)
        XCTAssertEqual(citation.match, .exact)
        XCTAssertEqual(found.ranges.count, 1)
        XCTAssertEqual(String(text[found.ranges[found.index]]), citation.quote)
    }

    func testNormalizedCitationSpanningALineBreakHighlightsTheSpanTheEngineLocated() throws {
        let (citation, text) = try recorded("x4c4")
        let found = QuoteLocator.passages(for: citation, in: text)
        XCTAssertEqual(citation.match, .normalized)
        let selected = String(text[try XCTUnwrap(found.ranges.first)])
        XCTAssertTrue(selected.contains("\n"), "this fixture quote genuinely wraps a line")
    }

    func testPdfQuoteThatOnlyMatchesOnTheShortestRungIsFoundByTheLadder() throws {
        let (citation, _) = try recorded("a2c1")
        let rungs = QuoteLocator.pdfSearchCandidates(for: citation.quote)
        XCTAssertTrue(citation.quote.contains("\n"), "the PDF's text layer breaks this quote across a line")
        XCTAssertEqual(rungs.first, citation.quote.replacingOccurrences(of: "\n", with: " "), "the full quote is tried first")
        XCTAssertEqual(rungs.last, "median spend on input tokens fell",
                       "the six-word rung is the one a broken text layer still contains")
    }

    func testUnresolvedCitationOffersNoPassage() {
        let found = QuoteLocator.passages(for: citation("nothing like this text", nil, match: .unresolved),
                                          in: "some unrelated snapshot body")
        XCTAssertTrue(found.ranges.isEmpty, "an unverified quote must never produce a highlight")
    }

    func testOffsetsPointingPastTheSnapshotHighlightNothing() {
        let found = QuoteLocator.passages(for: citation("short", 9_000..<9_100), in: "short body")
        XCTAssertTrue(found.ranges.isEmpty)
    }

    func testRecordedRangeSurvivesMultiByteCharactersBeforeIt() {
        let text = "🔬🔬 finding: the value doubled"
        let quote = "the value doubled"
        let start = text.utf16.distance(from: text.utf16.startIndex,
                                        to: text.range(of: quote)!.lowerBound.samePosition(in: text.utf16)!)
        let range = QuoteLocator.recordedRange(citation(quote, start..<(start + quote.utf16.count)), in: text)
        XCTAssertEqual(range.map { String(text[$0]) }, quote,
                       "UTF-16 offsets must not slide when emoji precede the quote")
    }
}

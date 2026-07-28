import XCTest
@testable import QuorumCore

/// The highlight itself (PRD 03). Every other test proves a citation *carries* offsets; this proves the
/// reader turns them into the right passage — and, where it can't, into no passage rather than a
/// confidently wrong one. Runs against the checked-in mock snapshots the offline demo actually opens.
final class QuoteLocatorTests: XCTestCase {

    private func snapshot(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mock-sources")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func citation(_ quote: String, _ span: Range<Int>?, match: QuoteMatch = .exact) -> Citation {
        Citation(id: "c1", sourceID: "s1", quote: quote,
                 start: span?.lowerBound, end: span?.upperBound, match: match)
    }

    // MARK: the real fixtures

    func testExactCitationHighlightsItsQuoteInTheRealSnapshot() throws {
        let text = try snapshot("s4a1f09b2.md")
        let quote = "every deployment reviewed here remained under 40 MW"
        let found = QuoteLocator.passages(for: citation(quote, 190..<241), in: text)
        XCTAssertFalse(found.ranges.isEmpty)
        XCTAssertEqual(String(text[found.ranges[found.index]]), quote)
    }

    func testNormalizedCitationSpanningALineBreakStillHighlights() throws {
        let text = try snapshot("s4a1f09b2.md")
        let quote = "the approach works at pilot scale today"
        let found = QuoteLocator.passages(for: citation(quote, 142..<181, match: .normalized), in: text)
        XCTAssertFalse(found.ranges.isEmpty, "a quote folded across a newline must still resolve")
        let selected = String(text[found.ranges[found.index]])
        XCTAssertTrue(selected.contains("\n"), "this fixture quote genuinely wraps a line")
        XCTAssertEqual(QuoteLocator.folded(selected), QuoteLocator.folded(quote))
    }

    func testPdfQuoteThatOnlyMatchesOnTheShortestRungIsFoundByTheLadder() throws {
        // The PDF's text layer breaks this quote across a line, so neither the full quote nor its first
        // 12 words appear; only the 6-word rung does. Pinned because losing the ladder loses the highlight.
        let quote = "subsidies are netted out the regional spread narrows to roughly 20%"
        let rungs = QuoteLocator.pdfSearchCandidates(for: quote)
        XCTAssertEqual(rungs.last, "subsidies are netted out the regional")
        XCTAssertEqual(rungs.first, quote, "the full quote is tried first")
    }

    // MARK: honesty

    func testUnresolvedCitationOffersNoPassage() {
        let found = QuoteLocator.passages(for: citation("nothing like this text", nil, match: .unresolved),
                                          in: "some unrelated snapshot body")
        XCTAssertTrue(found.ranges.isEmpty, "an unverified quote must never produce a highlight")
    }

    func testStaleOffsetsDoNotHighlightTheWrongText() {
        let text = "Alpha beta gamma. The real quote lives here. Delta epsilon."
        // Offsets recorded against an older revision now point at "Alpha beta gamma."
        let found = QuoteLocator.passages(for: citation("The real quote lives here", 0..<17), in: text)
        XCTAssertFalse(found.ranges.isEmpty, "the quote is still findable by search")
        XCTAssertEqual(String(text[found.ranges[found.index]]), "The real quote lives here",
                       "search must win over offsets that no longer hold the quote")
    }

    func testOffsetsPointingPastTheSnapshotAreIgnored() {
        let text = "short body"
        let found = QuoteLocator.passages(for: citation("short", 9_000..<9_100), in: text)
        XCTAssertEqual(found.ranges.map { String(text[$0]) }, ["short"])
    }

    func testRecordedRangeSurvivesMultiByteCharactersBeforeIt() {
        let text = "🔬🔬 finding: the value doubled"
        let quote = "the value doubled"
        let start = text.utf16.distance(from: text.utf16.startIndex,
                                        to: text.range(of: quote)!.lowerBound.samePosition(in: text.utf16)!)
        let range = QuoteLocator.recordedRange(citation(quote, start..<(start + quote.utf16.count)), in: text)
        XCTAssertNotNil(range)
        XCTAssertEqual(range.map { String(text[$0]) }, quote,
                       "UTF-16 offsets must not slide when emoji precede the quote")
    }

    func testRepeatedQuoteYieldsEveryOccurrenceForPrevNext() {
        let text = "the same claim appears twice: the same claim appears twice."
        let hits = QuoteLocator.occurrences(of: "the same claim appears twice", in: text)
        XCTAssertEqual(hits.count, 2)
    }

    func testRegexMetacharactersInAQuoteAreMatchedLiterally() {
        let text = "costs rose (roughly 20%) in Q3 [see note]."
        let hits = QuoteLocator.occurrences(of: "(roughly 20%) in Q3 [see note]", in: text)
        XCTAssertEqual(hits.count, 1, "a quote is a literal, not a pattern")
    }

    func testVeryShortQuotesAreRejectedRatherThanMatchingNoise() {
        XCTAssertTrue(QuoteLocator.occurrences(of: "of", in: "a body full of little words of noise").isEmpty)
    }
}

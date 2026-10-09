import XCTest
@testable import QuorumCore

/// The highlight itself (PRD 03). Every other test proves a citation *carries* offsets; this proves the
/// reader turns them into the right passage — and, where it can't, into no passage rather than a
/// confidently wrong one. Runs against the checked-in mock snapshots the offline demo actually opens.
final class QuoteLocatorTests: XCTestCase {

    private func snapshot(_ name: String) throws -> String {
        try String(contentsOf: EngineFixtures.mockSource(name), encoding: .utf8)
    }

    private func citation(_ quote: String, _ span: Range<Int>?, match: QuoteMatch = .exact) -> Citation {
        Citation(id: "c1", sourceID: "s1", quote: quote,
                 start: span?.lowerBound, end: span?.upperBound, match: match)
    }

    /// A citation the offline demo actually records, paired with the snapshot it points into — so these
    /// stay true to the fixture instead of pinning offsets that a regenerated transcript would move.
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

    // MARK: PRD 07 R6 — two matchers, one behavior

    private struct MatchContract: Decodable {
        struct Case: Decodable { let name: String; let snapshot: String; let quote: String; let match: QuoteMatch }
        let diceThreshold: Double
        let orderThreshold: Double
        let snapshots: [String: String]
        let cases: [Case]
    }

    private func matchContract() throws -> MatchContract {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/quote-match-contract.json")
        return try JSONDecoder().decode(MatchContract.self, from: Data(contentsOf: url))
    }

    /// The same quotes the engine's `evidence.test.ts` runs, resolved by the reader's own matcher. A chip is
    /// coloured by the tier the engine recorded and highlighted by the tier this side derives; when they
    /// disagree the reader is shown a confident colour over a passage that does not hold the quote.
    func testEveryQuoteInTheSharedContractResolvesToTheTierTheEngineRecorded() throws {
        let contract = try matchContract()
        XCTAssertFalse(contract.cases.isEmpty)
        for shared in contract.cases {
            let text = try XCTUnwrap(contract.snapshots[shared.snapshot])
            XCTAssertEqual(QuoteLocator.resolve(quote: shared.quote, in: text).match, shared.match,
                           "shared contract case: \(shared.name)")
        }
    }

    func testThresholdsMatchTheOnesTheEngineIsBuiltAgainst() throws {
        let contract = try matchContract()
        XCTAssertEqual(QuoteLocator.fuzzyDiceThreshold, contract.diceThreshold)
        XCTAssertEqual(QuoteLocator.fuzzyOrderThreshold, contract.orderThreshold)
    }

    func testAScrambledQuoteClearsTheWordOverlapBarAndIsStillRefused() throws {
        let contract = try matchContract()
        let text = try XCTUnwrap(contract.snapshots["prose"])
        let scrambled = "clusters tested in year over year 40% fell latency fleet the across Measured"
        let scores = try XCTUnwrap(QuoteLocator.windowScores(quote: scrambled, in: text))
        XCTAssertGreaterThanOrEqual(scores.dice, QuoteLocator.fuzzyDiceThreshold)
        XCTAssertLessThan(scores.order, QuoteLocator.fuzzyOrderThreshold)
        XCTAssertEqual(QuoteLocator.resolve(quote: scrambled, in: text).match, .unresolved)
    }

    func testAScrambledWindowDoesNotShadowTheOrderedMatchFurtherDownTheDocument() throws {
        let contract = try matchContract()
        let text = try XCTUnwrap(contract.snapshots["decoyThenMatch"])
        let quote = "the cat sat on the mat"
        let scores = try XCTUnwrap(QuoteLocator.windowScores(quote: quote, in: text))
        let resolved = QuoteLocator.resolve(quote: quote, in: text)

        XCTAssertGreaterThanOrEqual(scores.order, QuoteLocator.fuzzyOrderThreshold)
        XCTAssertEqual(resolved.match, .fuzzy)
        XCTAssertTrue(String(text[try XCTUnwrap(resolved.range)]).contains("the cat sat on a mat"))
    }

    func testAFuzzyResolutionHighlightsTheWindowItScored() throws {
        let contract = try matchContract()
        let text = try XCTUnwrap(contract.snapshots["prose"])
        let reworded = "Measured across the fleet, latency fell 40% year over year in the tested clusters"
        let resolved = QuoteLocator.resolve(quote: reworded, in: text)
        XCTAssertEqual(resolved.match, .fuzzy)
        XCTAssertTrue(String(text[try XCTUnwrap(resolved.range)]).contains("latency fell 40%"))
    }

    func testAnUnresolvedQuoteCarriesNoRangeToHighlight() throws {
        let contract = try matchContract()
        let text = try XCTUnwrap(contract.snapshots["prose"])
        let resolved = QuoteLocator.resolve(quote: "Kubernetes eliminated cold starts entirely across every region in 2019",
                                            in: text)
        XCTAssertEqual(resolved.match, .unresolved)
        XCTAssertNil(resolved.range)
    }

    // MARK: the real fixtures

    func testExactCitationHighlightsItsQuoteInTheRealSnapshot() throws {
        let (citation, text) = try recorded("a1c1")
        let found = QuoteLocator.passages(for: citation, in: text)
        XCTAssertEqual(citation.match, .exact)
        XCTAssertFalse(found.ranges.isEmpty)
        XCTAssertEqual(String(text[found.ranges[found.index]]), citation.quote)
    }

    func testNormalizedCitationSpanningALineBreakStillHighlights() throws {
        let (citation, text) = try recorded("x4c4")
        let found = QuoteLocator.passages(for: citation, in: text)
        XCTAssertEqual(citation.match, .normalized)
        XCTAssertFalse(found.ranges.isEmpty, "a quote folded across a newline must still resolve")
        let selected = String(text[found.ranges[found.index]])
        XCTAssertTrue(selected.contains("\n"), "this fixture quote genuinely wraps a line")
        XCTAssertEqual(QuoteLocator.folded(selected), QuoteLocator.folded(citation.quote))
    }

    func testPdfQuoteThatOnlyMatchesOnTheShortestRungIsFoundByTheLadder() throws {
        let (citation, _) = try recorded("a2c1")
        let rungs = QuoteLocator.pdfSearchCandidates(for: citation.quote)
        XCTAssertTrue(citation.quote.contains("\n"), "the PDF's text layer breaks this quote across a line")
        XCTAssertEqual(rungs.first,
                       citation.quote.replacingOccurrences(of: "\n", with: " "),
                       "the full quote is tried first")
        XCTAssertEqual(rungs.last, "median spend on input tokens fell",
                       "the six-word rung is the one a broken text layer still contains")
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

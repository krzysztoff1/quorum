import XCTest
@testable import QuorumCore

final class CitationTierTests: XCTestCase {

    private let paper = SourceDocument(sourceID: "s1", url: "https://real.example", title: "Paper",
                                       contentType: .html, snapshotPath: "sources/s1.md")

    private func ladder(_ match: QuoteMatch, unsupported: Bool = false,
                        grounding: RunGrounding = .captured) -> CitationTier {
        EvidenceIndex(documents: [paper],
                      citations: [Citation(id: "c1", sourceID: "s1", quote: "q", start: 0, end: 1,
                                           match: match)],
                      grounding: grounding)
            .marking(unsupported: unsupported ? ["c1"] : [])
            .tier("c1")
    }

    func testAQuoteThatCarriesItsClaimIsTheOnlyOneDrawnAsVerified() {
        XCTAssertEqual(ladder(.exact), .supported)
        XCTAssertEqual(ladder(.normalized), .supported)
        XCTAssertEqual(ladder(.fuzzy), .close)
        XCTAssertEqual(ladder(.unresolved), .unresolved)
        XCTAssertEqual(CitationTier.supported.mark, "")
        XCTAssertEqual(Set(CitationTier.allCases.map(\.mark)).count, CitationTier.allCases.count)
    }

    func testAQuoteThatDoesNotSupportItsClaimOutranksHowWellItWasLocated() {
        XCTAssertEqual(ladder(.exact, unsupported: true), .unsupported)
        XCTAssertEqual(ladder(.normalized, unsupported: true), .unsupported)
        XCTAssertEqual(ladder(.fuzzy, unsupported: true), .unsupported)
        XCTAssertFalse(CitationTier.unsupported.isVerified)
        XCTAssertEqual(CitationTier.unsupported.mark, "⚠")
    }

    func testAQuoteNobodyLocatedIsNotDressedUpAsAJudgedOne() {
        XCTAssertEqual(ladder(.unresolved, unsupported: true), .unresolved)
    }

    func testAnUnvalidatedRunHandsOutNoTierItDidNotEarn() {
        XCTAssertEqual(ladder(.exact, grounding: .none), .unresolved)
        XCTAssertEqual(ladder(.exact, unsupported: true, grounding: .none), .unresolved)
    }

    func testAnIndexReadsTheSameLadderForACitationItNeverHeardOf() {
        XCTAssertEqual(EvidenceIndex().tier("nope"), .unresolved)
    }
}

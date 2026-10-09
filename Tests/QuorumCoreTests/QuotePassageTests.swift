import XCTest
@testable import QuorumCore

final class QuotePassageTests: XCTestCase {
    private let page = "Intro words. For grocers, personalization at scale can drive a sales lift of 1-2% of total sales. Then more text follows here."

    func testThePassageIsCutAroundTheEnginesOffsetsAtWordBoundaries() {
        let start = (page as NSString).range(of: "For grocers").location
        let end = (page as NSString).range(of: "total sales.").upperBound
        let passage = QuotePassage(text: page, quote: "ignored", start: start, end: end, radius: 10)
        XCTAssertEqual(passage.quote, "For grocers, personalization at scale can drive a sales lift of 1-2% of total sales.")
        XCTAssertEqual(passage.before, "…words. ")
        XCTAssertEqual(passage.after, " Then more…")
    }

    func testWithoutOffsetsTheQuoteIsFoundInTheText() {
        let passage = QuotePassage(text: page, quote: "a sales lift of 1-2%", start: nil, end: nil, radius: 12)
        XCTAssertEqual(passage.quote, "a sales lift of 1-2%")
        XCTAssertEqual(passage.before, "…can drive ")
    }

    func testAQuoteTheTextDoesNotHoldStandsAlone() {
        let passage = QuotePassage(text: page, quote: "nowhere in the page", start: nil, end: nil)
        XCTAssertEqual(passage, QuotePassage(before: "", quote: "nowhere in the page", after: ""))
    }

    func testOffsetsOutsideTheTextFallBackToSearching() {
        let passage = QuotePassage(text: page, quote: "Then more text", start: 900, end: 950, radius: 0)
        XCTAssertEqual(passage.quote, "Then more text")
    }
}

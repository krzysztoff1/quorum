import XCTest
@testable import QuorumCore

final class QuickSwitchTests: XCTestCase {

    func testEmptyQueryMatchesEverythingAtBaseScore() {
        XCTAssertEqual(QuickSwitch.score("", "New run"), 0)
        XCTAssertEqual(QuickSwitch.score("   ", "anything at all"), 0)
    }

    func testPrefixBeatsWordBoundaryBeatsSubstring() {
        XCTAssertEqual(QuickSwitch.score("new", "New run"), 0)   // title prefix
        XCTAssertEqual(QuickSwitch.score("run", "New run"), 1)   // after a space
        XCTAssertEqual(QuickSwitch.score("ew", "New run"), 2)    // mid-word
    }

    func testNoMatchIsNil() {
        XCTAssertNil(QuickSwitch.score("xyz", "New run"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(QuickSwitch.score("RUN", "New run"), 1)
        XCTAssertEqual(QuickSwitch.score("nEw", "New run"), 0)
    }

    func testRankedIndicesFilterAndOrderByScoreThenPosition() {
        let titles = ["New run", "Runbook", "Deep run archive", "unrelated"]
        XCTAssertEqual(QuickSwitch.rankedIndices("run", titles), [1, 0, 2])
    }

    func testRankedIndicesEmptyQueryKeepsInputOrder() {
        XCTAssertEqual(QuickSwitch.rankedIndices("", ["a", "b", "c"]), [0, 1, 2])
    }

    func testRankedIndicesNoMatches() {
        XCTAssertEqual(QuickSwitch.rankedIndices("zzz", ["a", "b"]), [])
    }
}

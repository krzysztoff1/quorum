import XCTest
@testable import QuorumCore

final class ClaimNavigatorTests: XCTestCase {

    private func navigator() -> ClaimNavigator {
        ClaimNavigator(entries: [
            .init(id: "lead", cites: ["c1"]),
            .init(id: "k1", cites: ["c2", "c3"]),
            .init(id: "k2", cites: []),
            .init(id: "k3", cites: ["c4"]),
        ])
    }

    func testJMovesToTheFirstClaimThenOnAndStopsAtTheLast() {
        var nav = navigator()
        nav.next()
        XCTAssertEqual(nav.focusedID, "lead")
        nav.next()
        XCTAssertEqual(nav.focusedID, "k1")
        nav.next(); nav.next(); nav.next()
        XCTAssertEqual(nav.focusedID, "k3")
    }

    func testKMovesBackAndStopsAtTheFirst() {
        var nav = navigator()
        nav.previous()
        XCTAssertEqual(nav.focusedID, "lead")
        nav.next()
        XCTAssertEqual(nav.focusedID, "k1")
        nav.previous()
        XCTAssertEqual(nav.focusedID, "lead")
        nav.previous()
        XCTAssertEqual(nav.focusedID, "lead")
    }

    func testReturnOpensTheFirstSourceOfTheFocusedClaim() {
        var nav = navigator()
        nav.next(); nav.next()
        nav.openFirstSource()
        XCTAssertEqual(nav.opened, "c2")
    }

    func testReturnOnAClaimWithoutSourcesOpensNothing() {
        var nav = navigator()
        nav.focus("k2")
        nav.openFirstSource()
        XCTAssertNil(nav.opened)
    }

    func testBracketsCycleTheSourcesWithinTheClaimAndWrap() {
        var nav = navigator()
        nav.focus("k1")
        nav.openFirstSource()
        nav.cycleSource(by: 1)
        XCTAssertEqual(nav.opened, "c3")
        nav.cycleSource(by: 1)
        XCTAssertEqual(nav.opened, "c2")
        nav.cycleSource(by: -1)
        XCTAssertEqual(nav.opened, "c3")
    }

    func testCyclingWithNothingOpenDoesNothing() {
        var nav = navigator()
        nav.focus("k1")
        nav.cycleSource(by: 1)
        XCTAssertNil(nav.opened)
    }

    func testMovingWhileTheRailIsOpenCarriesTheRailToTheNewClaim() {
        var nav = navigator()
        nav.focus("k1")
        nav.openFirstSource()
        nav.next()
        XCTAssertEqual(nav.focusedID, "k2")
        XCTAssertNil(nav.opened)
        nav.next()
        XCTAssertEqual(nav.opened, "c4")
    }

    func testEscapeClosesTheRailButKeepsTheFocus() {
        var nav = navigator()
        nav.focus("k1")
        nav.openFirstSource()
        nav.close()
        XCTAssertNil(nav.opened)
        XCTAssertEqual(nav.focusedID, "k1")
        XCTAssertFalse(nav.railOpen)
    }

    func testClickingAChipFocusesItsClaimAndOpensThatSource() {
        var nav = navigator()
        nav.open(cite: "c3")
        XCTAssertEqual(nav.focusedID, "k1")
        XCTAssertEqual(nav.opened, "c3")
        XCTAssertTrue(nav.railOpen)
    }

    func testClickingTheOpenChipAgainClosesTheRail() {
        var nav = navigator()
        nav.open(cite: "c3")
        nav.open(cite: "c3")
        XCTAssertNil(nav.opened)
    }

    func testAChipNoClaimOwnsStillOpens() {
        var nav = navigator()
        nav.open(cite: "zzz")
        XCTAssertEqual(nav.opened, "zzz")
        XCTAssertNil(nav.focusedID)
    }

    func testAnAnswerWithNoClaimsIsNotNavigable() {
        var nav = ClaimNavigator(entries: [])
        nav.next()
        XCTAssertNil(nav.focusedID)
    }

    func testTheFocusedClaimsSourcesAreWhatTheRailListsAsInThisClaim() {
        var nav = navigator()
        nav.focus("k1")
        XCTAssertEqual(nav.sources, ["c2", "c3"])
        XCTAssertEqual(nav.sourcePosition, nil)
        nav.openFirstSource()
        XCTAssertEqual(nav.sourcePosition, 0)
    }
}

import XCTest
@testable import QuorumCore

final class TextContainerWidthTests: XCTestCase {

    func testAContainerNarrowerThanItsFrameMustBeWidened() {
        XCTAssertTrue(TextContainerWidth.mustMatch(containerWidth: 170, frameWidth: 688))
    }

    func testAContainerWiderThanItsFrameMustBeNarrowed() {
        XCTAssertTrue(TextContainerWidth.mustMatch(containerWidth: 688, frameWidth: 462))
    }

    func testAContainerThatAlreadyMatchesIsLeftAlone() {
        XCTAssertFalse(TextContainerWidth.mustMatch(containerWidth: 688, frameWidth: 688))
        XCTAssertFalse(TextContainerWidth.mustMatch(containerWidth: 688.3, frameWidth: 688))
    }

    func testAFrameWithNoWidthYetNeverResizesTheContainer() {
        XCTAssertFalse(TextContainerWidth.mustMatch(containerWidth: 688, frameWidth: 0))
    }
}

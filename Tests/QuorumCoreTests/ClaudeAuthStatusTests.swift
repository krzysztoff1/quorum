import XCTest
@testable import QuorumCore

final class ClaudeAuthStatusTests: XCTestCase {
    func testLoggedInOutputIsAuthenticated() {
        XCTAssertEqual(ClaudeAuthStatus.isLoggedIn(from: #"{"loggedIn": true, "authMethod": "claude.ai"}"#), true)
    }

    func testLoggedOutOutputIsNotAuthenticated() {
        XCTAssertEqual(ClaudeAuthStatus.isLoggedIn(from: #"{"loggedIn": false}"#), false)
    }

    func testUnreadableOutputIsUnknownRatherThanGuessed() {
        XCTAssertNil(ClaudeAuthStatus.isLoggedIn(from: "Usage: claude auth <command>"))
        XCTAssertNil(ClaudeAuthStatus.isLoggedIn(from: nil))
        XCTAssertNil(ClaudeAuthStatus.isLoggedIn(from: #"{"email": "a@b.c"}"#))
    }
}

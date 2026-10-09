import XCTest
@testable import QuorumCore

final class RunRefusalTests: XCTestCase {
    func testALoggedOutRefusalExplainsTheFixInDoctorsWords() {
        let refusal = RunStreamParser.Refusal(kind: "not_logged_in", reason: "The Claude CLI is not logged in. Run `claude` in a terminal, sign in with /login, then try again.")
        let finding = Preflight.refusalFinding(refusal)
        XCTAssertFalse(finding.ok)
        XCTAssertEqual(finding.message, "The last run was refused: The Claude CLI is not logged in. Run `claude` in a terminal, sign in with /login, then try again.")
    }
}

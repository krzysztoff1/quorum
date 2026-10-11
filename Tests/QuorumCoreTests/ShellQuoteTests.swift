import XCTest
@testable import QuorumCore

final class ShellQuoteTests: XCTestCase {

    func testAPlainPathIsWrappedInSingleQuotes() {
        XCTAssertEqual(ShellQuote.quoted("/Users/me/Quorum"), "'/Users/me/Quorum'")
    }

    func testASingleQuoteInsideIsClosedEscapedAndReopened() {
        XCTAssertEqual(ShellQuote.quoted("/Users/me/Kasia's notes"), #"'/Users/me/Kasia'\''s notes'"#)
    }

    func testTheMentionPrefixStaysInsideTheQuotes() {
        XCTAssertEqual(ShellQuote.quoted("@notes/it's.md"), #"'@notes/it'\''s.md'"#)
    }

    func testEverythingElseTheShellLikesIsLeftToTheQuotes() {
        XCTAssertEqual(ShellQuote.quoted("a $b `c` \"d\" ; rm"), "'a $b `c` \"d\" ; rm'")
    }
}

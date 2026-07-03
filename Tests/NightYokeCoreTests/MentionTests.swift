import XCTest
@testable import NightYokeCore

final class MentionTests: XCTestCase {
    func testActiveQuery() {
        XCTAssertEqual(Mention.activeQuery(in: "look at @Chat"), "Chat")
        XCTAssertEqual(Mention.activeQuery(in: "@a"), "a")
        XCTAssertEqual(Mention.activeQuery(in: "@"), "")               // bare @ = empty query
        XCTAssertNil(Mention.activeQuery(in: "mail me@host"))          // @ not opening a token
        XCTAssertNil(Mention.activeQuery(in: "@done here"))            // whitespace after → completed
        XCTAssertNil(Mention.activeQuery(in: "no mention"))
    }

    func testComplete() {
        XCTAssertEqual(Mention.complete("see @Ch", with: "Sources/Chat.swift"), "see @Sources/Chat.swift ")
        XCTAssertEqual(Mention.complete("@", with: "a/b.swift"), "@a/b.swift ")
    }

    func testRankPrefersFilenamePrefixThenShortest() {
        let files = ["a/b/Chat.swift", "x/prefixChatSuffix.md", "deep/nested/notes.md"]
        let r = Mention.rank("chat", in: files)
        XCTAssertEqual(r.first, "a/b/Chat.swift")                      // filename prefix wins
        XCTAssertEqual(r, ["a/b/Chat.swift", "x/prefixChatSuffix.md"]) // notes.md has no "chat" → dropped
    }

    func testRankEmptyQueryReturnsPrefix() {
        XCTAssertEqual(Mention.rank("", in: ["a", "b", "c"], limit: 2), ["a", "b"])
    }

    func testRelativePath() {
        let root = URL(fileURLWithPath: "/proj", isDirectory: true)
        XCTAssertEqual(Mention.relativePath(of: URL(fileURLWithPath: "/proj/a/b.swift"), under: root), "a/b.swift")
        XCTAssertNil(Mention.relativePath(of: URL(fileURLWithPath: "/other/x.swift"), under: root))
    }
}

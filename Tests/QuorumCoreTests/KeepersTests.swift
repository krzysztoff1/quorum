import XCTest
@testable import QuorumCore

/// Keepers: append/parse/remove over the portable markdown file. Pure string ops — no disk, no network.
/// The load-bearing test is `testRobustBodyRoundTrips`: a clip body full of markdown metacharacters must
/// survive the marker-delimited format unchanged.
final class KeepersTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    func testEmptyRoundTrips() {
        XCTAssertEqual(Keepers.parse(Keepers.render([])), [])
    }

    func testAppendThenParse() {
        let md = Keepers.appending(text: "A great sentence", source: "Agent frameworks", id: "1", date: day, to: "")
        XCTAssertEqual(Keepers.parse(md),
                       [Keeper(id: "1", text: "A great sentence", source: "Agent frameworks", date: day)])
    }

    func testAppendPreservesOrder() {
        var md = Keepers.appending(text: "first", source: "s1", id: "1", date: day, to: "")
        md = Keepers.appending(text: "second", source: "s2", id: "2", date: day, to: md)
        XCTAssertEqual(Keepers.parse(md).map(\.text), ["first", "second"])
    }

    func testRobustBodyRoundTrips() {
        let tricky = "line with ---\n> already quoted\nand a | pipe\n\nblank above"
        let md = Keepers.appending(text: tricky, source: "src", id: "x", date: day, to: "")
        XCTAssertEqual(Keepers.parse(md).first?.text, tricky)
    }

    func testRemoveDropsOnlyThatClip() {
        var md = Keepers.appending(text: "keep me", source: "s", id: "a", date: day, to: "")
        md = Keepers.appending(text: "drop me", source: "s", id: "b", date: day, to: md)
        XCTAssertEqual(Keepers.parse(Keepers.removing(id: "b", from: md)).map(\.id), ["a"])
    }

    func testSourceSanitizedToOneLine() {
        let md = Keepers.appending(text: "t", source: "multi\nline | pipe", id: "1", date: day, to: "")
        XCTAssertEqual(Keepers.parse(md).first?.source, "multi line / pipe")
    }

    func testUrlLivesUnderBrainQuorum() {
        XCTAssertEqual(Keepers.url(in: URL(fileURLWithPath: "/tmp/proj")).path, "/tmp/proj/Quorum/keepers.md")
    }

    func testKeeperLinksBackToSourceNote() {
        let note = "/Users/me/proj/Quorum/notes/agent-frameworks.md"
        let md = Keepers.appending(text: "a load-bearing claim", source: note, id: "1", date: day, to: "")
        XCTAssertEqual(Keepers.parse(md).first?.source, note)          // full path kept for the app to reopen
        XCTAssertTrue(md.contains("[[agent-frameworks]]"))             // wikilink kept for Obsidian
    }
}

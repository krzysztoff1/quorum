import XCTest
@testable import QuorumCore

final class CLIStreamTests: XCTestCase {

    func testATokenDeltaIsLiveTextAndAThinkingDeltaIsNot() throws {
        let text = try XCTUnwrap(CLIStream.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}}"#))
        XCTAssertEqual(text.deltaText, "Hel")
        XCTAssertNil(text.deltaThinking)
        let thinking = try XCTUnwrap(CLIStream.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}}"#))
        XCTAssertEqual(thinking.deltaThinking, "hmm")
        XCTAssertNil(thinking.deltaText)
    }

    func testAToolCallNamesWhatItReadOrSearched() throws {
        let line = try XCTUnwrap(CLIStream.parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","name":"WebFetch","input":{"url":"https://example.com"}}]}}"#))
        XCTAssertEqual(line.assistantText, "Looking.")
        XCTAssertEqual(line.toolUses, [CLIStream.ToolUse(name: "WebFetch", detail: "https://example.com")])
    }

    func testTheResultLineCarriesTheSessionCostAndFinalText() throws {
        let line = try XCTUnwrap(CLIStream.parse(#"{"type":"result","result":"Done.","session_id":"abc","total_cost_usd":0.25}"#))
        XCTAssertEqual(line.result, "Done.")
        XCTAssertEqual(line.sessionID, "abc")
        XCTAssertEqual(line.totalCostUSD, Decimal(0.25))
    }

    func testALineThatIsNotJSONIsNoLine() {
        XCTAssertNil(CLIStream.parse("not json"))
    }
}

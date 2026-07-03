import XCTest
@testable import QuorumCore

final class ResearchOutputParserTests: XCTestCase {

    func testParsesWriteupAndFinalJSONBlock() {
        let text = """
        # Findings

        Swift is fast. See sources.

        ```json
        {"headline":"Swift is fast","status":"complete","sourcesConsulted":12,\
        "findings":[{"claim":"Swift compiles to native code","sources":["https://swift.org"],"confidence":"high"}],\
        "note":"solid"}
        ```
        """
        let out = ResearchOutputParser.parseFinal(text)
        XCTAssertEqual(out.headline, "Swift is fast")
        XCTAssertEqual(out.status, .complete)
        XCTAssertEqual(out.sourcesConsulted, 12)
        XCTAssertEqual(out.findings.count, 1)
        XCTAssertEqual(out.findings[0].confidence, .high)
        XCTAssertEqual(out.findings[0].sources, ["https://swift.org"])
        XCTAssertTrue(out.writeup.contains("Swift is fast. See sources."))
        XCTAssertFalse(out.writeup.contains("```json"))   // block stripped from the body
    }

    func testTitleFromCleansCheapModelReply() {
        XCTAssertEqual(ResearchOutputParser.titleFrom("Best Rust Async Runtimes"), "Best Rust Async Runtimes")
        XCTAssertEqual(ResearchOutputParser.titleFrom("Title: \"Vector DBs Compared\""), "Vector DBs Compared")
        XCTAssertEqual(ResearchOutputParser.titleFrom("**SwiftUI State Guide.**\nignored second line"), "SwiftUI State Guide")
        XCTAssertEqual(ResearchOutputParser.titleFrom("   \n  "), "")
        XCTAssertEqual(ResearchOutputParser.titleFrom(String(repeating: "x", count: 200)).count, 60)
    }

    func testInconclusiveStatusHonored() {
        let text = "Couldn't confirm.\n```json\n{\"headline\":\"No answer\",\"status\":\"inconclusive\",\"findings\":[]}\n```"
        let out = ResearchOutputParser.parseFinal(text)
        XCTAssertEqual(out.status, .inconclusive)
        XCTAssertTrue(out.findings.isEmpty)
    }

    func testUnknownConfidenceFallsBackToUnverified() {
        let text = "```json\n{\"headline\":\"h\",\"status\":\"complete\",\"findings\":[{\"claim\":\"c\",\"sources\":[],\"confidence\":\"bogus\"}]}\n```"
        let out = ResearchOutputParser.parseFinal(text)
        XCTAssertEqual(out.findings[0].confidence, .unverified)
    }

    func testMissingJSONBlockDegradesToProseNeverFabricates() {
        let out = ResearchOutputParser.parseFinal("Just some prose with no json summary.")
        XCTAssertEqual(out.status, .complete)
        XCTAssertTrue(out.findings.isEmpty)          // never invents findings
        XCTAssertEqual(out.headline, "Just some prose with no json summary.")
        XCTAssertTrue(out.writeup.contains("prose"))
    }

    func testEmptyOutputIsInconclusive() {
        let out = ResearchOutputParser.parseFinal("")
        XCTAssertEqual(out.status, .inconclusive)
    }

    func testStreamLineCostAndText() {
        let costLine = #"{"type":"result","subtype":"success","total_cost_usd":0.1234,"result":"done"}"#
        let sl = ResearchOutputParser.parseStreamLine(costLine)
        XCTAssertEqual(sl?.type, "result")
        XCTAssertEqual(sl?.totalCostUSD, Decimal(0.1234))
        XCTAssertEqual(sl?.result, "done")

        let asstLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}"#
        XCTAssertEqual(ResearchOutputParser.parseStreamLine(asstLine)?.assistantText, "hello")

        XCTAssertNil(ResearchOutputParser.parseStreamLine("not json at all"))
    }

    func testStreamLineExtractsThinking() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"let me plan"}]}}"#
        XCTAssertEqual(ResearchOutputParser.parseStreamLine(line)?.thinking, "let me plan")
    }

    func testStreamLineExtractsStreamingDeltas() {
        let textDelta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}}"#
        XCTAssertEqual(ResearchOutputParser.parseStreamLine(textDelta)?.deltaText, "Hel")
        let thinkDelta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}}"#
        XCTAssertEqual(ResearchOutputParser.parseStreamLine(thinkDelta)?.deltaThinking, "hmm")
    }

    func testStreamLineExtractsSessionAndRateLimit() {
        let line = #"{"type":"rate_limit_event","session_id":"abc-123","rate_limit_info":{"status":"allowed_warning","rateLimitType":"seven_day","resetsAt":1783014000}}"#
        let sl = ResearchOutputParser.parseStreamLine(line)
        XCTAssertEqual(sl?.sessionID, "abc-123")
        XCTAssertEqual(sl?.rateLimitType, "seven_day")
        XCTAssertEqual(sl?.rateLimitStatus, "allowed_warning")
        XCTAssertEqual(sl?.rateLimitResetsAt, 1783014000)
    }

    func testStreamLineExtractsToolUseAsSources() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"swift 6 concurrency"}},{"type":"tool_use","name":"WebFetch","input":{"url":"https://swift.org"}}]}}"#
        let tools = ResearchOutputParser.parseStreamLine(line)?.toolUses ?? []
        XCTAssertEqual(tools, [
            .init(name: "WebSearch", detail: "swift 6 concurrency"),
            .init(name: "WebFetch", detail: "https://swift.org"),
        ])
    }
}

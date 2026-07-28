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

    func testParsesCitationsAndTiesThemToTheirFindings() {
        let text = """
        Cold starts fell 40% [^c1].

        ```json
        {"headline":"h","status":"complete","sourcesConsulted":3,\
        "citations":[{"id":"c1","source":"s3","quote":"latency fell 40% year over year"},\
        {"id":"c2","source_id":"s4","quote":"adoption is uneven"}],\
        "findings":[{"claim":"c","sources":["https://x"],"citations":["c1","c2"],"confidence":"high"}]}
        ```
        """
        let out = ResearchOutputParser.parseFinal(text)
        XCTAssertEqual(out.evidence.citations.map(\.id), ["c1", "c2"])
        XCTAssertEqual(out.evidence.citation("c1")?.sourceID, "s3", "the writeup's `source` names the document")
        XCTAssertEqual(out.evidence.citation("c2")?.sourceID, "s4", "the resolved `source_id` spelling decodes too")
        XCTAssertEqual(out.evidence.citation("c1")?.quote, "latency fell 40% year over year")
        XCTAssertEqual(out.evidence.citation("c1")?.match, .unresolved,
                       "a writeup cannot vouch for its own quote — only the run's grounding can")
        XCTAssertTrue(out.evidence.documents.isEmpty, "captured documents come from the run stream, not the model")
        XCTAssertEqual(out.findings.first?.citationIDs, ["c1", "c2"])
    }

    func testAlreadyGroundedCitationsKeepTheirOffsets() {
        let text = """
        Body [^c1].
        ```json
        {"headline":"h","status":"complete",\
        "citations":[{"id":"c1","source_id":"s3","quote":"q","start":1840,"end":1904,"match":"exact","page":4}],\
        "findings":[]}
        ```
        """
        let c = ResearchOutputParser.parseFinal(text).evidence.citation("c1")
        XCTAssertEqual(c?.match, .exact)
        XCTAssertEqual(c?.snapshotRange, 1840..<1904)
        XCTAssertEqual(c?.page, 4)
    }

    func testCitationsWithoutAnIDAreDroppedAndDuplicatesCollapse() {
        let text = """
        ```json
        {"headline":"h","citations":[{"source":"s1","quote":"orphan"},{"id":"c1","quote":"first"},\
        {"id":"c1","source":"s2","quote":"second"},{"id":"c2"}],"findings":[]}
        ```
        """
        let evidence = ResearchOutputParser.parseFinal(text).evidence
        XCTAssertEqual(evidence.citations.map(\.id), ["c1", "c2"], "an id-less citation can't be referenced, so it's dropped")
        XCTAssertEqual(evidence.citation("c1")?.quote, "first", "first spelling of an id wins")
        XCTAssertEqual(evidence.citation("c2")?.quote, "", "a quote-less citation stays, unverifiable")
    }

    func testAbsentOrMalformedCitationsDegradeToNoEvidence() {
        let noField = "```json\n{\"headline\":\"h\",\"status\":\"complete\",\"findings\":[{\"claim\":\"c\",\"sources\":[]}]}\n```"
        let legacy = ResearchOutputParser.parseFinal(noField)
        XCTAssertTrue(legacy.evidence.isEmpty, "a legacy writeup carries no evidence and still parses")
        XCTAssertEqual(legacy.findings.first?.citationIDs, [])

        let wrongShape = "```json\n{\"headline\":\"h\",\"citations\":\"c1\",\"findings\":[]}\n```"
        let out = ResearchOutputParser.parseFinal(wrongShape)
        XCTAssertTrue(out.evidence.isEmpty, "a malformed block degrades to prose, never a fabricated citation")
        XCTAssertTrue(out.findings.isEmpty)

        XCTAssertTrue(ResearchOutputParser.parseFinal("prose only").evidence.isEmpty)
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

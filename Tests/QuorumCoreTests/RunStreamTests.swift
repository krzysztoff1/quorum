import XCTest
@testable import QuorumCore

/// The Swift side of the run-level protocol (fan-out in TS): parse each engine `run` event into a typed
/// value and fold a `topic_result` into a `TopicFindings` the brain can store. Pinned to the protocol
/// the engine builds against.
final class RunStreamTests: XCTestCase {

    func testRunStartAndPhaseAndPlan() {
        XCTAssertEqual(RunStreamParser.parse(#"{"type":"run_start","session_id":"qrun-1","protocol_version":1}"#),
                       .runStart(sessionID: "qrun-1", protocolVersion: 1))
        XCTAssertEqual(RunStreamParser.parse(#"{"type":"phase","phase":"researching"}"#), .phase("researching"))
        let plan = RunStreamParser.parse(#"{"type":"plan","angles":[{"angle_id":"a1","title":"T","prompt":"P"}]}"#)
        XCTAssertEqual(plan, .plan([.init(angleID: "a1", title: "T", prompt: "P")]))
    }

    func testRunStartSurfacesTheProtocolVersionForTheMismatchRefusal() {
        guard case let .runStart(_, version) =
                RunStreamParser.parse(#"{"type":"run_start","session_id":"qrun-1","protocol_version":9}"#)
        else { return XCTFail("expected run_start") }
        XCTAssertEqual(version, 9)
        XCTAssertNotEqual(version, RunStreamParser.supportedProtocolVersion,
                          "a newer engine stream must be detectable, not silently mis-parsed")
        XCTAssertEqual(RunStreamParser.supportedProtocolVersion, 1,
                       "bump in lockstep with the engine's PROTOCOL_VERSION")
        XCTAssertEqual(RunStreamParser.parse(#"{"type":"run_start","session_id":"qrun-legacy"}"#),
                       .runStart(sessionID: "qrun-legacy", protocolVersion: nil),
                       "a missing version is tolerated, never refused")
    }

    func testAngleStatusAndActivityRouteByAngleID() {
        XCTAssertEqual(RunStreamParser.parse(#"{"type":"angle_status","angle_id":"a2","status":"running"}"#),
                       .angleStatus(angleID: "a2", status: "running"))
        // a per-angle live line reuses the per-topic parser; angle_id must be surfaced for routing
        let act = RunStreamParser.parse(#"{"type":"assistant","angle_id":"a2","message":{"content":[{"type":"tool_use","name":"web_search","input":{"query":"q"}}]}}"#)
        guard case let .activity(angleID, line) = act else { return XCTFail("expected activity") }
        XCTAssertEqual(angleID, "a2")
        XCTAssertEqual(line.toolUses.first?.name, "web_search")
    }

    func testTopicResultFoldsToFindingsWithBackendAndUsage() {
        let line = #"{"type":"topic_result","angle_id":"a1","role":"research","backend":"engine","provider":"deepseek","model":"deepseek-chat","session_id":"qeng-9","status":"complete","result":"Body.\n\n```json\n{\"headline\":\"H\",\"status\":\"complete\",\"sourcesConsulted\":1,\"findings\":[{\"claim\":\"c\",\"sources\":[\"https://x\"],\"confidence\":\"high\"}]}\n```","usage":{"provider":"deepseek","model":"deepseek-chat","input_tokens":100,"output_tokens":40,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.002,"search_calls":2,"fetch_calls":1}}"#
        guard case let .topicResult(tr) = RunStreamParser.parse(line) else { return XCTFail("expected topic_result") }
        XCTAssertEqual(tr.backend, "engine")
        XCTAssertFalse(tr.isResumable)                 // BYOK session → chat must seed, not --resume
        let f = tr.toFindings()
        XCTAssertEqual(f.status, .complete)
        XCTAssertEqual(f.findings.first?.confidence, .high)
        XCTAssertEqual(f.usage?.provider, "deepseek")
        XCTAssertEqual(f.usage?.searchCalls, 2)
        XCTAssertEqual(f.sessionID, "qeng-9")
    }

    func testClaudeCodeTopicIsResumable() {
        let line = #"{"type":"topic_result","angle_id":"a1","role":"research","backend":"cli","provider":"anthropic","model":"claude-opus-4-8","session_id":"real-cli-uuid","status":"complete","result":"x"}"#
        guard case let .topicResult(tr) = RunStreamParser.parse(line) else { return XCTFail("expected topic_result") }
        XCTAssertTrue(tr.isResumable)   // subscription CLI session stays --resume-able
    }

    func testRunResultCollectsTopicsAndTotal() {
        let line = #"{"type":"run_result","status":"complete","total_cost_usd":0.5,"topics":[{"type":"topic_result","angle_id":"synthesis","role":"synthesis","backend":"cli","provider":"anthropic","model":"claude-opus-4-8","status":"complete","result":"S"}]}"#
        guard case let .runResult(rr) = RunStreamParser.parse(line) else { return XCTFail("expected run_result") }
        XCTAssertEqual(rr.status, "complete")
        XCTAssertEqual(rr.totalCostUSD, Decimal(0.5))
        XCTAssertEqual(rr.topics.count, 1)
        XCTAssertEqual(rr.topics.first?.role, "synthesis")
    }

    func testNonJSONLineIsNil() {
        XCTAssertNil(RunStreamParser.parse("not json"))
    }
}

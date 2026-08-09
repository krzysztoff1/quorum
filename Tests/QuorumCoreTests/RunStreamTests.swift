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
        XCTAssertEqual(RunStreamParser.supportedProtocolVersion, 3,
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

    // MARK: PRD 03 — captured documents and resolved citations

    func testDocumentEventCarriesTheCapturedSnapshot() {
        let line = #"{"type":"document","angle_id":"a1","document":{"source_id":"s3","url":"https://nature.com/x","title":"Cold starts","content_type":"pdf","fetched_at":"2026-07-27T10:00:00Z","snapshot_path":"sources/s3.md","original_path":"sources/s3.pdf","text_length":48213,"byte_size":1048576,"page_offsets":[0,1820,3944]}}"#
        guard case let .document(angleID, doc) = RunStreamParser.parse(line) else { return XCTFail("expected document") }
        XCTAssertEqual(angleID, "a1", "documents are namespaced by angle, like every other run event")
        XCTAssertEqual(doc.sourceID, "s3")
        XCTAssertEqual(doc.contentType, .pdf)
        XCTAssertEqual(doc.snapshotPath, "sources/s3.md", "run-relative — the app never rewrites it")
        XCTAssertEqual(doc.originalPath, "sources/s3.pdf")
        XCTAssertEqual(doc.textLength, 48213)
        XCTAssertEqual(doc.page(containing: 2000), 2)
    }

    func testDocumentEventWithoutADocumentIsIgnored() {
        XCTAssertEqual(RunStreamParser.parse(#"{"type":"document","angle_id":"a1"}"#), .other)
    }

    func testTopicResultCitationsWinOverTheWriteupsOwnJSON() {
        let line = #"{"type":"topic_result","angle_id":"a1","role":"research","backend":"engine","status":"complete","result":"Claim [^c1] and aside [^c2].\n\n```json\n{\"headline\":\"H\",\"status\":\"complete\",\"citations\":[{\"id\":\"c1\",\"source\":\"s3\",\"quote\":\"q1\"},{\"id\":\"c2\",\"source\":\"s4\",\"quote\":\"q2\"}],\"findings\":[{\"claim\":\"c\",\"sources\":[\"https://x\"],\"citations\":[\"c1\"],\"confidence\":\"high\"}]}\n```","citations":[{"id":"c1","source_id":"s3","quote":"q1","start":1840,"end":1904,"match":"exact","page":4}]}"#
        guard case let .topicResult(tr) = RunStreamParser.parse(line) else { return XCTFail("expected topic_result") }
        XCTAssertEqual(tr.evidence.citations.map(\.id), ["c1"], "the stream reports what it actually resolved")

        let f = tr.toFindings()
        XCTAssertEqual(f.evidence.citation("c1")?.match, .exact, "the stream carries the offsets, so it wins")
        XCTAssertEqual(f.evidence.citation("c1")?.snapshotRange, 1840..<1904)
        XCTAssertEqual(f.evidence.citation("c2")?.match, .unresolved,
                       "a citation only the writeup claimed survives, honestly unresolved")
        XCTAssertEqual(f.findings.first?.citationIDs, ["c1"])
    }

    func testRunResultCarriesTheRunWideDocumentRegistry() {
        let line = #"{"type":"run_result","status":"complete","total_cost_usd":0.5,"documents":[{"source_id":"s1","url":"https://a","title":"A","content_type":"html","snapshot_path":"sources/s1.md"},{"source_id":"","url":"https://ghost"}],"topics":[{"type":"topic_result","angle_id":"a1","role":"research","backend":"engine","status":"complete","result":"x","citations":[{"id":"c1","source_id":"s1","quote":"q","start":1,"end":3,"match":"normalized"}]}]}"#
        guard case let .runResult(rr) = RunStreamParser.parse(line) else { return XCTFail("expected run_result") }
        XCTAssertEqual(rr.evidence.documents.map(\.sourceID), ["s1"], "an id-less document is unreachable, so it's dropped")
        XCTAssertEqual(rr.topics.first?.evidence.citations.first?.match, .normalized)
        XCTAssertTrue(rr.evidence.citations.isEmpty, "citations stay on their topic")
    }

    /// What the app's engine-run consumer does as the stream arrives: fold `document` events into ONE
    /// run-wide source registry, and keep each topic's quotes on that topic — angle-local `c1` ids repeat
    /// across angles, so a run-level citation merge would resolve one angle's marker to another's quote.
    func testStreamReducesToARunWideRegistryWithPerTopicQuotes() {
        let lines = [
            #"{"type":"run_start","session_id":"qrun-1","protocol_version":2}"#,
            #"{"type":"document","angle_id":"a1","document":{"source_id":"s1","url":"https://a.example","title":"A","content_type":"html","snapshot_path":"sources/s1.md"}}"#,
            #"{"type":"document","angle_id":"a2","document":{"source_id":"s2","url":"https://b.example","title":"B","content_type":"pdf","snapshot_path":"sources/s2.md"}}"#,
            #"{"type":"topic_result","angle_id":"a1","role":"research","backend":"engine","status":"complete","result":"x","citations":[{"id":"c1","source_id":"s1","quote":"from A","start":1,"end":7,"match":"exact"}]}"#,
            #"{"type":"topic_result","angle_id":"a2","role":"research","backend":"engine","status":"complete","result":"x","citations":[{"id":"c1","source_id":"s2","quote":"from B","start":2,"end":8,"match":"fuzzy"}]}"#,
            #"{"type":"run_result","status":"complete","total_cost_usd":1,"documents":[{"source_id":"s1","url":"https://a.example","title":"A","content_type":"html","snapshot_path":"sources/s1.md"}],"topics":[]}"#,
        ]
        var registry = EvidenceIndex()
        var perTopic: [String: EvidenceIndex] = [:]
        for line in lines {
            switch RunStreamParser.parse(line) {
            case .document(_, let doc): registry = registry.merging(EvidenceIndex(documents: [doc]))
            case .topicResult(let tr): perTopic[tr.angleID] = tr.evidence.merging(registry)
            case .runResult(let rr): registry = registry.merging(rr.evidence)
            default: break
            }
        }
        XCTAssertEqual(registry.documents.map(\.sourceID), ["s1", "s2"], "one deduped registry, whoever fetched it")
        XCTAssertEqual(perTopic["a1"]?.citation("c1")?.quote, "from A")
        XCTAssertEqual(perTopic["a2"]?.citation("c1")?.quote, "from B")
        XCTAssertEqual(perTopic["a2"]?.document("s1")?.host, "a.example", "every topic can reach every source")
    }

    func testLegacyTopicResultHasNoEvidence() {
        let line = #"{"type":"topic_result","angle_id":"a1","role":"research","backend":"cli","status":"complete","result":"Body.\n\n```json\n{\"headline\":\"H\",\"status\":\"complete\",\"findings\":[]}\n```"}"#
        guard case let .topicResult(tr) = RunStreamParser.parse(line) else { return XCTFail("expected topic_result") }
        XCTAssertTrue(tr.evidence.isEmpty)
        XCTAssertTrue(tr.toFindings().evidence.isEmpty, "no capture → no evidence, never an invented one")
    }
}

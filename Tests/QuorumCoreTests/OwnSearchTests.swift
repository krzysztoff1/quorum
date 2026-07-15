import XCTest
@testable import QuorumCore

/// Own search on the CLI path (PRD 02 R7): with a search key the CLI routes web search through the
/// bundled engine's MCP server; without one it stays on built-in WebSearch, byte-identical to today.
/// The `--mcp-config` JSON rides argv, so it must never carry a secret.
final class OwnSearchTests: XCTestCase {

    private func researchTopic() -> PreparedTopic {
        let cfg = GuardrailMapper.runConfig(preset: .standard, perTopicSpendCap: Decimal(string: "10")!,
                                            perTopicTimeout: .seconds(600), depthOverride: nil)
        return PreparedTopic(id: "t1", question: "Q", context: nil,
                             projectURL: URL(fileURLWithPath: "/tmp/brain"), useProjectContext: false,
                             preset: .standard, runConfig: cfg, role: .research)
    }

    func testWithOwnSearchSwapsOnlyWebSearch() {
        let swapped = GuardrailMapper.withOwnSearch(["WebSearch", "WebFetch", "Read"])
        XCTAssertEqual(swapped, ["mcp__quorum__web_search", "WebFetch", "Read"])
    }

    func testMcpConfigIsValidJSONWithNoSecret() throws {
        let json = GuardrailMapper.mcpConfigJSON(enginePath: "/Applications/Quorum.app/quorum-engine")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let servers = obj?["mcpServers"] as? [String: Any]
        let quorum = servers?["quorum"] as? [String: Any]
        XCTAssertEqual(quorum?["command"] as? String, "/Applications/Quorum.app/quorum-engine")
        XCTAssertEqual(quorum?["args"] as? [String], ["mcp-serve"])
        XCTAssertFalse(json.lowercased().contains("key"), "the config must not carry any secret")
    }

    func testCLIArgsUseMCPToolWhenOwnSearchOn() {
        let args = CLIInvocation.claudeArguments(for: researchTopic(), modelArgs: [], synthesisModelArgs: [],
                                                 ownSearchBinary: "/bin/quorum-engine")
        XCTAssertTrue(args.contains("--mcp-config"))
        let allowed = args[args.firstIndex(of: "--allowedTools")! + 1]
        XCTAssertTrue(allowed.contains("mcp__quorum__web_search"))
        XCTAssertFalse(allowed.contains("WebSearch"))
        XCTAssertTrue(allowed.contains("WebFetch"))   // fetch stays built-in in v1
    }

    func testCLIArgsUnchangedWhenNoSearchKey() {
        let args = CLIInvocation.claudeArguments(for: researchTopic(), modelArgs: [], synthesisModelArgs: [])
        XCTAssertFalse(args.contains("--mcp-config"))
        let allowed = args[args.firstIndex(of: "--allowedTools")! + 1]
        XCTAssertTrue(allowed.contains("WebSearch"))
        XCTAssertFalse(allowed.contains("mcp__quorum__web_search"))
    }

    func testUsageAddingCallsMergesMCPSearches() {
        let base = TopicUsage(provider: "anthropic", model: "claude-haiku-4-5", inputTokens: 100,
                              outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                              searchCalls: 0, fetchCalls: 0, costUSD: Decimal(string: "0.5")!)
        let merged = base.addingCalls(search: 4, fetch: 0)
        XCTAssertEqual(merged.searchCalls, 4)
        XCTAssertEqual(merged.inputTokens, 100)   // tokens untouched
        XCTAssertEqual(merged.costUSD, Decimal(string: "0.5")!)
    }
}

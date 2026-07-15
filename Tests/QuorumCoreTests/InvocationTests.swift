import XCTest
@testable import QuorumCore

/// Guards the executor argv against silent drift. The Subscription profile must keep producing the same
/// CLI shape it always has (PRD 02 acceptance), and the engine must only ever get the flag subset it
/// accepts (PRD 01 R1) — never a CLI-only flag.
final class InvocationTests: XCTestCase {

    private func topic(_ role: TopicRole = .research, useProject: Bool = false) -> PreparedTopic {
        let cfg = GuardrailMapper.runConfig(preset: .standard, perTopicSpendCap: Decimal(string: "10")!,
                                            perTopicTimeout: .seconds(600), depthOverride: nil)
        return PreparedTopic(id: "t1", question: "What is Swift?", context: role == .research ? nil : "ctx",
                             projectURL: URL(fileURLWithPath: "/tmp/brain"), useProjectContext: useProject,
                             preset: .standard, runConfig: cfg, role: role)
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func testSubscriptionResearchArgsAreStable() {
        let args = CLIInvocation.claudeArguments(for: topic(), modelArgs: ["--model", "claude-sonnet-5"],
                                                 synthesisModelArgs: [])
        XCTAssertEqual(args.first, "-p")
        XCTAssertEqual(value(after: "--output-format", in: args), "stream-json")
        XCTAssertEqual(value(after: "--permission-mode", in: args), "dontAsk")
        XCTAssertTrue(args.contains("--include-partial-messages"))
        XCTAssertEqual(Array(args.suffix(2)), ["--model", "claude-sonnet-5"])
        let allowed = value(after: "--allowedTools", in: args) ?? ""
        XCTAssertTrue(allowed.contains("WebSearch"))
        XCTAssertFalse(allowed.contains("Write"))
        XCTAssertFalse(allowed.contains("Bash"))
    }

    func testSubscriptionProjectContextAddsDir() {
        let args = CLIInvocation.claudeArguments(for: topic(.research, useProject: true),
                                                 modelArgs: [], synthesisModelArgs: [])
        XCTAssertEqual(value(after: "--add-dir", in: args), "/tmp/brain")
    }

    func testEngineResearchUsesAcceptedSubsetOnly() {
        let args = EngineInvocation.arguments(for: topic(), model: "deepseek/deepseek-chat",
                                              synthesisModel: "anthropic/claude-opus-4-8")
        XCTAssertEqual(args.first, "-p")
        XCTAssertEqual(value(after: "--model", in: args), "deepseek/deepseek-chat")
        XCTAssertNotNil(value(after: "--append-system-prompt", in: args))
        XCTAssertNotNil(value(after: "--max-budget-usd", in: args))
        for cliOnly in ["--output-format", "--permission-mode", "--include-partial-messages", "--verbose"] {
            XCTAssertFalse(args.contains(cliOnly), "engine must not receive \(cliOnly)")
        }
    }

    func testEngineSynthesisUsesSynthesisModel() {
        let args = EngineInvocation.arguments(for: topic(.synthesis), model: "deepseek/deepseek-chat",
                                              synthesisModel: "anthropic/claude-opus-4-8")
        XCTAssertEqual(value(after: "--model", in: args), "anthropic/claude-opus-4-8")
    }

    func testEnginePlanUsesLowEffortAndModel() {
        let args = EngineInvocation.planArguments(question: "Q", count: 4, priorNotes: [],
                                                  model: "deepseek/deepseek-chat")
        XCTAssertEqual(value(after: "--effort", in: args), "low")
        XCTAssertEqual(value(after: "--model", in: args), "deepseek/deepseek-chat")
    }
}

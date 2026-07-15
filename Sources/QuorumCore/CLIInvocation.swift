import Foundation

/// Builds the exact `claude` argv for a prepared topic — pure, so the Subscription profile's args can
/// be snapshot-tested to prove they never drift (PRD 02 acceptance). Model flags arrive as `[String]`
/// so this stays free of the app-target `ModelChoice`. The executor is now just the subprocess around it.
public enum CLIInvocation {

    /// `ownSearchBinary` non-nil → route web search through the bundled engine's MCP server instead of
    /// Anthropic's server WebSearch (PRD 02 R7). Only the research role searches, so the swap + config
    /// apply there; nil keeps today's built-in-WebSearch args byte-identical.
    public static func claudeArguments(for topic: PreparedTopic, modelArgs: [String],
                                       synthesisModelArgs: [String],
                                       ownSearchBinary: String? = nil) -> [String] {
        let cfg = topic.runConfig
        if topic.role == .verify {
            return [
                "-p", ResearchPrompts.verify(for: topic),
                "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--permission-mode", "dontAsk",
                "--effort", "low",
                "--max-budget-usd", NSDecimalNumber(decimal: cfg.perTopicSpendCapUSD).stringValue,
                "--max-turns", String(cfg.maxTurns),
                "--append-system-prompt", ResearchPrompts.verifySystem(),
            ] + modelArgs
        }
        if topic.role == .synthesis {
            let tools = GuardrailMapper.readOnlyTools
            return [
                "-p", ResearchPrompts.synthesis(for: topic),
                "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--permission-mode", "dontAsk",
                "--tools", tools.joined(separator: ","),
                "--allowedTools", tools.joined(separator: " "),
                "--effort", cfg.effort.rawValue,
                "--max-budget-usd", NSDecimalNumber(decimal: cfg.perTopicSpendCapUSD).stringValue,
                "--max-turns", String(cfg.maxTurns),
                "--append-system-prompt", ResearchPrompts.synthesisSystem(),
            ] + synthesisModelArgs
        }
        if topic.role == .plain {
            let tools = GuardrailMapper.readOnlyTools
            return [
                "-p", topic.context ?? topic.question,
                "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--permission-mode", "dontAsk",
                "--tools", tools.joined(separator: ","),
                "--allowedTools", tools.joined(separator: " "),
                "--effort", cfg.effort.rawValue,
                "--max-budget-usd", NSDecimalNumber(decimal: cfg.perTopicSpendCapUSD).stringValue,
                "--max-turns", String(cfg.maxTurns),
            ] + modelArgs
        }
        var tools = topic.useProjectContext
            ? cfg.allowedTools
            : cfg.allowedTools.filter { $0 == "WebSearch" || $0 == "WebFetch" }
        if ownSearchBinary != nil { tools = GuardrailMapper.withOwnSearch(tools) }

        var args: [String] = [
            "-p", ResearchPrompts.research(for: topic),
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", "dontAsk",
            "--tools", tools.joined(separator: ","),
            "--allowedTools", tools.joined(separator: " "),
            "--effort", cfg.effort.rawValue,
            "--max-budget-usd", NSDecimalNumber(decimal: cfg.perTopicSpendCapUSD).stringValue,
            "--max-turns", String(cfg.maxTurns),
            "--append-system-prompt", ResearchPrompts.system(for: topic),
        ]
        args += modelArgs
        if let bin = ownSearchBinary {
            args += ["--mcp-config", GuardrailMapper.mcpConfigJSON(enginePath: bin)]
        }
        if topic.useProjectContext { args += ["--add-dir", topic.projectURL.path] }
        return args
    }

    public static func planArguments(question: String, count: Int, priorNotes: [URL],
                                     modelArgs: [String]) -> [String] {
        let tools = GuardrailMapper.readOnlyTools
        return [
            "-p", ResearchPrompts.plan(question: question, count: count, priorNotes: priorNotes),
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--permission-mode", "dontAsk",
            "--tools", tools.joined(separator: ","),
            "--allowedTools", tools.joined(separator: " "),
            "--effort", "low",
            "--max-budget-usd", "0.15",
            "--append-system-prompt", ResearchPrompts.planSystem(count: count),
        ] + modelArgs
    }
}

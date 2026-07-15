import Foundation

/// Builds the `quorum-engine` argv for a prepared topic — the CLI-compatible flag subset the engine
/// accepts (PRD 01 R1): `-p --model --effort --max-budget-usd --max-turns --tools --append-system-prompt`.
/// Same prompts as the CLI path (`ResearchPrompts`), so a BYOK angle runs the identical contract.
/// Pure → snapshot-testable.
public enum EngineInvocation {

    public static func arguments(for topic: PreparedTopic, model: String, synthesisModel: String) -> [String] {
        let cfg = topic.runConfig
        let budget = NSDecimalNumber(decimal: cfg.perTopicSpendCapUSD).stringValue
        switch topic.role {
        case .verify:
            return [
                "-p", ResearchPrompts.verify(for: topic),
                "--model", synthesisModel,
                "--effort", "low",
                "--max-budget-usd", budget,
                "--max-turns", String(cfg.maxTurns),
                "--append-system-prompt", ResearchPrompts.verifySystem(),
            ]
        case .synthesis:
            return [
                "-p", ResearchPrompts.synthesis(for: topic),
                "--model", synthesisModel,
                "--effort", cfg.effort.rawValue,
                "--max-budget-usd", budget,
                "--max-turns", String(cfg.maxTurns),
                "--append-system-prompt", ResearchPrompts.synthesisSystem(),
            ]
        case .plain:
            return [
                "-p", topic.context ?? topic.question,
                "--model", model,
                "--effort", cfg.effort.rawValue,
                "--max-budget-usd", budget,
                "--max-turns", String(cfg.maxTurns),
            ]
        case .research:
            let tools = cfg.allowedTools.filter { $0 == "WebSearch" || $0 == "WebFetch" }   // engine is web-only
            return [
                "-p", ResearchPrompts.research(for: topic),
                "--model", model,
                "--effort", cfg.effort.rawValue,
                "--max-budget-usd", budget,
                "--max-turns", String(cfg.maxTurns),
                "--tools", tools.joined(separator: ","),
                "--append-system-prompt", ResearchPrompts.system(for: topic),
            ]
        }
    }

    public static func planArguments(question: String, count: Int, priorNotes: [URL], model: String) -> [String] {
        [
            "-p", ResearchPrompts.plan(question: question, count: count, priorNotes: priorNotes),
            "--model", model,
            "--effort", "low",
            "--max-budget-usd", "0.15",
            "--append-system-prompt", ResearchPrompts.planSystem(count: count),
        ]
    }
}

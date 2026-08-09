import Foundation

/// Pure function: a topic's guardrails + preset + depth → the concrete read-only run config.
/// This is where "limits are walls" starts: the tool allowlist is read-only *by construction*,
/// so a run is incapable of damage before it ever starts.
public enum GuardrailMapper {

    /// Least-power read-only tool set: search / fetch / read only. Never write/edit/bash.
    public static let readOnlyTools = ["WebSearch", "WebFetch", "Read", "Grep", "Glob"]

    /// The MCP search tool the bundled engine exposes in `mcp-serve` mode (PRD 02 R7). When a search
    /// key exists, CLI runs use this instead of Anthropic's ~$10/1k server WebSearch. WebFetch stays
    /// built-in in v1 (token-priced, no per-call fee).
    public static let mcpSearchTool = "mcp__quorum__web_search"

    /// Swap `WebSearch` for the own-search MCP tool; everything else (incl. built-in `WebFetch`) is
    /// untouched. No-op if `WebSearch` isn't present — so the no-key path stays byte-identical.
    public static func withOwnSearch(_ tools: [String]) -> [String] {
        tools.map { $0 == "WebSearch" ? mcpSearchTool : $0 }
    }

    /// The `--mcp-config` JSON pointing `claude` at the bundled engine in stdio MCP mode. Rides argv,
    /// so it MUST carry no secrets — the search key reaches the server via inherited environment only.
    public static func mcpConfigJSON(enginePath: String) -> String {
        let escaped = enginePath.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"mcpServers\":{\"quorum\":{\"command\":\"\(escaped)\",\"args\":[\"mcp-serve\"]}}}"
    }

    public struct PresetSpec: Equatable {
        public let effort: Effort
        public let sourceBudget: Int
        public let depth: Depth
        public let maxTurns: Int
        public let perTopicSpendCapUSD: Decimal
        public let runSpendCapUSD: Decimal
    }

    /// The revisable preset→dials table. The 4-tier shape and the low↔max span are the decision. The
    /// spend caps are the same dial as effort/sourceBudget now — no separate manual $ fields; `draft`'s
    /// are a rounding-error smoke-test wall, `standard`'s are the measured real-run figures (benchmark).
    public static func spec(for preset: EffortPreset) -> PresetSpec {
        switch preset {
        case .draft:
            return PresetSpec(effort: .low, sourceBudget: 5, depth: .scan, maxTurns: 20,
                              perTopicSpendCapUSD: Decimal(string: "0.15")!, runSpendCapUSD: 1)
        case .standard:
            return PresetSpec(effort: .medium, sourceBudget: 10, depth: .thorough, maxTurns: 60,
                              perTopicSpendCapUSD: 10, runSpendCapUSD: 40)
        case .deep:
            return PresetSpec(effort: .xhigh, sourceBudget: 30, depth: .thorough, maxTurns: 120,
                              perTopicSpendCapUSD: 15, runSpendCapUSD: 60)
        case .max:
            return PresetSpec(effort: .max, sourceBudget: 50, depth: .thorough, maxTurns: 200,
                              perTopicSpendCapUSD: 20, runSpendCapUSD: 80)
        }
    }

    public static func runConfig(preset: EffortPreset, perTopicSpendCap: Decimal,
                                 perTopicTimeout: Duration, depthOverride: Depth?) -> RunConfig {
        let s = spec(for: preset)
        return RunConfig(
            allowedTools: readOnlyTools,
            effort: s.effort,
            sourceBudget: s.sourceBudget,
            maxTurns: s.maxTurns,
            perTopicSpendCapUSD: perTopicSpendCap,
            perTopicTimeout: perTopicTimeout,
            depth: depthOverride ?? s.depth
        )
    }

    /// Resolve a queue topic against the run config. A per-topic preset override beats the
    /// run default; a per-topic depth overrides the preset's default depth.
    public static func prepare(topic: Topic, run: RunSettings, priorNotes: [URL] = []) -> PreparedTopic {
        let preset = topic.presetOverride ?? run.defaultPreset
        let cfg = runConfig(preset: preset,
                            perTopicSpendCap: run.perTopicSpendCapUSD,
                            perTopicTimeout: run.perTopicTimeout,
                            depthOverride: topic.depth)
        return PreparedTopic(id: topic.id, question: topic.question, context: topic.context,
                             projectURL: run.projectURL, priorNotes: priorNotes,
                             useProjectContext: topic.useProjectContext, preset: preset, runConfig: cfg)
    }
}

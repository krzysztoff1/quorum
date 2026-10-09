import Foundation

/// Which engine serves a given topic role.
public enum ExecutorKind: String, Sendable, Equatable { case cli, engine }

/// Who judges the answer, and where that judge runs (PRD 06 R7). Tool-less, cheap, and never the family
/// that wrote what it reads.
public struct ValidatorRoute: Equatable, Sendable {
    public let executor: ExecutorKind
    public let model: String

    public init(executor: ExecutorKind, model: String) {
        self.executor = executor
        self.model = model
    }
}

/// Model addressing is `provider/model-id` (e.g. `deepseek/deepseek-chat`, `claude-code/claude-opus-4-8`).
public enum ModelID {
    /// The provider segment, lowercased ("" if none). `claude-code` means the Claude subscription CLI,
    /// `codex` the OpenAI Codex CLI — both OAuth logins the engine spawns, neither a metered API key.
    public static func provider(_ model: String) -> String {
        String(model.split(separator: "/").first ?? "").lowercased()
    }
    public static func isSubscription(_ model: String) -> Bool {
        provider(model) == "claude-code" || provider(model) == "codex"
    }
}

/// The Codex models Quorum addresses by alias. The engine resolves each to its slug (`gpt-5.6-terra`)
/// and clamps the run's effort to what that model actually offers.
public enum CodexModel: String, Codable, Sendable, CaseIterable, Identifiable {
    case luna, terra, sol

    public static let `default`: CodexModel = .terra

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .luna:  return "GPT-5.6-Luna"
        case .terra: return "GPT-5.6-Terra"
        case .sol:   return "GPT-5.6-Sol"
        }
    }

    public var blurb: String {
        switch self {
        case .luna:  return "Fastest of the three — good for wide, shallow fan-outs."
        case .terra: return "The balanced default."
        case .sol:   return "Deepest agentic reasoning; slowest and the heaviest on your Codex limit."
        }
    }

    public var engineAddress: String { "codex/\(rawValue)" }
}

/// The visible cost/quality routing dial (PRD 02 R2). A profile decides, per topic role, whether work
/// runs on the Claude Code CLI (subscription OAuth, $0 marginal against the weekly cap) or the BYOK
/// engine (metered cheap tokens). Few, named, and stamped onto every report — dials, not a mixing desk.
public enum RunProfile: String, Codable, Sendable, CaseIterable, Identifiable {
    case subscription   // default — today's behavior, all-CLI, the "no API key" promise intact
    case budget         // engine for planner + angles (cheap), CLI-subscription for synthesis + verify
    case fullBYOK       // all-engine — for when the weekly limit must stay untouched
    case codex          // the OpenAI Codex subscription, addressed through the engine — still no API key
    case benchmark      // pinned pure-Claude — mixed engines would break the architecture-isolation claim

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .subscription: return "Subscription"
        case .budget:       return "Budget"
        case .fullBYOK:     return "Full BYOK"
        case .codex:        return "Codex"
        case .benchmark:    return "Benchmark"
        }
    }

    public var blurb: String {
        switch self {
        case .subscription: return "Your Claude Code login. No API key, $0 marginal, counts against the weekly limit."
        case .budget:       return "Cheap BYOK models research the angles; your subscription synthesizes. Needs provider + search keys."
        case .fullBYOK:     return "Every step on BYOK models — the weekly limit stays untouched. Needs provider + search keys."
        case .codex:        return "Your OpenAI Codex login. No API key, $0 marginal, and it leaves the Claude weekly limit untouched."
        case .benchmark:    return "Pure Claude, pinned — keeps published benchmark arms architecture-isolated."
        }
    }

    /// Whether this profile spends against the BYOK engine (so it stays disabled until keys exist).
    public var needsEngineKeys: Bool { self == .budget || self == .fullBYOK }

    /// Whether this profile spends against the OpenAI Codex CLI (so it stays disabled until it exists).
    public var needsCodexCLI: Bool { self == .codex }

    /// Which executor serves a topic of this role. Project-context topics route to the CLI — the BYOK
    /// engine is web-only in v1, so it cannot read the working directory. Codex is the exception: its
    /// backend opens the project read-only, so handing its topics to the Claude CLI would silently run
    /// a different model than the one the report names.
    public func executor(for role: TopicRole, useProjectContext: Bool) -> ExecutorKind {
        if self == .codex { return .engine }
        if useProjectContext { return .cli }
        switch self {
        case .subscription, .benchmark: return .cli
        case .budget:   return role == .research ? .engine : .cli   // angles cheap, synthesis/verify on subscription
        case .fullBYOK: return .engine
        case .codex:    return .engine
        }
    }

    /// Which executor runs the angle planner (a cheap decompose call; doesn't touch the project).
    public var plannerKind: ExecutorKind { needsEngineKeys || needsCodexCLI ? .engine : .cli }

    /// The small CLI model a run with no API key judges on. The subscription is already paid for, so a
    /// zero-key run still gets its answer checked rather than shipped unvalidated.
    public static let subscriptionValidatorModel = "claude-code/claude-haiku-4-5"

    /// Cheap judges, one per family, so there is always one that did not write what it reads.
    public static let crossFamilyValidatorModels = ["deepseek/deepseek-chat", "openrouter/openai/gpt-5-mini"]

    /// Who judges an answer written by `authorModel`. A validator reads only what it is handed — no tools,
    /// no project — so nothing here routes on project context. BYOK profiles cross families because the
    /// benchmark's Claude-judging-Claude arm is exactly the bias this is guarding against; the rest judge
    /// on the CLI, whose small model costs the run no key and no metered spend.
    public func validator(judging authorModel: String) -> ValidatorRoute {
        switch self {
        case .subscription, .benchmark, .codex:
            return ValidatorRoute(executor: .cli, model: Self.subscriptionValidatorModel)
        case .budget, .fullBYOK:
            return ValidatorRoute(executor: .engine, model: Self.crossFamily(from: authorModel))
        }
    }

    private static func crossFamily(from authorModel: String) -> String {
        let author = ModelID.provider(authorModel)
        return crossFamilyValidatorModels.first { ModelID.provider($0) != author }
            ?? crossFamilyValidatorModels[0]
    }

    public struct Availability: Equatable, Sendable {
        public let ok: Bool
        public let reason: String?   // one line explaining why it's disabled (R4), nil when ok
    }

    /// Whether this profile can be selected given the stored keys (PRD 02 R4). Subscription/Benchmark
    /// always run; the BYOK profiles need a model provider key AND a search key before they light up;
    /// Codex needs no key at all, only its CLI installed and signed in.
    public func availability(hasModelKey: Bool, hasSearchKey: Bool, hasCodexCLI: Bool = true) -> Availability {
        if needsCodexCLI {
            return hasCodexCLI
                ? Availability(ok: true, reason: nil)
                : Availability(ok: false, reason: "Install the Codex CLI and run `codex` once to sign in")
        }
        guard needsEngineKeys else { return Availability(ok: true, reason: nil) }
        switch (hasModelKey, hasSearchKey) {
        case (true, true):   return Availability(ok: true, reason: nil)
        case (false, false): return Availability(ok: false, reason: "Add a model provider key and a search key in Settings")
        case (false, true):  return Availability(ok: false, reason: "Add a model provider key (DeepSeek/OpenRouter/Anthropic) in Settings")
        case (true, false):  return Availability(ok: false, reason: "Add a search key (Tavily or Brave) in Settings")
        }
    }
}

public enum ExperimentalProfiles {
    public static let defaultsKey = "experimentalRunProfiles"

    public static let profiles: [RunProfile] = [.codex, .budget, .fullBYOK]

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    public static func selectable(experimentsEnabled: Bool) -> [RunProfile] {
        experimentsEnabled ? [.subscription] + profiles : [.subscription]
    }

    public static func effective(_ profile: RunProfile, experimentsEnabled: Bool) -> RunProfile {
        experimentsEnabled || !profiles.contains(profile) ? profile : .subscription
    }
}

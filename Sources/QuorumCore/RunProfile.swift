import Foundation

/// Which engine serves a given topic role.
public enum ExecutorKind: String, Sendable, Equatable { case cli, engine }

/// Model addressing is `provider/model-id` (e.g. `deepseek/deepseek-chat`, `claude-code/claude-opus-4-8`).
public enum ModelID {
    /// The provider segment, lowercased ("" if none). `claude-code` means the Claude subscription CLI.
    public static func provider(_ model: String) -> String {
        String(model.split(separator: "/").first ?? "").lowercased()
    }
    public static func isSubscription(_ model: String) -> Bool { provider(model) == "claude-code" }
}

/// The visible cost/quality routing dial (PRD 02 R2). A profile decides, per topic role, whether work
/// runs on the Claude Code CLI (subscription OAuth, $0 marginal against the weekly cap) or the BYOK
/// engine (metered cheap tokens). Few, named, and stamped onto every report — dials, not a mixing desk.
public enum RunProfile: String, Codable, Sendable, CaseIterable, Identifiable {
    case subscription   // default — today's behavior, all-CLI, the "no API key" promise intact
    case budget         // engine for planner + angles (cheap), CLI-subscription for synthesis + verify
    case fullBYOK       // all-engine — for when the weekly limit must stay untouched
    case benchmark      // pinned pure-Claude — mixed engines would break the architecture-isolation claim

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .subscription: return "Subscription"
        case .budget:       return "Budget"
        case .fullBYOK:     return "Full BYOK"
        case .benchmark:    return "Benchmark"
        }
    }

    public var blurb: String {
        switch self {
        case .subscription: return "Your Claude Code login. No API key, $0 marginal, counts against the weekly limit."
        case .budget:       return "Cheap BYOK models research the angles; your subscription synthesizes. Needs provider + search keys."
        case .fullBYOK:     return "Every step on BYOK models — the weekly limit stays untouched. Needs provider + search keys."
        case .benchmark:    return "Pure Claude, pinned — keeps published benchmark arms architecture-isolated."
        }
    }

    /// Whether this profile spends against the BYOK engine (so it stays disabled until keys exist).
    public var needsEngineKeys: Bool { self == .budget || self == .fullBYOK }

    /// Which executor serves a topic of this role. Project-context topics always route to the CLI —
    /// the engine is web-only in v1, so it cannot read the working directory regardless of profile.
    public func executor(for role: TopicRole, useProjectContext: Bool) -> ExecutorKind {
        if useProjectContext { return .cli }
        switch self {
        case .subscription, .benchmark: return .cli
        case .budget:   return role == .research ? .engine : .cli   // angles cheap, synthesis/verify on subscription
        case .fullBYOK: return .engine
        }
    }

    /// Which executor runs the angle planner (a cheap decompose call; doesn't touch the project).
    public var plannerKind: ExecutorKind { needsEngineKeys ? .engine : .cli }

    public struct Availability: Equatable, Sendable {
        public let ok: Bool
        public let reason: String?   // one line explaining why it's disabled (R4), nil when ok
    }

    /// Whether this profile can be selected given the stored keys (PRD 02 R4). Subscription/Benchmark
    /// always run; the BYOK profiles need a model provider key AND a search key before they light up.
    public func availability(hasModelKey: Bool, hasSearchKey: Bool) -> Availability {
        guard needsEngineKeys else { return Availability(ok: true, reason: nil) }
        switch (hasModelKey, hasSearchKey) {
        case (true, true):   return Availability(ok: true, reason: nil)
        case (false, false): return Availability(ok: false, reason: "Add a model provider key and a search key in Settings")
        case (false, true):  return Availability(ok: false, reason: "Add a model provider key (DeepSeek/OpenRouter/Anthropic) in Settings")
        case (true, false):  return Availability(ok: false, reason: "Add a search key (Tavily or Brave) in Settings")
        }
    }
}

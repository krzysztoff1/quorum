import Foundation

// MARK: - Effort / presets / depth

/// Claude Code `--effort` levels.
public enum Effort: String, Codable, Sendable, CaseIterable {
    case low, medium, high, xhigh, max
}

public enum Depth: String, Codable, Sendable, CaseIterable {
    case scan, thorough
}

/// The user-facing cost/quality dial. The concrete (effort, sourceBudget, depth) each preset maps
/// to lives in `GuardrailMapper` — one source of truth, directly unit-tested.
public enum EffortPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case draft      // "ULTRA low" — cheap dry-runs
    case standard   // sensible default
    case deep       // agentic-research sweet spot
    case max        // most thorough, for topics that matter

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .draft:    return "Draft (ULTRA low)"
        case .standard: return "Standard"
        case .deep:     return "Deep"
        case .max:      return "Max"
        }
    }
}

/// A structured deliverable the fan-out synthesis should produce. **Same engine** (blind angles → one
/// summariser) — the template only shapes the *synthesiser's* output; angles, walls, and citation
/// grounding are untouched. `.general` is the default reconciled writeup with no imposed structure.
public enum ResearchTemplate: String, Codable, Sendable, CaseIterable, Identifiable {
    case general            // default — a reconciled, cited answer with no imposed shape
    case comparisonMatrix   // options × criteria table + a recommendation
    case decisionBrief      // recommendation-first: options, tradeoffs, risks, why
    case litReview          // literature review: themes, consensus vs. dispute, gaps, key sources

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .general:          return "General"
        case .comparisonMatrix: return "Comparison matrix"
        case .decisionBrief:    return "Decision brief"
        case .litReview:        return "Literature review"
        }
    }
}

// MARK: - Findings

public enum Confidence: String, Codable, Sendable, CaseIterable {
    case high, medium, low, unverified
}

public struct Finding: Codable, Sendable, Identifiable {
    public var id = UUID()
    public let claim: String
    public let sources: [String]      // citations (URLs / titles)
    public let confidence: Confidence
    /// Marker ids (`c1`, `a2c1`) tying this claim to quotes in `EvidenceIndex` — the precise link the
    /// bare `sources` URLs can't express. Empty on a run whose backend captured no document text.
    public let citationIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case claim, sources, confidence
        case citationIDs = "citations"
    }

    public init(claim: String, sources: [String], confidence: Confidence, citationIDs: [String] = []) {
        self.claim = claim
        self.sources = sources
        self.confidence = confidence
        self.citationIDs = citationIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claim = try c.decode(String.self, forKey: .claim)
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        confidence = try c.decodeIfPresent(Confidence.self, forKey: .confidence) ?? .unverified
        citationIDs = try c.decodeIfPresent([String].self, forKey: .citationIDs) ?? []
    }
}

/// A point where the blind angles disagreed — surfaced as data by the synthesis, not dissolved into
/// confident prose. `positions` is one line per divergent stance (e.g. "angle 1: X", "angle 3: Y").
public struct Conflict: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id = UUID()
    public let claim: String
    public let positions: [String]

    private enum CodingKeys: String, CodingKey { case claim, positions }

    public init(claim: String, positions: [String]) {
        self.claim = claim
        self.positions = positions
    }
}

/// The lifecycle of one topic. The PRD contract: complete / inconclusive / haltedSpend / haltedTime /
/// error, plus `skipped` when the run budget (time or spend) is reached before a topic starts (the
/// reason is in `note`). `haltedManual` (user pressed Stop mid-topic → partial, story 51) is an
/// honest addition. ponytail: one extra case, story-backed — not speculative.
public enum TopicStatus: String, Codable, Sendable, CaseIterable {
    case queued, running
    case complete           // researched + verified → note written/updated
    case inconclusive       // ran fully but nothing solid to file
    case haltedSpend        // hit a spend wall → partial findings, flagged incomplete
    case haltedTime         // hit the time wall → partial findings, flagged incomplete
    case haltedManual       // user pressed Stop mid-topic → partial findings (story 51)
    case skipped            // run time/spend budget reached before this topic started (reason in `note`)
    case error

    /// Whether this outcome carries incomplete-but-usable partial findings.
    public var isPartial: Bool {
        switch self {
        case .haltedSpend, .haltedTime, .haltedManual: return true
        default: return false
        }
    }

    /// Human label for the digest.
    public var label: String {
        switch self {
        case .queued:       return "queued"
        case .running:      return "running"
        case .complete:     return "complete"
        case .inconclusive: return "inconclusive"
        case .haltedSpend:  return "halted · spend wall"
        case .haltedTime:   return "halted · time wall"
        case .haltedManual: return "halted · stopped"
        case .skipped:      return "skipped"
        case .error:        return "error"
        }
    }
}

/// One research angle on a question, produced by the planner for a fan-out run. `title` is the short
/// label the viz shows on a node; `prompt` is the full, self-contained research question that agent
/// runs — deliberately isolated so an angle never needs (or sees) a sibling's findings.
public struct ResearchAngle: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var prompt: String
    public var preset: EffortPreset?   // planner-assigned budget: a shallow lookup runs cheaper than the run default

    public init(id: String = UUID().uuidString, title: String, prompt: String, preset: EffortPreset? = nil) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.preset = preset
    }
}

/// Whether a prepared topic is a normal research run or the fan-in summariser (which reconciles the
/// angle writeups in its `context` instead of searching the web). The executor branches on this.
public enum TopicRole: String, Codable, Sendable {
    case research, synthesis
    case verify        // cheap, no-tools citation re-check over the provided writeups (context)
    case plain         // no system prompt at all — `context` verbatim as the prompt (the benchmark's baseline)
}

/// Run-level config held in app state / Application Support.
public struct RunSettings: Codable, Sendable {
    public var brainURL: URL
    public var runSpendCapUSD: Decimal
    public var perTopicSpendCapUSD: Decimal
    public var perTopicTimeout: Duration
    public var runDeadline: Date?           // optional "be done by" wall
    public var defaultPreset: EffortPreset
    public var useProjectContext: Bool      // let the research agents read the project (read-only)
    public var synthesisTemplate: ResearchTemplate?  // fan-out: shape the synthesis into a structured deliverable (nil = general)
    public var profile: RunProfile          // which executors serve this run (subscription / budget / …)

    public init(brainURL: URL, runSpendCapUSD: Decimal, perTopicSpendCapUSD: Decimal,
                perTopicTimeout: Duration, runDeadline: Date? = nil, defaultPreset: EffortPreset,
                useProjectContext: Bool = false, synthesisTemplate: ResearchTemplate? = nil,
                profile: RunProfile = .subscription) {
        self.brainURL = brainURL
        self.runSpendCapUSD = runSpendCapUSD
        self.perTopicSpendCapUSD = perTopicSpendCapUSD
        self.perTopicTimeout = perTopicTimeout
        self.runDeadline = runDeadline
        self.defaultPreset = defaultPreset
        self.useProjectContext = useProjectContext
        self.synthesisTemplate = synthesisTemplate
        self.profile = profile
    }
}

// MARK: - Executor I/O

/// The per-topic usage ledger (PRD 02 R3): token/search/cost breakdown for one topic, from whichever
/// executor served it. Populated by summing the parser's `StepUsage` lines — engine per-step events, or
/// the CLI result's `modelUsage` aggregate. Always recorded; no run completes without it.
public struct TopicUsage: Codable, Sendable, Equatable {
    public let provider: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let searchCalls: Int
    public let fetchCalls: Int
    public let costUSD: Decimal

    public init(provider: String, model: String, inputTokens: Int, outputTokens: Int,
                cacheReadTokens: Int, cacheWriteTokens: Int, searchCalls: Int, fetchCalls: Int,
                costUSD: Decimal) {
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.searchCalls = searchCalls
        self.fetchCalls = fetchCalls
        self.costUSD = costUSD
    }

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }

}

// MARK: - Seams (protocols — the substitutable boundaries)

/// Injected clock — no real wall-clock waits in tests. `Date`-based (wake deadline is a wall clock,
/// per-topic timeout is a Duration added to the topic start).
public protocol RunClock: Sendable {
    func now() -> Date
    func sleep(until deadline: Date) async throws
}

public protocol PowerManager: Sendable {
    func preventSleep(reason: String)
    func allowSleep()
}

public protocol Notifier: Sendable {
    func notifyRunFinished(_ run: StoredRun)
}

public protocol ClaudeProbe: Sendable {
    func probe() -> ProbeResult
}

public struct ProbeResult: Sendable, Equatable {
    public let installed: Bool
    public let authenticated: Bool?   // nil = present but couldn't confirm sign-in
    public let version: String?
    public let detail: String

    public init(installed: Bool, authenticated: Bool?, version: String?, detail: String) {
        self.installed = installed
        self.authenticated = authenticated
        self.version = version
        self.detail = detail
    }
}

// MARK: - Small helpers

public extension Duration {
    /// Seconds as a Double (for Date arithmetic and display).
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

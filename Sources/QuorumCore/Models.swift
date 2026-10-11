import Foundation

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

}

// MARK: - Seams (protocols — the substitutable boundaries)

/// Injected clock — no real wall-clock waits in tests. `Date`-based (wake deadline is a wall clock,
/// per-topic timeout is a Duration added to the topic start).
public protocol RunClock: Sendable {
    func now() -> Date
    func sleep(until deadline: Date) async throws
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

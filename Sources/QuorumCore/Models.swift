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

    /// Deliverable-shape instructions injected into the synthesiser's prompt (empty for `.general`).
    /// STRUCTURE only — the synthesis system prompt's citation, "## Open conflicts", and trailing-JSON
    /// contract still applies underneath every template.
    public var synthesisInstructions: String {
        switch self {
        case .general:
            return ""
        case .comparisonMatrix:
            return """
            Shape the answer as a COMPARISON MATRIX. Identify the options/alternatives the angles cover \
            and the criteria that distinguish them. Lead with a markdown table under "## Comparison" \
            (rows = options, columns = criteria, each cell cited), then a short "## Recommendation" \
            naming the best fit and for whom. Any cell the sources don't support → write "unverified", \
            never a guess.
            """
        case .decisionBrief:
            return """
            Shape the answer as a DECISION BRIEF, recommendation-first. Open with "## Recommendation" \
            (one clear call + confidence), then "## Options considered" (each with its key tradeoff), \
            "## Risks & unknowns", and "## Why" (the evidence). Keep it decision-oriented and skimmable.
            """
        case .litReview:
            return """
            Shape the answer as a LITERATURE REVIEW, organized by THEME (not by angle). Under \
            "## Themes", group what the sources say and, per theme, state where they agree vs. dispute \
            and how strong the evidence is. Add "## Gaps & open questions" and "## Key sources" (the \
            most authoritative, one line each).
            """
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

    private enum CodingKeys: String, CodingKey { case claim, sources, confidence }

    public init(claim: String, sources: [String], confidence: Confidence) {
        self.claim = claim
        self.sources = sources
        self.confidence = confidence
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

/// How the brain grew for a topic (shown in the digest — the compounding core, stories 30–32).
public enum NoteAction: String, Codable, Sendable {
    case created     // a brand-new note in the brain
    case extended    // appended a dated section to an existing note — the topic deepens over time
    case merged      // a fan-out synthesis folded into an existing note (one dated section per dive)
    case reconciled  // a completed multi-round dive fused into ONE current answer, superseding its per-round sections

    public var digestLabel: String {
        switch self {
        case .created:    return "created a new note"
        case .extended:   return "extended an existing note"
        case .merged:     return "merged into an existing note"
        case .reconciled: return "reconciled a multi-round dive into one answer"
        }
    }
}

/// The lifecycle of one topic. The PRD contract: complete / inconclusive / haltedSpend / haltedTime /
/// error, plus `skipped` when the run budget (time or spend) is reached before a topic starts (the
/// reason is in `note`). `haltedManual` (user pressed Stop mid-topic → partial, story 51) is an
/// honest addition. ponytail: one extra case, story-backed — not speculative.
public enum TopicStatus: String, Codable, Sendable {
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

// MARK: - Run configuration (mapper output)

public struct RunConfig: Sendable, Equatable {
    public let allowedTools: [String]        // READ-ONLY: search / fetch / read — never write/edit/bash
    public let effort: Effort
    public let sourceBudget: Int             // ~how many sources to consult & cross-check
    public let maxTurns: Int                 // backstop ceiling
    public let perTopicSpendCapUSD: Decimal
    public let perTopicTimeout: Duration
    public let depth: Depth

    public init(allowedTools: [String], effort: Effort, sourceBudget: Int, maxTurns: Int,
                perTopicSpendCapUSD: Decimal, perTopicTimeout: Duration, depth: Depth) {
        self.allowedTools = allowedTools
        self.effort = effort
        self.sourceBudget = sourceBudget
        self.maxTurns = maxTurns
        self.perTopicSpendCapUSD = perTopicSpendCapUSD
        self.perTopicTimeout = perTopicTimeout
        self.depth = depth
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

/// A queue item: a plain-language rabbit hole plus optional per-topic overrides.
public struct Topic: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var question: String
    public var context: String?
    public var depth: Depth?                 // optional per-topic override
    public var presetOverride: EffortPreset? // beats the run default (stories 45)
    public var useProjectContext: Bool

    public init(id: String = UUID().uuidString, question: String, context: String? = nil,
                depth: Depth? = nil, presetOverride: EffortPreset? = nil, useProjectContext: Bool = false) {
        self.id = id
        self.question = question
        self.context = context
        self.depth = depth
        self.presetOverride = presetOverride
        self.useProjectContext = useProjectContext
    }
}

/// A topic resolved through the mapper, ready to hand to the executor.
public struct PreparedTopic: Sendable {
    public let id: String
    public let question: String
    public let context: String?
    public let projectURL: URL
    public let priorNotes: [URL]              // related existing notes, passed as read-only context (story 30)
    public let useProjectContext: Bool
    public let preset: EffortPreset          // which preset this ran at (shown in the digest)
    public let runConfig: RunConfig
    public let role: TopicRole               // research (default) or the fan-in synthesis run

    public init(id: String, question: String, context: String?, projectURL: URL,
                priorNotes: [URL] = [], useProjectContext: Bool, preset: EffortPreset,
                runConfig: RunConfig, role: TopicRole = .research) {
        self.id = id
        self.question = question
        self.context = context
        self.projectURL = projectURL
        self.priorNotes = priorNotes
        self.useProjectContext = useProjectContext
        self.preset = preset
        self.runConfig = runConfig
        self.role = role
    }
}

/// Run-level config held in app state / Application Support.
public struct RunSettings: Codable, Sendable {
    public var projectURL: URL
    public var runSpendCapUSD: Decimal
    public var perTopicSpendCapUSD: Decimal
    public var perTopicTimeout: Duration
    public var runDeadline: Date?           // optional "be done by" wall
    public var defaultPreset: EffortPreset
    public var useProjectContext: Bool      // let the research agents read the project (read-only)
    public var synthesisTemplate: ResearchTemplate?  // fan-out: shape the synthesis into a structured deliverable (nil = general)

    public init(projectURL: URL, runSpendCapUSD: Decimal, perTopicSpendCapUSD: Decimal,
                perTopicTimeout: Duration, runDeadline: Date? = nil, defaultPreset: EffortPreset,
                useProjectContext: Bool = false, synthesisTemplate: ResearchTemplate? = nil) {
        self.projectURL = projectURL
        self.runSpendCapUSD = runSpendCapUSD
        self.perTopicSpendCapUSD = perTopicSpendCapUSD
        self.perTopicTimeout = perTopicTimeout
        self.runDeadline = runDeadline
        self.defaultPreset = defaultPreset
        self.useProjectContext = useProjectContext
        self.synthesisTemplate = synthesisTemplate
    }
}

// MARK: - Executor I/O

/// Emitted by the research run as it goes, so an aborted topic can hand back what it had.
public struct PartialFindings: Sendable {
    public let headline: String
    public let findings: [Finding]
    public let sourcesConsulted: Int
    public let writeupMarkdown: String       // the writeup so far

    public init(headline: String, findings: [Finding], sourcesConsulted: Int, writeupMarkdown: String) {
        self.headline = headline
        self.findings = findings
        self.sourcesConsulted = sourcesConsulted
        self.writeupMarkdown = writeupMarkdown
    }
}

/// What the executor returns: content only (no disk URLs) — the app's findings store does the writing.
public struct TopicFindings: Sendable {
    public let id: String
    public let status: TopicStatus
    public let preset: EffortPreset
    public let headline: String
    public let findings: [Finding]
    public let conflicts: [Conflict]         // fan-out synthesis: where the blind angles disagreed
    public let gaps: [String]                // fan-out synthesis: open questions the answer couldn't close (fed to the next round)
    public let sourcesConsulted: Int
    public let costUSD: Decimal
    public let duration: Duration
    public let writeupMarkdown: String       // full cited writeup (the store writes this to disk)
    public let transcript: String            // raw sources/logs, kept out of the skimmable brief
    public let note: String?                 // one-line reason for halted/inconclusive/error
    public let sessionID: String?            // the CLI session — resume this topic to chat / continue
    public let rateLimit: String?            // e.g. "weekly limit: allowed · resets Sat 7:00 PM"

    public init(id: String, status: TopicStatus, preset: EffortPreset, headline: String,
                findings: [Finding], conflicts: [Conflict] = [], gaps: [String] = [], sourcesConsulted: Int,
                costUSD: Decimal, duration: Duration,
                writeupMarkdown: String, transcript: String, note: String?, sessionID: String? = nil,
                rateLimit: String? = nil) {
        self.id = id
        self.status = status
        self.preset = preset
        self.headline = headline
        self.findings = findings
        self.conflicts = conflicts
        self.gaps = gaps
        self.sourcesConsulted = sourcesConsulted
        self.costUSD = costUSD
        self.duration = duration
        self.writeupMarkdown = writeupMarkdown
        self.transcript = transcript
        self.note = note
        self.sessionID = sessionID
        self.rateLimit = rateLimit
    }
}

// MARK: - Report (rendered as the run digest)

public struct RunReport: Sendable, Codable {
    public struct TopicEntry: Sendable, Codable {
        public let id: String
        public let question: String
        public let status: TopicStatus
        public let preset: EffortPreset
        public let headline: String
        public let confidenceSummary: String   // e.g. "2 high · 1 unverified"
        public let sourcesConsulted: Int
        public let costUSD: Decimal
        public let durationSeconds: Double
        public let note: String?
        public let notePath: String?            // the note in the brain (app-written; nil if the write failed)
        public let noteAction: NoteAction?      // created a new note, or extended an existing one (stories 30–32)
        public let transcriptPath: String?
        public let sessionID: String?    // resume this topic to chat / continue in Claude Code
        public let rateLimit: String?    // limit window/status/reset at the time this topic ran
        public let isSynthesis: Bool?    // fan-out: the summariser entry. Optional → old report.json still decodes
        public let conflicts: [Conflict]?  // fan-out synthesis: cross-angle disagreements. Optional → old report.json decodes
        public let gaps: [String]?         // fan-out synthesis: open questions still unanswered. Optional → old report.json decodes
        public let round: Int?             // iterative fan-out: which round (1-based) produced this entry; nil = single-round/legacy
        public let sources: [String]?      // the actual cited source URLs (so History can show them, not just a count)
        public let findings: [Finding]?    // the structured findings — autoresearch reads their confidence to judge if the answer is concrete. Optional → old report.json decodes

        public init(id: String, question: String, status: TopicStatus, preset: EffortPreset,
                    headline: String, confidenceSummary: String, sourcesConsulted: Int,
                    costUSD: Decimal, durationSeconds: Double, note: String?,
                    notePath: String?, noteAction: NoteAction? = nil, transcriptPath: String?,
                    sessionID: String? = nil, rateLimit: String? = nil, isSynthesis: Bool = false,
                    conflicts: [Conflict] = [], gaps: [String] = [], round: Int? = nil, sources: [String] = [],
                    findings: [Finding] = []) {
            self.id = id
            self.question = question
            self.status = status
            self.preset = preset
            self.headline = headline
            self.confidenceSummary = confidenceSummary
            self.sourcesConsulted = sourcesConsulted
            self.costUSD = costUSD
            self.durationSeconds = durationSeconds
            self.note = note
            self.notePath = notePath
            self.noteAction = noteAction
            self.transcriptPath = transcriptPath
            self.sessionID = sessionID
            self.rateLimit = rateLimit
            self.isSynthesis = isSynthesis
            self.conflicts = conflicts
            self.gaps = gaps
            self.round = round
            self.sources = sources
            self.findings = findings
        }
    }

    public let startedAt: Date
    public let finishedAt: Date
    public let entries: [TopicEntry]
    public let totalCostUSD: Decimal
    public let runSpendCapUSD: Decimal

    public var totalDurationSeconds: Double { finishedAt.timeIntervalSince(startedAt) }
    public var stayedUnderCap: Bool { totalCostUSD <= runSpendCapUSD }

    public init(startedAt: Date, finishedAt: Date, entries: [TopicEntry],
                totalCostUSD: Decimal, runSpendCapUSD: Decimal) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.entries = entries
        self.totalCostUSD = totalCostUSD
        self.runSpendCapUSD = runSpendCapUSD
    }
}

// MARK: - Seams (protocols — the substitutable boundaries)

/// The ONE substitutable seam. Production spawns the Claude Code CLI; tests fake it.
public protocol ResearchExecutor: Sendable {
    func run(_ topic: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings
}

/// The fan-out seam: decompose one question into N independent research angles. Its own protocol so
/// the serial `runBatch` path (and its tests) never has to know about it. Production spawns a cheap
/// `claude` call; tests script it. Cost/cancellation flow through the same `RunContext`.
public protocol AnglePlanner: Sendable {
    func plan(question: String, count: Int, priorNotes: [URL], projectURL: URL,
              _ ctx: RunContext) async throws -> [ResearchAngle]
}

/// Injected clock — no real wall-clock waits in tests. `Date`-based (wake deadline is a wall clock,
/// per-topic timeout is a Duration added to the topic start).
public protocol RunClock: Sendable {
    func now() -> Date
    func sleep(until deadline: Date) async throws
}

/// The result of filing one topic's findings into the brain.
public struct WriteResult: Sendable {
    public let note: URL          // the note in the brain (created or extended)
    public let transcript: URL    // raw sources/logs for this run, kept out of the note
    public let action: NoteAction
    public let angleArtifacts: [URL]   // fan-out only: each angle's writeup on disk (aligned to input order)
    public init(note: URL, transcript: URL, action: NoteAction, angleArtifacts: [URL] = []) {
        self.note = note; self.transcript = transcript; self.action = action; self.angleArtifacts = angleArtifacts
    }
}

/// The app performs ALL disk writes; the research run never writes. This is the second-brain core:
/// it finds related prior notes (passed to a run as context), and files findings by *extending* an
/// existing note or *creating* a new one — so a topic compounds into one deepening note (stories 30–32).
public protocol FindingsStore: Sendable {
    func makeRunDirectory(projectURL: URL, startedAt: Date) throws -> URL
    /// Related prior notes in the brain (title/keyword match), most-related first — read-only run context.
    func relatedNotes(to question: String, in brain: URL) -> [URL]
    /// Is this question already covered by an existing note? (story 32 — the "already researched" warning.)
    func existingNote(matching question: String, in brain: URL) -> URL?
    /// File the findings: extend the best-matching note or create a new one; write the transcript into `runDir`.
    func write(_ findings: TopicFindings, question: String, brain: URL, priorNotes: [URL],
               runDir: URL, at date: Date) throws -> WriteResult
    /// File a fan-out run: angle writeups → run artifacts; the summary → the one durable note
    /// (`.created` new / `.merged` into an existing one), wikilinked to the artifacts + prior notes.
    func writeSynthesis(_ summary: TopicFindings, question: String, angles: [TopicFindings],
                        angleTitles: [String], brain: URL, priorNotes: [URL], runDir: URL, at date: Date) throws -> WriteResult
    /// The body (after frontmatter) of the note that already covers this question, or nil if none exists.
    /// Captured BEFORE a multi-round dive starts so reconciliation can rewrite the dive's rounds into one
    /// section while preserving everything above it (prior dives stay immutable dated history).
    func noteBody(matching question: String, in brain: URL) -> String?
    /// File a completed multi-round dive as ONE reconciled section: `preDiveBody` + one dated section,
    /// collapsing the dive's per-round sections into the current answer (`.reconciled`). Prior dives are
    /// preserved because they live in `preDiveBody`. Frontmatter lineage is carried like `extend`.
    func writeReconciliation(_ summary: TopicFindings, question: String, relatedLinks: [URL],
                             brain: URL, runDir: URL, preDiveBody: String?, at date: Date) throws -> WriteResult
    func writeDigest(_ report: RunReport, inRunDirectory dir: URL) throws -> URL
    func listRuns(projectURL: URL) -> [URL]
    /// Every note in the brain (unordered) — the whole-brain health check reads all of them.
    func allNotes(in brain: URL) -> [URL]
}

public protocol PowerManager: Sendable {
    func preventSleep(reason: String)
    func allowSleep()
}

public protocol Notifier: Sendable {
    func notifyRunFinished(_ report: RunReport)
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

// MARK: - Run context handed to the executor

public struct RunContext: Sendable {
    public let clock: any RunClock
    public let cancel: CancellationToken             // supervisor cancels / kills the subprocess on breach
    public let onCost: @Sendable (Decimal) -> Void   // streamed cumulative cost → supervisor watches this
    public let onPartial: @Sendable (PartialFindings) -> Void

    public init(clock: any RunClock, cancel: CancellationToken,
                onCost: @escaping @Sendable (Decimal) -> Void,
                onPartial: @escaping @Sendable (PartialFindings) -> Void) {
        self.clock = clock
        self.cancel = cancel
        self.onCost = onCost
        self.onPartial = onPartial
    }
}

/// A one-shot cancellation signal. `cancel()` fires the handler once; setting a handler after
/// cancellation fires it immediately. The supervisor's handler cancels the executor's Task
/// (which, in production, terminates the Claude Code subprocess).
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (() -> Void)?

    public init() {}

    public func onCancel(_ h: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); h(); return }
        handler = h
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true
        let h = handler
        handler = nil
        lock.unlock()
        h?()
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }
}

// MARK: - Small helpers

public extension Duration {
    /// Seconds as a Double (for Date arithmetic and display).
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

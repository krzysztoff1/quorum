import Foundation
@testable import NightYokeCore

// MARK: - The one fake at the seam: a scripted stand-in for the Claude Code subprocess.

final class FakeExecutor: ResearchExecutor, @unchecked Sendable {
    typealias Behavior = @Sendable (PreparedTopic, RunContext) async throws -> TopicFindings
    private let behaviors: [String: Behavior]
    private let fallback: Behavior

    init(_ behaviors: [String: Behavior], fallback: @escaping Behavior = FakeExecutor.completing()) {
        self.behaviors = behaviors
        self.fallback = fallback
    }

    func run(_ topic: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        try await (behaviors[topic.id] ?? fallback)(topic, ctx)
    }

    // MARK: scripted behaviors

    /// Completes cleanly with verified + one unverified finding, reporting cost via the stream.
    static func completing(cost: Decimal = Decimal(string: "0.10")!, sources: Int = 12) -> Behavior {
        { t, ctx in
            ctx.onCost(cost)
            return TopicFindings(
                id: t.id, status: .complete, preset: t.preset,
                headline: "Verified answer",
                findings: [
                    Finding(claim: "Claim A", sources: ["https://a.example"], confidence: .high),
                    Finding(claim: "Claim B", sources: ["https://b.example", "https://c.example"], confidence: .high),
                    Finding(claim: "Unconfirmed aside", sources: [], confidence: .unverified),
                ],
                sourcesConsulted: sources, costUSD: cost, duration: .seconds(0),
                writeupMarkdown: "## Details\n\nA long cited writeup.", transcript: "search log", note: nil)
        }
    }

    /// Emits a partial, then a cost tick that trips a spend wall, then parks until killed.
    static func spendWall(cost: Decimal) -> Behavior {
        { t, ctx in
            ctx.onPartial(PartialFindings(
                headline: "Partial before spend halt",
                findings: [Finding(claim: "Early claim", sources: ["https://x.example"], confidence: .medium)],
                sourcesConsulted: 3, writeupMarkdown: "partial body"))
            ctx.onCost(cost)                    // pulls the cord
            try await parkUntilCancelled()
            return FakeExecutor.completingSync(t) // unreached in practice; supervisor overrides anyway
        }
    }

    /// Emits a partial, advances the test clock past the per-topic timeout, then parks until killed.
    static func timeWall(_ clock: TestClock, advanceBy: Duration) -> Behavior {
        { t, ctx in
            ctx.onPartial(PartialFindings(
                headline: "Partial before time halt",
                findings: [], sourcesConsulted: 1, writeupMarkdown: "partial time body"))
            clock.advance(by: advanceBy)         // trips the timer → markTimedOut → cancel
            try await parkUntilCancelled()
            return FakeExecutor.completingSync(t)
        }
    }

    /// Ran fully but nothing solid; optionally advances the clock (used to push past a deadline).
    static func inconclusive(cost: Decimal = Decimal(string: "0.05")!, advance clock: TestClock? = nil, by: Duration = .zero) -> Behavior {
        { t, ctx in
            ctx.onCost(cost)
            if let clock { clock.advance(by: by) }
            return TopicFindings(
                id: t.id, status: .inconclusive, preset: t.preset,
                headline: "No solid answer", findings: [], sourcesConsulted: 4,
                costUSD: cost, duration: .seconds(0), writeupMarkdown: "Searched but couldn't confirm.",
                transcript: "log", note: "couldn't verify a solid answer")
        }
    }

    /// Signals it has started (so a test can then cancel the run), then parks until killed.
    static func parksAfterSignaling(_ signal: Signal) -> Behavior {
        { t, ctx in
            ctx.onPartial(PartialFindings(headline: "Work in progress", findings: [], sourcesConsulted: 2, writeupMarkdown: "in progress"))
            await signal.fire()
            try await parkUntilCancelled()
            return FakeExecutor.completingSync(t)
        }
    }

    private static func completingSync(_ t: PreparedTopic) -> TopicFindings {
        TopicFindings(id: t.id, status: .complete, preset: t.preset, headline: "done",
                      findings: [], sourcesConsulted: 0, costUSD: 0, duration: .seconds(0),
                      writeupMarkdown: "", transcript: "", note: nil)
    }
}

/// Suspends until the running Task is cancelled (then throws). The long sleep is never actually
/// waited out in a passing test — cancellation arrives first.
func parkUntilCancelled() async throws {
    try await Task.sleep(nanoseconds: 60_000_000_000)
}

// MARK: - Spies for the non-seam services

final class SpyPower: PowerManager, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var prevented = 0
    private(set) var allowed = 0
    func preventSleep(reason: String) { lock.withLock { prevented += 1 } }
    func allowSleep() { lock.withLock { allowed += 1 } }
}

final class SpyNotifier: Notifier, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var lastReport: RunReport?
    func notifyRunFinished(_ report: RunReport) { lock.withLock { count += 1; lastReport = report } }
}

struct FakeProbe: ClaudeProbe {
    let result: ProbeResult
    func probe() -> ProbeResult { result }
}

// MARK: - Test coordination

/// A one-shot signal a behavior can `fire()` and a test can `await wait()` on.
actor Signal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func fire() { fired = true; waiters.forEach { $0.resume() }; waiters = [] }
    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

// MARK: - Fan-out fakes

/// Scripted planner: returns fixed angles and reports a small planning cost.
final class FakeAnglePlanner: AnglePlanner, @unchecked Sendable {
    let angles: [ResearchAngle]
    let cost: Decimal
    private let lock = NSLock()
    private(set) var calls = 0
    init(_ angles: [ResearchAngle], cost: Decimal = Decimal(string: "0.01")!) {
        self.angles = angles; self.cost = cost
    }
    func plan(question: String, count: Int, priorNotes: [URL], projectURL: URL,
              _ ctx: RunContext) async throws -> [ResearchAngle] {
        lock.withLock { calls += 1 }
        ctx.onCost(cost)
        return angles
    }
}

/// Records every PreparedTopic it runs — thread-safe, since fan-out angles run in parallel. Lets tests
/// assert isolation (no sibling writeup leaked into an angle) and that the synthesis saw every angle.
final class RecordingExecutor: ResearchExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [PreparedTopic] = []
    let angleCost: Decimal
    init(angleCost: Decimal = Decimal(string: "0.10")!) { self.angleCost = angleCost }

    var seen: [PreparedTopic] { lock.withLock { _seen } }
    var researchTopics: [PreparedTopic] { seen.filter { $0.role == .research } }
    var synthesisTopic: PreparedTopic? { seen.first { $0.role == .synthesis } }

    func run(_ topic: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        lock.withLock { _seen.append(topic) }
        if topic.role == .synthesis {
            let c = Decimal(string: "0.05")!
            ctx.onCost(c)
            return TopicFindings(id: topic.id, status: .complete, preset: topic.preset,
                                 headline: "Synthesis",
                                 findings: [Finding(claim: "merged", sources: ["https://s.example"], confidence: .high)],
                                 sourcesConsulted: 3, costUSD: c, duration: .seconds(0),
                                 writeupMarkdown: "Reconciled writeup.", transcript: "synth log", note: nil)
        }
        ctx.onCost(angleCost)
        return TopicFindings(id: topic.id, status: .complete, preset: topic.preset,
                             headline: "Angle: \(topic.question)", findings: [], sourcesConsulted: 5,
                             costUSD: angleCost, duration: .seconds(0),
                             writeupMarkdown: "FINDINGS ABOUT \(topic.question)", transcript: "log", note: nil)
    }
}

/// A fan-out executor whose SYNTHESIS emits one unresolved conflict + one gap for its first
/// `roundsWithWork` calls, then a clean synthesis — so `runIterativeFanOut` runs that many follow-up
/// rounds and then goes dry. Angles always complete cheaply and cite the same source the synthesis does
/// (so citation-grounding never fires, keeping the cost math exact). Thread-safe: angles run in parallel.
final class IterativeExecutor: ResearchExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _synthCalls = 0
    private var _researchPrompts: [String] = []
    let roundsWithWork: Int
    let angleCost: Decimal
    let synthCost: Decimal

    init(roundsWithWork: Int, angleCost: Decimal = Decimal(string: "0.10")!,
         synthCost: Decimal = Decimal(string: "0.05")!) {
        self.roundsWithWork = roundsWithWork; self.angleCost = angleCost; self.synthCost = synthCost
    }

    var synthCalls: Int { lock.withLock { _synthCalls } }
    var researchPrompts: [String] { lock.withLock { _researchPrompts } }

    func run(_ topic: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        if topic.role == .synthesis {
            let n = lock.withLock { _synthCalls += 1; return _synthCalls }
            ctx.onCost(synthCost)
            let work = n <= roundsWithWork
            return TopicFindings(
                id: topic.id, status: .complete, preset: topic.preset, headline: "Synthesis \(n)",
                findings: [Finding(claim: "merged \(n)", sources: ["https://s.example"], confidence: .high)],
                conflicts: work ? [Conflict(claim: "disputed point \(n)", positions: ["angle 1: X", "angle 2: Y"])] : [],
                gaps: work ? ["open question \(n)"] : [],
                sourcesConsulted: 3, costUSD: synthCost, duration: .seconds(0),
                writeupMarkdown: "synthesis \(n)", transcript: "log", note: nil)
        }
        lock.withLock { _researchPrompts.append(topic.question) }
        ctx.onCost(angleCost)
        return TopicFindings(id: topic.id, status: .complete, preset: topic.preset, headline: "Angle",
                             findings: [Finding(claim: "found", sources: ["https://s.example"], confidence: .high)],
                             sourcesConsulted: 5, costUSD: angleCost, duration: .seconds(0),
                             writeupMarkdown: "found", transcript: "log", note: nil)
    }
}

/// Every run signals it started, then parks until cancelled — for the manual-stop-mid-fan-out test.
final class ParkingExecutor: ResearchExecutor, @unchecked Sendable {
    let signal: Signal
    init(_ signal: Signal) { self.signal = signal }
    func run(_ topic: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        ctx.onPartial(PartialFindings(headline: "wip", findings: [], sourcesConsulted: 1, writeupMarkdown: "wip"))
        await signal.fire()
        try await parkUntilCancelled()
        return TopicFindings(id: topic.id, status: .complete, preset: topic.preset, headline: "x",
                             findings: [], sourcesConsulted: 0, costUSD: 0, duration: .seconds(0),
                             writeupMarkdown: "", transcript: "", note: nil)
    }
}

// MARK: - Temp project folder

func makeTempProject() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nightyoke-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

let fixedStart = Date(timeIntervalSince1970: 1_700_000_000)

func standardRun(project: URL, runCap: Decimal = 100, perTopicCap: Decimal = Decimal(string: "0.50")!,
                   timeout: Duration = .seconds(300), deadline: Date? = nil,
                   preset: EffortPreset = .standard) -> RunSettings {
    RunSettings(projectURL: project, runSpendCapUSD: runCap, perTopicSpendCapUSD: perTopicCap,
                perTopicTimeout: timeout, runDeadline: deadline, defaultPreset: preset)
}

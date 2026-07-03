import Foundation
import NightYokeCore

/// Dev-only launch detection. A shipped, notarized `.app` has a bundle id; the raw SwiftPM executable
/// (`swift run NightYoke`) does not. Gates the dry-run affordance so it can never reach a real build.
enum AppEnv {
    static let isDev = Bundle.main.bundleIdentifier == nil
    /// Seed for the dry-run toggle: `NIGHTYOKE_DRY_RUN=1 swift run NightYoke` starts with it on.
    static let dryRunRequested = ProcessInfo.processInfo.environment["NIGHTYOKE_DRY_RUN"] != nil
}

/// A dry stand-in for `ClaudeCodeExecutor` at the same seam (research + planner): spawns no subprocess,
/// makes no external API call, and reports $0. It streams a few canned snapshots so the live feed and
/// the radial fan still animate — a fast, free way to exercise the whole run flow, storage, and UI in
/// dev. ponytail: gated by `AppEnv.isDev` at the call site; never wired into a shipped build.
struct DryRunExecutor: ResearchExecutor, AnglePlanner {
    let onActivity: (@Sendable (LiveSnapshot) -> Void)?
    init(onActivity: (@Sendable (LiveSnapshot) -> Void)? = nil) { self.onActivity = onActivity }

    func run(_ topic: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        let q = topic.question
        let sources = [
            LiveSource(kind: "WebSearch", value: "\(q) — dry run"),
            LiveSource(kind: "WebFetch", value: "https://example.com/dry-run"),
        ]
        var snap = LiveSnapshot(topicID: topic.id, question: q)
        snap.thinking = "Dry run — pretending to research “\(q)”. No external calls, no spend."
        onActivity?(snap); try await nap()
        snap.sources = sources
        onActivity?(snap); try await nap()
        snap.output = stubWriteup(q)
        onActivity?(snap); try await nap()

        let headline: String
        var conflicts: [Conflict] = []
        var gaps: [String] = []
        var findings = [Finding(claim: "Dry-run stub — no real research was done.",
                                sources: ["https://example.com/dry-run"], confidence: .low)]
        switch topic.role {
        case .research:  headline = "Dry-run answer for “\(q)”"
        case .verify:    headline = "Dry-run citation check"
        case .synthesis:
            headline = "Dry-run synthesis"
            // Populate the interesting states so the synthesis Summary tab + iterative rounds are demoable
            // without spend: one cross-angle conflict + one gap (both feed the next round → watch it grow),
            // and one deliberately untraceable citation (no angle cited it).
            conflicts = [Conflict(claim: "Sample disputed claim about “\(q)”",
                                  positions: ["angle 1: says yes", "angle 2: says no"])]
            gaps = ["An open sub-question about “\(q)” that another round could still answer"]
            findings.append(Finding(claim: "A claim citing a source no angle consulted.",
                                    sources: ["https://example.com/not-in-any-angle"], confidence: .medium))
        }
        return TopicFindings(
            id: topic.id, status: .complete, preset: topic.preset, headline: headline,
            findings: findings, conflicts: conflicts, gaps: gaps,
            sourcesConsulted: sources.count, costUSD: 0, duration: .seconds(0),
            writeupMarkdown: stubWriteup(q), transcript: "dry run — no subprocess spawned",
            note: "dry run — no external calls, no spend")
    }

    func plan(question: String, count: Int, priorNotes: [URL], projectURL: URL,
              _ ctx: RunContext) async throws -> [ResearchAngle] {
        let angles = (1...max(1, count)).map {
            ResearchAngle(title: "Dry angle \($0)", prompt: "Dry-run angle \($0) of \(count) for: \(question)")
        }
        // Stream titles as (fake) JSON so the planning view animates them in, like the real planner.
        var json = ""
        for a in angles {
            json += (json.isEmpty ? "[" : ",") + "{\"title\":\"\(a.title)\"}"
            onActivity?(LiveSnapshot(topicID: "planning", question: "Planning research angles", output: json + "]"))
            try await nap(short: true)
        }
        return angles
    }

    private func nap(short: Bool = false) async throws {
        // Slow enough to watch the live feed fill in; well under the per-topic time wall (min 1 min).
        let delay: Duration = short ? .milliseconds(120) : .seconds(Double.random(in: 5...10))
        try await Task.sleep(for: delay)   // throws on Stop → supervisor halts
    }

    private func stubWriteup(_ q: String) -> String {
        """
        > 🧪 **Dry run** — no external API calls, no token spend.

        ## Dry-run stub for “\(q)”

        Canned output from `DryRunExecutor` so the run flow, brain storage, and UI can be exercised
        without spending anything.

        ## Sources
        - [Dry-run source](https://example.com/dry-run)
        """
    }
}

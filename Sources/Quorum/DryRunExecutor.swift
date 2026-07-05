import Foundation
import QuorumCore

/// Dev-only launch detection. A shipped, notarized `.app` has a bundle id; the raw SwiftPM executable
/// (`swift run Quorum`) does not. Gates the dry-run affordance so it can never reach a real build.
enum AppEnv {
    static let isDev = Bundle.main.bundleIdentifier == nil
    /// Seed for the dry-run toggle: `QUORUM_DRY_RUN=1 swift run Quorum` starts with it on.
    static let dryRunRequested = ProcessInfo.processInfo.environment["QUORUM_DRY_RUN"] != nil
}

/// A dry stand-in for `ClaudeCodeExecutor` at the same seam (research + planner): spawns no subprocess,
/// makes no external API call, and needs no auth. It streams token-by-token like the real thing —
/// thinking, incremental sources, a growing writeup — and reports a *plausible* cost through the same
/// `ctx.onCost` channel, so the whole app is exercised in dev: live fan nodes, the run total, the spend
/// and time walls, Stop→partial, iterative rounds, and the citation-grounding repair.
///
/// It honours the run config (depth, source budget, project context, prior brain notes, effort, model)
/// so the streamed shape matches what the config asked for — the only thing missing is real research.
/// ponytail: gated by `AppEnv.isDev` at the call site; never wired into a shipped build. `sessionID`
/// stays nil on purpose — a dry topic has no resumable CLI session, and faking one would leave a
/// "resume in terminal / chat" button that errors on click.
struct DryRunExecutor: ResearchExecutor, AnglePlanner {
    let onActivity: (@Sendable (LiveSnapshot) -> Void)?
    let model: ModelChoice
    let synthesisModel: ModelChoice
    init(onActivity: (@Sendable (LiveSnapshot) -> Void)? = nil,
         model: ModelChoice = .default, synthesisModel: ModelChoice? = nil) {
        self.onActivity = onActivity
        self.model = model
        self.synthesisModel = synthesisModel ?? model
    }

    private static let traceable = "https://example.com/dry-run"             // an angle always cites this
    private static let untraceable = "https://example.com/not-in-any-angle"  // no angle cites this → verify drops it

    func run(_ topic: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        switch topic.role {
        case .verify:    return try await runVerify(topic, ctx)
        case .synthesis: return topic.id.hasPrefix("reconcile-")
                              ? try await runReconciliation(topic, ctx)   // the final multi-round fuse
                              : try await runSynthesis(topic, ctx)
        case .research:  return try await runResearch(topic, ctx)
        case .plain:     return try await runPlain(topic, ctx)
        }
    }

    // MARK: - Research

    private func runResearch(_ t: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        let cfg = t.runConfig
        let sources = researchSources(t)
        let findings = researchFindings(t, sources: sources)
        let writeup = researchWriteup(t, sources: sources)
        let total = cost(base: cfg.depth == .scan ? 0.05 : 0.14, effort: cfg.effort,
                         budgetFactor: 0.6 + Double(min(cfg.sourceBudget, 50)) / 50.0)

        try await drive(topicID: t.id, question: t.question,
                        thinking: researchThinking(t),
                        sources: sources, writeup: writeup, findings: findings,
                        total: total, ctx: ctx)

        return TopicFindings(
            id: t.id, status: .complete, preset: t.preset,
            headline: "Dry-run answer for “\(t.question)”",
            findings: findings, sourcesConsulted: sources.count, costUSD: total,
            duration: .seconds(0), writeupMarkdown: writeup,
            transcript: "dry run — no subprocess spawned", note: "dry run — no external calls, no spend",
            rateLimit: rateLimit(t))
    }

    // MARK: - Synthesis (fan-in summariser)

    private func runSynthesis(_ t: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        let conflicts = [Conflict(claim: "Sample disputed claim about “\(t.question)”",
                                  positions: ["angle 1: says yes", "angle 2: says no"])]
        let gaps = ["An open sub-question about “\(t.question)” that another round could still answer"]
        // One finding cites a source every angle also cited (survives verify); one cites a source no
        // angle used (groundCitations flags it → fires the verify repair below).
        let findings = [
            Finding(claim: "Angles agree on the core answer to “\(t.question)”.",
                    sources: [Self.traceable], confidence: .high),
            Finding(claim: "A claim citing a source no angle consulted.",
                    sources: [Self.untraceable], confidence: .medium),
        ]
        let writeup = synthesisWriteup(t, conflicts: conflicts, gaps: gaps)
        let total = cost(base: 0.06, effort: t.runConfig.effort, budgetFactor: 1.0, model: synthesisModel)

        try await drive(topicID: t.id, question: t.question,
                        thinking: "Reconciling the independent angle writeups — matching claims, surfacing conflicts, and marking gaps.",
                        sources: [], writeup: writeup, findings: findings,
                        total: total, ctx: ctx)

        return TopicFindings(
            id: t.id, status: .complete, preset: t.preset, headline: "Dry-run synthesis",
            findings: findings, conflicts: conflicts, gaps: gaps, sourcesConsulted: 1,
            costUSD: total, duration: .seconds(0), writeupMarkdown: writeup,
            transcript: "dry run — no subprocess spawned", note: "dry run — no external calls, no spend")
    }

    // MARK: - Reconciliation (the final multi-round fuse — leads with the current answer)

    /// A canned reconciled answer for the dry-run demo: leads with the position the later round corrected
    /// to, deliberately OMITS the round-1 claim it overturned, and keeps one still-open conflict flagged —
    /// so the whole reconciliation path (collapse-to-one-section, `.reconciled` label) validates for $0.
    /// Cites only a source the rounds cited, so citation-grounding stays clean. Mirrors `cannedJudge`.
    private func runReconciliation(_ t: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        let conflicts = [Conflict(claim: "One point still genuinely unresolved after the final round on “\(t.question)”",
                                  positions: ["round 1: leaned yes", "round 2: leaned no — evidence thin either way"])]
        let findings = [
            Finding(claim: "The current answer to “\(t.question)”, as corrected by the later round.",
                    sources: [Self.traceable], confidence: .high),
            Finding(claim: "A second point corroborated across both rounds — stronger for it.",
                    sources: [Self.traceable], confidence: .medium),
        ]
        let writeup = reconciliationWriteup(t, conflicts: conflicts)
        let total = cost(base: 0.06, effort: t.runConfig.effort, budgetFactor: 1.0, model: synthesisModel)
        try await drive(topicID: t.id, question: t.question,
                        thinking: "Fusing the rounds — leading with the corrected answer, dropping what a later round overturned, keeping only what's still open.",
                        sources: [], writeup: writeup, findings: findings, total: total, ctx: ctx)
        return TopicFindings(
            id: t.id, status: .complete, preset: t.preset, headline: "Dry-run reconciled answer",
            findings: findings, conflicts: conflicts, gaps: [], sourcesConsulted: 1,
            costUSD: total, duration: .seconds(0), writeupMarkdown: writeup,
            transcript: "dry run — no subprocess spawned", note: "dry run — no external calls, no spend")
    }

    private func reconciliationWriteup(_ t: PreparedTopic, conflicts: [Conflict]) -> String {
        """
        > 🧪 **Dry run** — reconciled across rounds, no spend.

        ## Dry-run reconciled answer for “\(t.question)”

        This is the current answer, with later-round corrections taking precedence over earlier claims.

        ## Open conflicts
        \(conflicts.map { "- \($0.claim) (\($0.positions.joined(separator: "; ")))" }.joined(separator: "\n"))

        ## Sources
        - [dry-run round source](\(Self.traceable))
        """
    }

    // MARK: - Citation verify (the gated, cheap re-check — mirrors the real repair)

    /// The real verify keeps every claim but drops any citation not in the angle sources, marking a
    /// finding unverified if it's left with none. We parse the same `verifyContext` string and apply
    /// exactly that, so the dry citation-grounding repair actually corrects the planted fabrication.
    private func runVerify(_ t: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        let (angleSources, parsed) = parseVerifyContext(t.context ?? "")
        let corrected = parsed.map { f -> Finding in
            let kept = f.sources.filter { angleSources.contains(normalize($0)) }
            return Finding(claim: f.claim, sources: kept,
                           confidence: kept.isEmpty ? .unverified : f.confidence)
        }
        let total = cost(base: 0.008, effort: .low, budgetFactor: 1.0)
        try await drive(topicID: t.id, question: "citation check",
                        thinking: "Checking each cited URL against the sources the angles actually consulted.",
                        sources: [], writeup: "Dry-run citation check — dropped citations no angle supported.",
                        findings: corrected, total: total, ctx: ctx)
        return TopicFindings(
            id: t.id, status: .complete, preset: t.preset, headline: "Dry-run citation check",
            findings: corrected, sourcesConsulted: angleSources.count, costUSD: total,
            duration: .seconds(0), writeupMarkdown: "dry run — citation check",
            transcript: "dry run — no subprocess spawned", note: "dry run — no external calls, no spend")
    }

    private func parseVerifyContext(_ ctx: String) -> (Set<String>, [Finding]) {
        var sources = Set<String>(), findings: [Finding] = []
        var inFindings = false
        var claim: String?, sourceLine = "", conf = Confidence.medium
        func flush() {
            guard let c = claim else { return }
            let urls = sourceLine.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            findings.append(Finding(claim: c, sources: urls, confidence: conf))
            claim = nil; sourceLine = ""; conf = .medium
        }
        for raw in ctx.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("Synthesis findings to check") { inFindings = true; continue }
            if !inFindings {
                if line.hasPrefix("- ") { sources.insert(normalize(String(line.dropFirst(2)))) }
            } else if let c = line.range(of: "- claim: ") {
                flush(); claim = String(line[c.upperBound...])
            } else if let c = line.range(of: "confidence: ") {
                conf = Confidence(rawValue: String(line[c.upperBound...]).trimmingCharacters(in: .whitespaces)) ?? .medium
            } else if let c = line.range(of: "sources: ") {
                sourceLine = String(line[c.upperBound...])
            }
        }
        flush()
        return (sources, findings)
    }

    // MARK: - Plain (no scaffolding — the benchmark's baseline; never actually reached by a real
    // benchmark run since that always uses ClaudeCodeExecutor, but DryRunExecutor must still handle it)

    private func runPlain(_ t: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        let prompt = t.context ?? t.question
        let writeup = Self.cannedJudge(for: prompt)
            ?? "> 🧪 **Dry run** — no external API calls, no token spend.\n\nCanned plain reply to:\n\n\(prompt)"
        let total = cost(base: 0.03, effort: t.runConfig.effort, budgetFactor: 1.0)
        try await drive(topicID: t.id, question: t.question,
                        thinking: "Dry run — answering directly, no scaffolding.",
                        sources: [], writeup: writeup, findings: [], total: total, ctx: ctx)
        return TopicFindings(id: t.id, status: .complete, preset: t.preset, headline: "Dry-run plain reply",
                             findings: [], sourcesConsulted: 0, costUSD: total, duration: .seconds(0),
                             writeupMarkdown: writeup, transcript: "dry run — no subprocess spawned",
                             note: "dry run — no external calls, no spend")
    }

    // MARK: - AnglePlanner

    func plan(question: String, count: Int, priorNotes: [URL], projectURL: URL,
              _ ctx: RunContext) async throws -> [ResearchAngle] {
        let n = max(1, count)
        let angles = (1...n).map {
            ResearchAngle(title: "Dry angle \($0)",
                          prompt: "Investigate a distinct facet of “\(question)”.")
        }
        let inc = cost(base: 0.02, effort: .low, budgetFactor: 1.0) / Decimal(n)
        var spent = Decimal(0), json = ""
        if !priorNotes.isEmpty {
            onActivity?(LiveSnapshot(topicID: "planning", question: "Planning research angles",
                                     thinking: "Building on \(priorNotes.count) related brain note(s) — steering angles toward what's still open."))
            try await nap(0.4...0.8)
        }
        for a in angles {
            ctx.onCost(inc); spent += inc
            json += (json.isEmpty ? "[" : ",") + "{\"title\":\"\(a.title)\"}"
            onActivity?(LiveSnapshot(topicID: "planning", question: "Planning research angles",
                                     output: json + "]", costUSD: spent))
            try await nap(0.15...0.35)
        }
        return angles
    }

    // MARK: - Streaming primitive

    /// Streams thinking → sources (one at a time) → writeup (in chunks), charging `total` in small
    /// increments across every step (so the fan node ticks up and the spend wall can trip), pushing a
    /// live snapshot each step and a partial each writeup chunk (so Stop hands back what it had).
    private func drive(topicID: String, question: String, thinking: String,
                       sources: [LiveSource], writeup: String, findings: [Finding],
                       total: Decimal, ctx: RunContext) async throws {
        let thinkingChunks = chunks(thinking, into: 3)
        let writeupChunks = chunks(writeup, into: 14)
        let steps = max(1, thinkingChunks.count + sources.count + writeupChunks.count)
        let inc = total / Decimal(steps)
        var spent = Decimal(0), stepsLeft = steps
        var snap = LiveSnapshot(topicID: topicID, question: question)

        func charge() { stepsLeft -= 1; let amt = stepsLeft == 0 ? total - spent : inc; ctx.onCost(amt); spent += amt; snap.costUSD = spent }

        for chunk in thinkingChunks {
            snap.thinking += chunk; charge(); onActivity?(snap); try await nap(0.3...0.6)
        }
        for s in sources {
            snap.sources.append(s); charge(); onActivity?(snap); try await nap(0.3...0.7)
        }
        for chunk in writeupChunks {
            snap.output += chunk; charge(); onActivity?(snap)
            let headline = snap.output.split(separator: "\n").first.map { String($0.prefix(120)) } ?? question
            ctx.onPartial(PartialFindings(headline: headline, findings: findings,
                                          sourcesConsulted: sources.count, writeupMarkdown: snap.output))
            try await nap(0.12...0.25)
        }
    }

    // MARK: - Realistic cost (plausible dollars, scaled by depth/effort/budget/model — not the cap)

    private func cost(base: Double, effort: Effort, budgetFactor: Double, model: ModelChoice? = nil) -> Decimal {
        dollars(base * effortWeight(effort) * modelWeight(model ?? self.model) * budgetFactor * Double.random(in: 0.85...1.15))
    }

    private func effortWeight(_ e: Effort) -> Double {
        switch e { case .low: 0.5; case .medium: 0.75; case .high: 1.0; case .xhigh: 1.4; case .max: 1.9 }
    }

    /// Roughly proportional to each model's output list price, so the picked model moves the number.
    private func modelWeight(_ m: ModelChoice) -> Double {
        switch m { case .default, .opus: 1.0; case .sonnet: 0.6; case .haiku: 0.25; case .fable: 2.0 }
    }

    private func dollars(_ d: Double) -> Decimal { Decimal(Int((d * 10000).rounded())) / 10000 }

    // MARK: - Content builders (shaped by the config so the stream matches what was asked for)

    private func researchThinking(_ t: PreparedTopic) -> String {
        var s = "Dry run — pretending to \(t.runConfig.depth == .scan ? "quick-scan" : "thoroughly dig into") “\(t.question)”. No external calls, no spend."
        if !t.priorNotes.isEmpty { s += " Building on \(t.priorNotes.count) prior brain note(s)." }
        return s
    }

    private func researchSources(_ t: PreparedTopic) -> [LiveSource] {
        let kw = t.question.split(separator: " ").prefix(4).joined(separator: " ")
        let slug = kw.lowercased().replacingOccurrences(of: " ", with: "-")
        var out = [
            LiveSource(kind: "WebSearch", value: "\(kw) — overview"),
            LiveSource(kind: "WebFetch", value: Self.traceable),
            LiveSource(kind: "WebSearch", value: "\(kw) best practices 2026"),
            LiveSource(kind: "WebFetch", value: "https://docs.example.org/\(slug)"),
            LiveSource(kind: "WebFetch", value: "https://example.com/\(slug)/analysis"),
        ]
        if t.useProjectContext {
            let name = t.projectURL.lastPathComponent
            out += [LiveSource(kind: "Read", value: "\(name)/README.md"),
                    LiveSource(kind: "Grep", value: "\(kw) — in \(name)")]
        }
        if let note = t.priorNotes.first {
            out.append(LiveSource(kind: "Read", value: "brain/\(note.lastPathComponent)"))
        }
        let shown = min(out.count, t.runConfig.depth == .scan ? 5 : 8)
        return Array(out.prefix(max(2, min(shown, t.runConfig.sourceBudget))))
    }

    private func researchFindings(_ t: PreparedTopic, sources: [LiveSource]) -> [Finding] {
        let urls = sources.filter(\.isURL).map(\.value)
        var out = [
            Finding(claim: "Dry-run key finding for “\(t.question)”.",
                    sources: [Self.traceable] + Array(urls.prefix(1)), confidence: .high),
            Finding(claim: "A secondary dry-run finding, corroborated by one source.",
                    sources: Array(urls.dropFirst().prefix(1)), confidence: .medium),
        ]
        if t.runConfig.depth == .scan {
            out.append(Finding(claim: "A thinner claim a quick scan couldn't fully corroborate.",
                               sources: [], confidence: .unverified))
        }
        if let note = t.priorNotes.first {
            out.append(Finding(claim: "Extends prior note \(note.lastPathComponent) with a dry-run update.",
                               sources: [Self.traceable], confidence: .medium))
        }
        return out
    }

    private func researchWriteup(_ t: PreparedTopic, sources: [LiveSource]) -> String {
        var s = """
        > 🧪 **Dry run** — no external API calls, no token spend.

        ## Dry-run \(t.runConfig.depth == .scan ? "scan" : "deep dig") for “\(t.question)”

        Canned output from `DryRunExecutor` so the run flow, brain storage, cost accounting, and UI can \
        be exercised without spending anything. Targeted ~\(t.runConfig.sourceBudget) sources at \
        \(t.runConfig.effort.rawValue) effort.
        """
        if let c = t.context, !c.isEmpty { s += "\n\n**Focus / constraints:** \(c)" }
        if !t.priorNotes.isEmpty { s += "\n\nBuilt on \(t.priorNotes.count) related brain note(s)." }
        if t.useProjectContext { s += "\n\nRead the current project (\(t.projectURL.lastPathComponent)) as read-only grounding." }
        s += "\n\n## Sources\n"
        s += sources.filter(\.isURL).map { "- [\($0.kind)](\($0.value))" }.joined(separator: "\n")
        return s
    }

    private func synthesisWriteup(_ t: PreparedTopic, conflicts: [Conflict], gaps: [String]) -> String {
        """
        > 🧪 **Dry run** — synthesis of the blind angles, no spend.

        ## Dry-run synthesis for “\(t.question)”

        Reconciled answer built only from the angle writeups.

        ## Open conflicts
        \(conflicts.map { "- \($0.claim) (\($0.positions.joined(separator: "; ")))" }.joined(separator: "\n"))

        ## Gaps & open questions
        \(gaps.map { "- \($0)" }.joined(separator: "\n"))

        ## Sources
        - [dry-run angle source](\(Self.traceable))
        """
    }

    // MARK: - Small helpers

    /// A rate-limit banner on ~1 topic in 4, so that UI is demoable without waiting for a real limit.
    private func rateLimit(_ t: PreparedTopic) -> String? {
        abs(t.id.hashValue) % 4 == 0 ? "weekly limit: allowed · resets Sat 7:00 PM" : nil
    }

    private func normalize(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces).lowercased()
        if v.hasSuffix("/") { v.removeLast() }
        return v
    }

    private func chunks(_ s: String, into n: Int) -> [String] {
        guard n > 1, !s.isEmpty else { return s.isEmpty ? [] : [s] }
        let words = s.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count > n else { return [s] }
        let per = Int((Double(words.count) / Double(n)).rounded(.up))
        return stride(from: 0, to: words.count, by: per).map {
            words[$0..<min($0 + per, words.count)].joined(separator: " ") + " "
        }
    }

    private func nap(_ range: ClosedRange<Double>) async throws {
        try await Task.sleep(for: .milliseconds(Int(Double.random(in: range) * 1000)))
    }

    /// Canned whole-brain audit for the dry-run demo: recognises `BrainLint`'s prompt by its marker and
    /// returns a sample report (prose + a ```json block) so Health check → parse → render → "Research this"
    /// works offline with no subprocess. nil for any non-lint prompt. Mirrors the sample conflict + gap the
    /// dry-run synthesis emits.
    /// Canned benchmark judge verdict for the dry-run demo: recognises `BenchmarkRunner`'s judge prompt by
    /// its `scoresA` schema marker and returns a parseable ```json verdict, so a dry `--benchmark` run
    /// exercises the full report path — score tables + winner un-blinding — not just "unparsed". "A"
    /// wins, so with the randomised A/B order the winner lands on quorum and traditional across
    /// questions, covering both attribution branches. Mirrors `cannedLint`.
    static func cannedJudge(for prompt: String) -> String? {
        guard prompt.contains("\"scoresA\"") else { return nil }
        return """
        > 🧪 **Dry run** — canned judge verdict, no external calls, no spend.

        ```json
        {"scoresA":{"groundedness":7,"comprehensiveness":8,"honesty":7,"clarity":8},
        "scoresB":{"groundedness":6,"comprehensiveness":6,"honesty":7,"clarity":7},
        "winner":"A","reasoning":"Dry-run canned verdict — no real evaluation was performed."}
        ```
        """
    }

    static func cannedLint(for prompt: String) -> String? {
        guard prompt.contains(BrainLint.auditMarker) else { return nil }
        return """
        > 🧪 **Dry run** — canned brain audit, no external calls, no spend.

        I reviewed your notes and spotted a few things worth your attention.

        ```json
        {
          "inconsistencies": [
            {"claim": "Two notes disagree on the default request timeout",
             "notes": ["Onboarding flow", "Performance tuning"],
             "detail": "One note assumes 20s; another builds on a 60s timeout for the same call."}
          ],
          "gaps": [
            "How does the onboarding flow behave when the network is offline?"
          ],
          "questions": [
            "Could the search and feed features share one caching layer?"
          ]
        }
        ```
        """
    }
}

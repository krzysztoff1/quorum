import Foundation

/// Fan-out research: decompose ONE question into N angles, research them with N *blind* parallel
/// agents (no agent sees another's findings), then a single summariser reconciles them into one note.
/// Map-reduce over the existing seams — angles reuse `Supervisor.supervise` + `ResearchExecutor.run`;
/// the summariser is just a `run` with `role: .synthesis`. The serial `runBatch` path is untouched.

public enum FanOutPhase: String, Sendable, Equatable {
    case planning, awaitingApproval, researching, synthesizing, verifying, done
}

/// Step 1 — ask the planner for N distinct angles. Reads the brain so the angles complement (not
/// duplicate) what's already known. Throws only if the planner itself throws; an empty result means
/// "no usable plan" and the caller should let the user retry.
public func planAngles(question: String, count: Int, config: RunSettings, planner: AnglePlanner,
                       store: FindingsStore, clock: RunClock) async throws -> [ResearchAngle] {
    let priorNotes = store.relatedNotes(to: question, in: config.projectURL)
    let ctx = RunContext(clock: clock, cancel: CancellationToken(), onCost: { _ in }, onPartial: { _ in })
    let angles = try await planner.plan(question: question, count: max(1, count),
                                        priorNotes: priorNotes, projectURL: config.projectURL, ctx)
    return Array(angles.prefix(max(1, count)))
}

/// Step 2 — run the approved angles in parallel, then synthesize. Never throws: always yields a
/// report (partial if walls trip or the user stops). Cancelling the enclosing Task is the Stop button.
public func runFanOut(question: String, angles: [ResearchAngle], config: RunSettings,
                      executor: ResearchExecutor, clock: RunClock, store: FindingsStore,
                      power: PowerManager, notifier: Notifier,
                      runDir preMadeRunDir: URL? = nil, round: Int? = nil,
                      onPhase: (@Sendable (FanOutPhase) -> Void)? = nil,
                      onAngle: (@Sendable (_ id: String, _ status: TopicStatus) -> Void)? = nil) async -> RunReport {
    let startedAt = clock.now()
    power.preventSleep(reason: "Quorum fan-out research")
    defer { power.allowSleep() }

    // The caller may pre-create the run dir (so the run shows in History the instant it launches); else
    // make one now. Same layout either way.
    let runDir = preMadeRunDir ?? (try? store.makeRunDirectory(projectURL: config.projectURL, startedAt: startedAt))
    // The brain is shared prior knowledge — angles may read it, but NEVER each other (the isolation
    // requirement): each agent's prompt is only its own angle. No sibling writeup is ever passed in.
    let priorNotes = store.relatedNotes(to: question, in: config.projectURL)

    guard !angles.isEmpty else {
        let report = RunReport(startedAt: startedAt, finishedAt: clock.now(), entries: [],
                               totalCostUSD: 0, runSpendCapUSD: config.runSpendCapUSD)
        notifier.notifyRunFinished(report)
        return report
    }

    let ledger = RunLedger(cap: config.runSpendCapUSD)
    // Hard aggregate wall by construction: divide the run cap across the N angles + 1 synthesis, so
    // the per-agent caps (enforced live by the CLI `--max-budget-usd` + the supervisor) can never sum
    // past the run cap. The ledger below is the live total for the UI + a defensive straggler-kill.
    let perAngleCap = capPerAgent(runCap: config.runSpendCapUSD,
                                  perTopicCap: config.perTopicSpendCapUSD, slices: angles.count + 1)

    onPhase?(.researching)
    let findings: [TopicFindings] = await withTaskGroup(of: (Int, TopicFindings).self) { group in
        for (i, angle) in angles.enumerated() {
            var cfg = config
            cfg.perTopicSpendCapUSD = perAngleCap
            let prepared = GuardrailMapper.prepare(
                topic: Topic(id: angle.id, question: angle.prompt,
                             useProjectContext: config.useProjectContext),
                run: cfg, priorNotes: priorNotes)
            group.addTask {
                onAngle?(angle.id, .running)
                let outcome = await Supervisor.supervise(prepared, executor: executor, clock: clock,
                                                         runSpent: 0, runCap: config.runSpendCapUSD,
                                                         startedAt: clock.now(),
                                                         onCharge: { ledger.charge($0) })
                onAngle?(angle.id, outcome.findings.status)
                return (i, outcome.findings)
            }
        }
        var out: [(Int, TopicFindings)] = []
        for await pair in group {
            out.append(pair)
            // ponytail: aggregate cap is a hard wall via `perAngleCap`; this only kills stragglers if
            // the live total somehow crosses (e.g. a mis-set cap). Overshoot ≤ in-flight per-agent caps.
            if ledger.tripped { group.cancelAll() }
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    onPhase?(.synthesizing)
    let draft = await synthesize(question: question, angleFindings: findings, config: config,
                                 executor: executor, clock: clock, ledger: ledger)

    // Ground the synthesis citations against what the angles actually cited (cheap fabrication tripwire),
    // repairing via one gated low-cost call only if something looks untraceable. See `groundCitations`.
    onPhase?(.verifying)
    let synthesis = await groundCitations(draft, angles: findings, config: config,
                                          executor: executor, clock: clock, ledger: ledger)

    // File it: the summary is the one durable note; angle writeups become run artifacts.
    var entries: [RunReport.TopicEntry] = []
    var notePath: String?, noteAction: NoteAction?, transcriptPath: String?
    var artifacts: [String] = []
    if let runDir, let res = try? store.writeSynthesis(synthesis, question: question, angles: findings,
                                                       angleTitles: angles.map(\.title),
                                                       brain: config.projectURL, priorNotes: priorNotes,
                                                       runDir: runDir, at: clock.now()) {
        notePath = res.note.path; noteAction = res.action; transcriptPath = res.transcript.path
        artifacts = res.angleArtifacts.map(\.path)
    }
    entries.append(entry(from: synthesis, question: question, notePath: notePath,
                         noteAction: noteAction, transcriptPath: transcriptPath, isSynthesis: true, round: round))
    for (i, f) in findings.enumerated() {
        let label = i < angles.count ? angles[i].title : f.headline
        // Point each angle entry at its writeup artifact so it opens as a readable note (not just chat).
        let art = i < artifacts.count ? artifacts[i] : nil
        entries.append(entry(from: f, question: label, notePath: art, noteAction: nil, transcriptPath: art, round: round))
    }

    let report = RunReport(startedAt: startedAt, finishedAt: clock.now(), entries: entries,
                           totalCostUSD: ledger.total, runSpendCapUSD: config.runSpendCapUSD)
    if let runDir { _ = try? store.writeDigest(report, inRunDirectory: runDir) }
    onPhase?(.done)
    notifier.notifyRunFinished(report)
    return report
}

// MARK: - Iterative fan-out (round 2+ on the synthesis's unresolved conflicts + gaps)

/// One question → fan out → synthesize → feed the synthesis's UNRESOLVED conflicts + gaps back as the
/// NEXT round's angles → repeat. This is the line between a one-shot parallel search and actual research:
/// the answer deepens round over round (each round's synthesis MERGES into the same brain note).
///
/// Stops when a round surfaces nothing new (dry), the run budget is spent, or `maxRounds` is hit.
/// Reuses `runFanOut` wholesale — every round is a full blind-parallel → synthesis → citation-grounding
/// pass. The run cap is ONE wall across ALL rounds: each round runs with only what earlier rounds left,
/// so total spend can never exceed `config.runSpendCapUSD`. Never throws; returns one report per round
/// (empty only if `angles` was empty). Cancelling the Task is Stop — it returns the rounds done so far.
///
/// All rounds share ONE run dir: the whole dive is a single History row whose merged, round-tagged report
/// drives the History fan diagram. ponytail: the per-round synthesis transcript is overwritten in that dir
/// (last round wins) — fine for a debug log; keep per-round transcripts only if someone needs the trail.
///
/// `autoresearch`: when on, a round that surfaces no new conflicts/gaps but whose answer isn't yet
/// concrete (inconclusive, or every finding low/unverified) doesn't stop — it re-fans on the weak
/// findings to dig deeper. The budget wall + prompt dedup still bound it: it digs until the answer is
/// concrete, the run cap is spent, or it can make no new progress. Off (default) preserves the old
/// "stop when no open questions remain" behavior.
public func runIterativeFanOut(
    question: String, angles: [ResearchAngle], config: RunSettings,
    executor: ResearchExecutor, clock: RunClock, store: FindingsStore,
    power: PowerManager, notifier: Notifier,
    maxRounds: Int = 3, autoresearch: Bool = false, runDir preMadeRunDir: URL? = nil,
    onPhase: (@Sendable (FanOutPhase) -> Void)? = nil,
    onAngle: (@Sendable (_ id: String, _ status: TopicStatus) -> Void)? = nil,
    onRound: (@Sendable (_ round: Int, _ angles: [ResearchAngle]) -> Void)? = nil
) async -> [RunReport] {
    var reports: [RunReport] = []
    var current = angles
    var asked = Set<String>()               // normalized angle prompts already researched → the "nothing new" guard
    var remaining = config.runSpendCapUSD

    for round in 1...max(1, maxRounds) {
        guard !current.isEmpty else { break }
        current.forEach { asked.insert(normalizeSource($0.prompt)) }
        onRound?(round, current)            // fires at round START → the live viz re-fans for the new round

        var cfg = config
        cfg.runSpendCapUSD = remaining      // the SAME wall, minus what earlier rounds already spent
        // All rounds share ONE run dir (the whole dive is one History row): the brain note compounds and
        // every round's angle artifacts land together. Silence per-round "finished" pings — runIterativeFanOut
        // sends ONE at the end for the whole dive, and writes ONE merged digest over the per-round ones.
        let report = await runFanOut(question: question, angles: current, config: cfg,
                                     executor: executor, clock: clock, store: store, power: power,
                                     notifier: SilentNotifier(), runDir: preMadeRunDir, round: round,
                                     onPhase: onPhase, onAngle: onAngle)
        reports.append(report)
        remaining -= report.totalCostUSD

        if Task.isCancelled { break }       // user pressed Stop → keep the rounds we have
        // ponytail: a round needs at least one topic's worth of budget to be worth running; below that,
        // stop rather than spawn near-$0 agents that find nothing. The run cap is the hard wall above this.
        guard remaining >= config.perTopicSpendCapUSD else { break }

        let synth = report.entries.first { $0.isSynthesis == true }
        current = followUpAngles(conflicts: synth?.conflicts ?? [], gaps: synth?.gaps ?? [],
                                 alreadyAsked: asked, limit: angles.count)
        // dry: no unresolved conflicts/gaps we haven't already chased → the research has converged, stop.
        // Autoresearch: converged on questions but NOT on a concrete answer → re-fan on the weak findings
        // to keep digging. `deepenAngles` dedups against `asked`, so a question that can't be settled stops
        // itself (nothing new to try); the budget guard above is the hard wall on top of that.
        if current.isEmpty, autoresearch, let synth, !isConcrete(synth) {
            current = deepenAngles(findings: synth.findings ?? [], question: question,
                                   alreadyAsked: asked, limit: angles.count)
        }
    }

    // One merged digest for the whole dive (all rounds, round-tagged) over the per-round ones, and one ping.
    if let merged = mergeReports(reports) {
        if let dir = preMadeRunDir { _ = try? store.writeDigest(merged, inRunDirectory: dir) }
        notifier.notifyRunFinished(merged)
    }
    return reports
}

/// Turn a synthesis's UNRESOLVED conflicts + gaps into the next round's research angles: each conflict
/// becomes a "resolve this disagreement" angle, each gap an "investigate this open question" angle. Drops
/// anything already researched in a prior round (dedup on the normalized prompt) so the loop converges
/// instead of re-chasing the same point, and caps the count so round sizes don't balloon. `[]` == dry.
func followUpAngles(conflicts: [Conflict], gaps: [String],
                    alreadyAsked: Set<String>, limit: Int) -> [ResearchAngle] {
    var candidates: [ResearchAngle] = []
    for c in conflicts {
        let positions = c.positions.map { "- \($0)" }.joined(separator: "\n")
        candidates.append(ResearchAngle(title: "Resolve: \(shortTitle(c.claim))", prompt: """
            Prior parallel research reached conflicting conclusions on this point. Resolve it with \
            authoritative, primary sources — or explain precisely why it is genuinely unsettled.

            Disputed: \(c.claim)
            Positions found:
            \(positions)
            """))
    }
    for g in gaps {
        candidates.append(ResearchAngle(title: shortTitle(g), prompt: """
            Prior research left this question open. Investigate it directly and answer it with sources:

            \(g)
            """))
    }
    var seen = alreadyAsked
    var deduped: [ResearchAngle] = []
    for a in candidates {
        let key = normalizeSource(a.prompt)
        guard !seen.contains(key) else { continue }   // already chased in an earlier round → not new
        seen.insert(key)
        deduped.append(a)
    }
    return Array(deduped.prefix(max(1, limit)))
}

/// Is this synthesis a concrete answer? It ran to completion, left no unresolved cross-angle conflict,
/// and landed at least one medium-or-better finding. An inconclusive result, or one where every finding
/// is low/unverified, is NOT concrete — autoresearch keeps digging on those instead of filing a non-answer.
func isConcrete(_ entry: RunReport.TopicEntry) -> Bool {
    guard entry.status == .complete, (entry.conflicts ?? []).isEmpty else { return false }
    return (entry.findings ?? []).contains { $0.confidence == .high || $0.confidence == .medium }
}

/// The autoresearch deepen step: when a round converged (no new conflicts/gaps) but the answer isn't
/// concrete, turn its WEAK findings into the next round's angles — each "confirm or refute this with
/// primary sources". With no findings at all (a bare inconclusive), re-attack the original question for a
/// definitive answer. Dedups against prior rounds so an unanswerable point stops itself; `[]` == stop.
func deepenAngles(findings: [Finding], question: String,
                  alreadyAsked: Set<String>, limit: Int) -> [ResearchAngle] {
    let weak = findings.filter { $0.confidence == .low || $0.confidence == .unverified }
    var candidates: [ResearchAngle] = []
    if weak.isEmpty {
        candidates.append(ResearchAngle(title: "Settle: \(shortTitle(question))", prompt: """
            Prior parallel research could not reach a concrete answer to this question. Investigate it \
            directly with primary, authoritative sources and give a definitive answer — or state precisely \
            what evidence is missing and why it is genuinely unsettled.

            Question: \(question)
            """))
    } else {
        for f in weak {
            candidates.append(ResearchAngle(title: "Confirm: \(shortTitle(f.claim))", prompt: """
                Prior research stated this but could not confirm it (low confidence / unverified). Verify it \
                with primary, authoritative sources: confirm it, refute it, or explain why it cannot be settled.

                Claim: \(f.claim)
                """))
        }
    }
    var seen = alreadyAsked
    var deduped: [ResearchAngle] = []
    for a in candidates {
        let key = normalizeSource(a.prompt)
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        deduped.append(a)
    }
    return Array(deduped.prefix(max(1, limit)))
}

private func shortTitle(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.count > 60 ? String(t.prefix(57)) + "…" : t
}

/// Fold every round's report into one dive-level report (summed spend, all entries in round order) — the
/// basis for the single "finished" notification. Pure; nil for an empty run so no ping fires.
func mergeReports(_ reports: [RunReport]) -> RunReport? {
    guard let first = reports.first, let last = reports.last else { return nil }
    return RunReport(startedAt: first.startedAt, finishedAt: last.finishedAt,
                     entries: reports.flatMap(\.entries),
                     totalCostUSD: reports.reduce(Decimal(0)) { $0 + $1.totalCostUSD },
                     runSpendCapUSD: first.runSpendCapUSD)
}

/// A `Notifier` that drops the signal — used to mute `runFanOut`'s per-round "finished" ping so an
/// iterative dive fires exactly one at the end.
private struct SilentNotifier: Notifier { func notifyRunFinished(_ report: RunReport) {} }

// MARK: - Synthesis (the fan-in summariser)

private func synthesize(question: String, angleFindings: [TopicFindings], config: RunSettings,
                        executor: ResearchExecutor, clock: RunClock, ledger: RunLedger) async -> TopicFindings {
    // Whatever's left of the run cap, up to the per-topic cap, is the summariser's budget.
    let synthCap = min(config.perTopicSpendCapUSD, max(0, config.runSpendCapUSD - ledger.total))
    let runCfg = GuardrailMapper.runConfig(preset: config.defaultPreset, perTopicSpendCap: synthCap,
                                           perTopicTimeout: config.perTopicTimeout, depthOverride: nil)
    let prepared = PreparedTopic(id: "synthesis-\(question.hashValue)", question: question,
                                 context: synthesisContext(question: question, angles: angleFindings,
                                                           template: config.synthesisTemplate ?? .general),
                                 projectURL: config.projectURL, priorNotes: [], useProjectContext: false,
                                 preset: config.defaultPreset, runConfig: runCfg, role: .synthesis)
    let outcome = await Supervisor.supervise(prepared, executor: executor, clock: clock,
                                             runSpent: ledger.total, runCap: config.runSpendCapUSD,
                                             startedAt: clock.now(), onCharge: { ledger.charge($0) })
    return outcome.findings
}

// MARK: - Citation grounding (deterministic flag + one gated cheap repair)

/// Flag any citation the synthesis used that NO angle ever cited — a likely fabrication (the intent of
/// Anthropic's CitationAgent without a second full agent). Deterministic and free. If flags exist, fire
/// ONE cheap low-effort call to correct them, then surface the check honestly in the writeup. Never
/// makes things worse: on any repair failure we keep the original synthesis plus the honest flag.
func groundCitations(_ synthesis: TopicFindings, angles: [TopicFindings], config: RunSettings,
                     executor: ResearchExecutor, clock: RunClock, ledger: RunLedger) async -> TopicFindings {
    let angleSources = Set(angles.flatMap { $0.findings.flatMap(\.sources) }.map(normalizeSource))
    let untraceable = Set(synthesis.findings.flatMap(\.sources).map(normalizeSource))
        .subtracting(angleSources)
        .subtracting([""])
    guard !untraceable.isEmpty else { return synthesis }   // clean → nothing to do, $0

    var repaired = synthesis
    // Gated cheap repair: only reached when there's a flag, so typical runs never pay for it.
    let cap = min(Decimal(0.05), max(0, config.runSpendCapUSD - ledger.total))
    if cap > 0 {
        let runCfg = GuardrailMapper.runConfig(preset: config.defaultPreset, perTopicSpendCap: cap,
                                               perTopicTimeout: config.perTopicTimeout, depthOverride: nil)
        let prepared = PreparedTopic(id: "verify-\(synthesis.id)", question: "citation check",
                                     context: verifyContext(synthesis, angleSources: angleSources),
                                     projectURL: config.projectURL, useProjectContext: false,
                                     preset: config.defaultPreset, runConfig: runCfg, role: .verify)
        let outcome = await Supervisor.supervise(prepared, executor: executor, clock: clock,
                                                 runSpent: ledger.total, runCap: config.runSpendCapUSD,
                                                 startedAt: clock.now(), onCharge: { ledger.charge($0) })
        if !outcome.findings.findings.isEmpty {
            repaired = rebuild(synthesis, withFindings: outcome.findings.findings)   // keep writeup, swap findings
        }
    }

    // Whether or not repair ran, surface the check honestly in the note.
    let remaining = Set(repaired.findings.flatMap(\.sources).map(normalizeSource))
        .subtracting(angleSources).subtracting([""])
    return annotateCitationCheck(repaired, untraceable: remaining)
}

/// The verify call's input: the synthesis findings + the full list of sources the angles actually cited.
func verifyContext(_ synthesis: TopicFindings, angleSources: Set<String>) -> String {
    var s = "Sources the underlying research actually cited (a citation not in this list is unsupported):\n"
    for u in angleSources.sorted() where !u.isEmpty { s += "- \(u)\n" }
    s += "\nSynthesis findings to check:\n"
    for f in synthesis.findings {
        s += "- claim: \(f.claim)\n  confidence: \(f.confidence.rawValue)\n  sources: \(f.sources.joined(separator: ", "))\n"
    }
    return s
}

private func rebuild(_ f: TopicFindings, withFindings findings: [Finding]) -> TopicFindings {
    TopicFindings(id: f.id, status: f.status, preset: f.preset, headline: f.headline,
                  findings: findings, conflicts: f.conflicts, gaps: f.gaps, sourcesConsulted: f.sourcesConsulted,
                  costUSD: f.costUSD, duration: f.duration, writeupMarkdown: f.writeupMarkdown,
                  transcript: f.transcript, note: f.note, sessionID: f.sessionID, rateLimit: f.rateLimit)
}

/// Append an honest "## Citation check" section listing any citation still not traceable to an angle.
private func annotateCitationCheck(_ f: TopicFindings, untraceable: Set<String>) -> TopicFindings {
    guard !untraceable.isEmpty else { return f }
    var block = "\n\n## Citation check\n\n"
    block += "⚠️ \(untraceable.count) citation(s) in this synthesis could not be traced to any angle's "
    block += "sources — treat them as unverified:\n\n"
    for u in untraceable.sorted() { block += "- \(u)\n" }
    let note = f.note ?? "\(untraceable.count) untraceable citation(s) — see Citation check."
    return TopicFindings(id: f.id, status: f.status, preset: f.preset, headline: f.headline,
                         findings: f.findings, conflicts: f.conflicts, gaps: f.gaps, sourcesConsulted: f.sourcesConsulted,
                         costUSD: f.costUSD, duration: f.duration,
                         writeupMarkdown: f.writeupMarkdown + block,
                         transcript: f.transcript, note: note, sessionID: f.sessionID, rateLimit: f.rateLimit)
}

/// The summariser's input: the N independent writeups, bounded so many angles can't blow the prompt.
/// This is the ONLY place angle outputs are combined — and only the summariser ever sees them.
func synthesisContext(question: String, angles: [TopicFindings],
                      template: ResearchTemplate = .general) -> String {
    var s = "You are given \(angles.count) INDEPENDENT research writeups, each investigating a "
    s += "different angle of the same question. They did not see each other. Reconcile them into ONE "
    s += "answer: state where they agree, flag conflicts and gaps, and synthesize — do not just "
    s += "concatenate them.\n\n"
    let shape = template.synthesisInstructions   // template shapes the deliverable; empty for .general
    if !shape.isEmpty { s += shape + "\n\n" }
    s += "Original question: \(question)\n\n"
    let table = corroboration(angles).filter { $0.count > 1 }   // singletons add noise, not corroboration
    if !table.isEmpty {
        s += "Sources multiple angles independently cited (more angles = better corroborated):\n"
        for (url, count) in table { s += "- \(url) — \(count) of \(angles.count) angles\n" }
        s += "\n"
    }
    for (i, a) in angles.enumerated() {
        let body = a.writeupMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = body.count > 4000 ? String(body.prefix(4000)) + "\n…(truncated)" : body
        s += "===== ANGLE \(i + 1): \(a.headline) (\(a.status.label)) =====\n"
        s += (excerpt.isEmpty ? "_no findings gathered_" : excerpt) + "\n\n"
    }
    return s
}

/// Deduped source URLs across all angles, each with how many DISTINCT angles cited it, most-corroborated
/// first. Pure/deterministic — the cheap way to weight corroboration and dedup without an extra LLM call.
func corroboration(_ angles: [TopicFindings]) -> [(url: String, count: Int)] {
    var counts: [String: Int] = [:]           // normalized url → distinct-angle count
    var display: [String: String] = [:]       // normalized url → first-seen original form
    for a in angles {
        let urls = Set(a.findings.flatMap(\.sources).map(normalizeSource).filter { !$0.isEmpty })
        for u in urls {
            counts[u, default: 0] += 1
            if display[u] == nil { display[u] = u }
        }
    }
    return counts.map { (display[$0.key] ?? $0.key, $0.value) }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
}

/// Normalize a citation for dedup/matching: trim, drop a trailing slash, lowercase the scheme+host but
/// keep the path (a naive canonical form — good enough to collapse the same URL cited two ways).
func normalizeSource(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    while t.hasSuffix("/") { t.removeLast() }
    return t.lowercased()
}

// MARK: - Budget helpers

/// Split the run cap into equal slices (angles + synthesis), never exceeding the user's per-topic cap.
func capPerAgent(runCap: Decimal, perTopicCap: Decimal, slices: Int) -> Decimal {
    guard slices > 0 else { return perTopicCap }
    return min(perTopicCap, runCap / Decimal(slices))
}

/// Thread-safe running total of a fan-out run's spend. Lock-guarded (not an actor) so `charge` can be
/// called synchronously from the executor's streamed-cost callback, mirroring `TopicMonitor`.
public final class RunLedger: @unchecked Sendable {
    private let lock = NSLock()
    private let cap: Decimal
    private var _total: Decimal = 0

    public init(cap: Decimal) { self.cap = cap }

    @discardableResult
    public func charge(_ amount: Decimal) -> Decimal { lock.withLock { _total += amount; return _total } }
    public var total: Decimal { lock.withLock { _total } }
    public var tripped: Bool { lock.withLock { _total >= cap } }
}

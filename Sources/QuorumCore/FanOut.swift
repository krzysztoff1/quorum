import Foundation

/// Fan-out research: decompose ONE question into N angles, research them with N *blind* parallel
/// agents (no agent sees another's findings), then a single summariser reconciles them into one note.
/// Map-reduce over the existing seams — angles reuse `Supervisor.supervise` + `ResearchExecutor.run`;
/// the summariser is just a `run` with `role: .synthesis`.

public enum FanOutPhase: String, Sendable, Equatable, CaseIterable {
    case planning, awaitingApproval, researching, synthesizing, verifying, validating, done
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
                      stagger: Duration = .zero,
                      runDir preMadeRunDir: URL? = nil, round: Int? = nil,
                      pipeline: RunPipeline = .inProcess,
                      onPhase: (@Sendable (FanOutPhase) -> Void)? = nil,
                      onAngle: (@Sendable (_ id: String, _ status: TopicStatus) -> Void)? = nil,
                      onAngleFinding: (@Sendable (_ index: Int, _ finding: TopicFindings) -> Void)? = nil,
                      onSynthesis: (@Sendable (TopicFindings) -> Void)? = nil) async -> RunReport {
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
                               totalCostUSD: 0, runSpendCapUSD: config.runSpendCapUSD, profile: config.profile,
                               pipeline: pipeline)
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
                             context: ResearchPrompts.answerLanguage(question: question),
                             presetOverride: angle.preset,
                             useProjectContext: config.useProjectContext),
                run: cfg, priorNotes: priorNotes)
            group.addTask {
                // Stagger the launches so angle 0 warms the shared prompt cache before the rest fire
                // (they then cache-read the system prefix instead of each cache-writing it). Uses the
                // injected clock, so tests don't wait; `startedAt: clock.now()` below stays AFTER this
                // sleep, so each angle still gets its full per-topic timeout. Default .zero = no stagger.
                if stagger > .zero {
                    let target = angleStaggerTarget(base: startedAt, index: i, step: stagger)
                    if clock.now() < target { try? await clock.sleep(until: target) }
                }
                onAngle?(angle.id, .running)
                let outcome = await Supervisor.supervise(prepared, executor: executor, clock: clock,
                                                         runSpent: 0, runCap: config.runSpendCapUSD,
                                                         startedAt: clock.now(),
                                                         onCharge: { ledger.charge($0) })
                onAngle?(angle.id, outcome.findings.status)
                onAngleFinding?(i, outcome.findings)
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
    onSynthesis?(synthesis)   // iterative dives collect each round's synthesis (with its writeup) to reconcile at the end

    // File it: the summary is the one durable note; angle writeups become run artifacts.
    // Nothing in this pipeline snapshots a page, so every quote it carries is unchecked and says so —
    // the same sentence a run whose search tier keeps no snapshot carries (PRD 07 R1).
    let entries = persistFanOutRound(synthesis: synthesis, angleFindings: findings,
                                     angleTitles: angles.map(\.title), question: question, config: config,
                                     store: store, runDir: runDir, priorNotes: priorNotes, round: round,
                                     at: clock.now(), evidence: EvidenceIndex(grounding: .none))

    let report = RunReport(startedAt: startedAt, finishedAt: clock.now(), entries: entries,
                           totalCostUSD: ledger.total, runSpendCapUSD: config.runSpendCapUSD,
                           profile: config.profile, pipeline: pipeline)
    if let runDir { _ = try? store.writeDigest(report, inRunDirectory: runDir) }
    onPhase?(.done)
    notifier.notifyRunFinished(report)
    return report
}

/// Persist one completed fan-out round and return its report entries — the summary becomes the durable
/// note, the angle writeups become run artifacts. Shared by the Swift orchestrator (`runFanOut`) and the
/// engine-run consumer (fan-out in TS), so both file findings into the brain identically.
public func persistFanOutRound(synthesis: TopicFindings, angleFindings: [TopicFindings],
                               angleTitles: [String], question: String, config: RunSettings,
                               store: FindingsStore, runDir: URL?, priorNotes: [URL], round: Int?,
                               at now: Date, evidence registry: EvidenceIndex = EvidenceIndex()) -> [RunReport.TopicEntry] {
    // The captured-source registry is run-wide (the engine reports it once per source), so every writeup
    // resolves its own markers — and renders its own footnotes — against the same documents.
    let summary = withRegistry(synthesis, registry)
    let angles = angleFindings.map { withRegistry($0, registry) }
    var entries: [RunReport.TopicEntry] = []
    var notePath: String?, noteAction: NoteAction?, transcriptPath: String?
    var artifacts: [String] = []
    var transcripts: [String?] = []
    if let runDir, let res = try? store.writeSynthesis(summary, question: question, angles: angles,
                                                       angleTitles: angleTitles, brain: config.projectURL,
                                                       priorNotes: priorNotes, runDir: runDir, at: now) {
        notePath = res.note.path; noteAction = res.action; transcriptPath = res.transcript.path
        artifacts = res.angleArtifacts.map(\.path)
        transcripts = res.angleTranscripts.map { $0?.path }
    }
    entries.append(entry(from: summary, question: question, notePath: notePath,
                         noteAction: noteAction, transcriptPath: transcriptPath, isSynthesis: true,
                         round: round, id: roundScopedSynthesisID(summary.id, round: round),
                         sourcesConsulted: Reporter.distinctSources(([summary] + angles).flatMap(\.findings))))
    for (i, f) in angles.enumerated() {
        let label = i < angleTitles.count ? angleTitles[i] : f.headline
        // Point each angle entry at its writeup artifact so it opens as a readable note (not just chat), and
        // at its OWN log — an angle with no transcript says so rather than handing back its writeup twice.
        let art = i < artifacts.count ? artifacts[i] : nil
        let log = i < transcripts.count ? transcripts[i] : nil
        entries.append(entry(from: f, question: label, notePath: art, noteAction: nil, transcriptPath: log, round: round))
    }
    return entries
}

func roundScopedSynthesisID(_ id: String, round: Int?) -> String {
    guard let round, round > 1 else { return id }
    return "\(id)·round·\(round)"
}

/// The same findings, able to reach every source the run captured — its own resolved quotes win.
func withRegistry(_ f: TopicFindings, _ registry: EvidenceIndex) -> TopicFindings {
    registry.hasNothingToSay ? f : rebuild(f, evidence: f.evidence.merging(registry))
}

/// The same answer, carrying what the run's validators made of it, so the export renders the judgement
/// rather than restating it (PRD 09 R4).
func withValidation(_ f: TopicFindings, _ validation: RunValidation?) -> TopicFindings {
    validation.map { rebuild(f, validation: $0) } ?? f
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
    stagger: Duration = .zero,
    maxRounds: Int = 3, autoresearch: Bool = false, runDir preMadeRunDir: URL? = nil,
    pipeline: RunPipeline = .inProcess,
    onPhase: (@Sendable (FanOutPhase) -> Void)? = nil,
    onAngle: (@Sendable (_ id: String, _ status: TopicStatus) -> Void)? = nil,
    onRound: (@Sendable (_ round: Int, _ angles: [ResearchAngle]) -> Void)? = nil
) async -> [RunReport] {
    var reports: [RunReport] = []
    var current = angles
    var asked = Set<String>()               // normalized angle prompts already researched → the "nothing new" guard
    var remaining = config.runSpendCapUSD
    // Snapshot the note's body BEFORE any round writes — reconciliation rewrites the dive's rounds into
    // one section on top of this, so prior dives (and their dated sections) stay intact (stories 6, 13).
    let preDiveBody = store.noteBody(matching: question, in: config.projectURL)
    let roundMaterials = ReconciliationCollector()   // each round's synthesis plus every angle writeup, for the final fuse

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
                                     notifier: SilentNotifier(), stagger: stagger, runDir: preMadeRunDir, round: round,
                                     pipeline: pipeline, onPhase: onPhase, onAngle: onAngle,
                                     onAngleFinding: { i, finding in roundMaterials.addAngle(round: round, index: i, finding: finding) },
                                     onSynthesis: { roundMaterials.addSynthesis(round: round, finding: $0) })
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

    // Reconciliation: a completed multi-round dive fuses its per-round syntheses into ONE current answer
    // (superseding overturned claims, keeping still-open conflicts) and collapses the dive's rounds into a
    // single note section. Only for 2+ rounds, not cancelled, with a topic's worth of budget left — else the
    // per-round sections the rounds already wrote stand as-is (today's behavior). Needs the shared dive dir.
    var reconciledEntry: RunReport.TopicEntry?
    var reconciledSpend: Decimal = 0
    if let dir = preMadeRunDir, reports.count >= 2, !Task.isCancelled,
       remaining >= config.perTopicSpendCapUSD,
       divergedAcrossRounds(roundMaterials.syntheses) {
        let artifacts = reports.flatMap(\.entries).filter { $0.isSynthesis != true }
            .compactMap { $0.notePath.map { URL(fileURLWithPath: $0) } }
        let related = store.relatedNotes(to: question, in: config.projectURL) + artifacts
        if let (entry, spent) = await reconcile(question: question, rounds: roundMaterials.rounds, relatedLinks: related,
                                                config: config, remaining: remaining, preDiveBody: preDiveBody,
                                                executor: executor, clock: clock, store: store, runDir: dir) {
            reconciledEntry = entry; reconciledSpend = spent
        }
    }

    // One merged digest for the whole dive (all rounds, round-tagged, + any reconciliation), and one ping.
    if var merged = mergeReports(reports) {
        if let rec = reconciledEntry {
            // Add the FULL reconciliation spend (synth call + any citation repair) to the run total, so the
            // digest is honest; the entry itself shows the synth-call cost, like every per-round synthesis.
            merged = RunReport(startedAt: merged.startedAt, finishedAt: clock.now(),
                               entries: merged.entries + [rec], totalCostUSD: merged.totalCostUSD + reconciledSpend,
                               runSpendCapUSD: merged.runSpendCapUSD, profile: merged.profile,
                               pipeline: merged.pipeline)
        }
        if let dir = preMadeRunDir { _ = try? store.writeDigest(merged, inRunDirectory: dir) }
        notifier.notifyRunFinished(merged)
    }
    return reports
}

/// Does a completed multi-round dive actually need reconciling, or did the later rounds just reaffirm the
/// first? Reconcile when any round surfaced a conflict, OR a later round introduced a finding an earlier
/// round didn't have (its claim is new). When every later round only restated earlier claims and nothing
/// conflicted, the fuse is pure reformatting — skip it and let the per-round sections stand (the same
/// fallback used when budget/cancellation skips reconciliation). Pure; conservative — biases to reconcile.
func divergedAcrossRounds(_ rounds: [TopicFindings]) -> Bool {
    guard rounds.count >= 2 else { return false }
    if rounds.contains(where: { !$0.conflicts.isEmpty }) { return true }
    let earlier = Set(rounds.dropLast().flatMap { $0.findings.map { normalizeSource($0.claim) } })
    let last = Set((rounds.last?.findings ?? []).map { normalizeSource($0.claim) })
    return !last.isSubset(of: earlier)
}

/// The final fuse of a multi-round dive: one `.synthesis`-role call over the per-round syntheses plus
/// the underlying angle writeups that produced them, grounded by the same citation tripwire, then
/// written as ONE reconciled section that collapses the dive's rounds. Draws from the same run-cap wall
/// (capped at what the rounds left). Returns nil — falling back to the per-round sections already on
/// disk — when there are <2 rounds, or the call itself comes back empty (a reconciliation error must
/// never leave a worse note than the rounds did; stories 8, 20).
private func reconcile(question: String, rounds: [ReconciliationRound], relatedLinks: [URL],
                       config: RunSettings, remaining: Decimal, preDiveBody: String?,
                       executor: ResearchExecutor, clock: RunClock, store: FindingsStore,
                       runDir: URL) async -> (entry: RunReport.TopicEntry, spent: Decimal)? {
    let syntheses = rounds.map(\.synthesis)
    guard syntheses.count >= 2 else { return nil }
    // The SAME wall, scoped to what the rounds left — so the synth call AND the gated citation repair both
    // draw only from `remaining` (matches how each round scopes its own budget). Total stays ≤ the run cap.
    var cfg = config
    cfg.runSpendCapUSD = remaining
    let ledger = RunLedger(cap: remaining)
    let synthCap = min(config.perTopicSpendCapUSD, remaining)
    let runCfg = GuardrailMapper.runConfig(preset: config.defaultPreset, perTopicSpendCap: synthCap,
                                           perTopicTimeout: config.perTopicTimeout, depthOverride: nil)
    let prepared = PreparedTopic(id: "reconcile-\(question.hashValue)", question: question,
                                 context: reconciliationContext(question: question, rounds: rounds),
                                 projectURL: config.projectURL, priorNotes: [], useProjectContext: false,
                                 preset: config.defaultPreset, runConfig: runCfg, role: .synthesis)
    let outcome = await Supervisor.supervise(prepared, executor: executor, clock: clock,
                                             runSpent: config.runSpendCapUSD - remaining, runCap: config.runSpendCapUSD,
                                             startedAt: clock.now(), onCharge: { ledger.charge($0) })
    var reconciled = outcome.findings
    guard !reconciled.writeupMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

    // Same deterministic citation tripwire the per-round syntheses use: the rounds are this pass's "angles".
    reconciled = await groundCitations(reconciled, angles: rounds.flatMap(\.angles), config: cfg,
                                       executor: executor, clock: clock, ledger: ledger)

    // The fused answer stands on the whole dive's reading, not on its own reference list.
    let sources = Reporter.distinctSources(
        rounds.flatMap { $0.angles + [$0.synthesis] }.flatMap(\.findings) + reconciled.findings)
    var notePath: String?, transcriptPath: String?, action: NoteAction?
    if let res = try? store.writeReconciliation(reconciled, question: question, relatedLinks: relatedLinks,
                                                brain: config.projectURL, runDir: runDir,
                                                preDiveBody: preDiveBody, at: clock.now(),
                                                sourcesConsulted: sources) {
        notePath = res.note.path; transcriptPath = res.transcript.path; action = res.action
    }
    // round: nil keeps the reconciliation OUT of the History fan diagram's per-round grouping (story 17) —
    // it's the fuse of the rounds, not another round. `ledger.total` is the full spend (synth + any repair).
    let entry = entry(from: reconciled, question: question, notePath: notePath, noteAction: action,
                      transcriptPath: transcriptPath, isSynthesis: true, round: nil,
                      sourcesConsulted: sources)
    return (entry, ledger.total)
}

/// The reconciliation call's input: one dive's per-round syntheses, framed as sequential rounds where each
/// later round was run to correct/deepen the earlier ones, plus the individual angle writeups that fed
/// them. Lives behind the executor seam (impure) — the prompt only supplies the raw materials and asks
/// for one clean current answer. Not unit-tested, consistent with `synthesisContext`.
func reconciliationContext(question: String, rounds: [ReconciliationRound]) -> String {
    var s = "You are reconciling \(rounds.count) SEQUENTIAL rounds of research on the SAME question.\n"
    s += "Your job is to produce one clean current answer.\n"
    s += "Use the best format for the material: a short narrative, bullets, or headings if they help.\n"
    s += "Read the round syntheses and the underlying angle writeups. When a later round corrected an\n"
    s += "earlier one, treat the corrected position as the standing answer\n"
    s += "and do not keep the superseded claim alive. Preserve only the disagreements and gaps that still\n"
    s += "remain unresolved after the final round. Weight corroboration across rounds more heavily than\n"
    s += "mere recency.\n\n"
    s += "Original question: \(question)\n\n"
    for (i, r) in rounds.enumerated() {
        let body = r.synthesis.writeupMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = body.count > 4000 ? String(body.prefix(4000)) + "\n…(truncated)" : body
        s += "===== ROUND \(i + 1): \(r.synthesis.headline) =====\n"
        s += (excerpt.isEmpty ? "_no writeup_" : excerpt) + "\n"
        if !r.synthesis.conflicts.isEmpty {
            s += "Round \(i + 1) unresolved conflicts:\n"
            for c in r.synthesis.conflicts { s += "- \(c.claim): \(c.positions.joined(separator: " / "))\n" }
        }
        if !r.synthesis.gaps.isEmpty {
            s += "Round \(i + 1) open gaps:\n"
            for g in r.synthesis.gaps { s += "- \(g)\n" }
        }
        if !r.angles.isEmpty {
            s += "Round \(i + 1) angle writeups:\n"
            for (j, angle) in r.angles.enumerated() {
                s += "----- ANGLE \(j + 1): \(angle.headline) -----\n"
                let angleBody = angle.writeupMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                let angleExcerpt = angleBody.count > 1200 ? String(angleBody.prefix(1200)) + "\n…(truncated)" : angleBody
                s += (angleExcerpt.isEmpty ? "_no writeup_" : angleExcerpt) + "\n"
                if !angle.findings.isEmpty {
                    s += "Findings:\n"
                    for f in angle.findings {
                        s += "- \(f.claim) · \(f.confidence.rawValue) · \(f.sources.joined(separator: ", "))\n"
                    }
                }
            }
        }
        s += "\n"
    }
    return s
}

/// Backward-compatible shim for call sites that only have the per-round syntheses.
func reconciliationContext(question: String, rounds: [TopicFindings]) -> String {
    reconciliationContext(question: question, rounds: rounds.map { ReconciliationRound(synthesis: $0, angles: []) })
}

/// One round's synthesis plus every angle that produced it, for the final reconciliation fuse.
struct ReconciliationRound: Sendable {
    let synthesis: TopicFindings
    let angles: [TopicFindings]
}

/// Collects each round's synthesis and the full set of angle findings as an iterative dive runs, so the
/// final reconciliation can fuse the actual evidence, not just the round-level summary. Lock-guarded
/// like `RunLedger` — appended from `runFanOut`'s callback.
private final class ReconciliationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _rounds: [Int: RoundBucket] = [:]

    func addSynthesis(round: Int, finding: TopicFindings) {
        lock.withLock {
            var bucket = _rounds[round] ?? RoundBucket()
            bucket.synthesis = finding
            _rounds[round] = bucket
        }
    }

    func addAngle(round: Int, index: Int, finding: TopicFindings) {
        lock.withLock {
            var bucket = _rounds[round] ?? RoundBucket()
            bucket.angles[index] = finding
            _rounds[round] = bucket
        }
    }

    var syntheses: [TopicFindings] {
        lock.withLock {
            _rounds.keys.sorted().compactMap { _rounds[$0]?.synthesis }
        }
    }

    var rounds: [ReconciliationRound] {
        lock.withLock {
            _rounds.keys.sorted().compactMap { key in
                guard let bucket = _rounds[key], let synthesis = bucket.synthesis else { return nil }
                let angles = bucket.angles.keys.sorted().compactMap { bucket.angles[$0] }
                return ReconciliationRound(synthesis: synthesis, angles: angles)
            }
        }
    }

    private struct RoundBucket {
        var synthesis: TopicFindings?
        var angles: [Int: TopicFindings] = [:]
    }
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
                     runSpendCapUSD: first.runSpendCapUSD, profile: first.profile,
                     pipeline: first.pipeline)
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
/// Either way the result is then floored against the run's evidence — a claim whose quotes the run could
/// not locate reads as `unverified`, however traceable its URLs were (PRD 03).
func groundCitations(_ synthesis: TopicFindings, angles: [TopicFindings], config: RunSettings,
                     executor: ResearchExecutor, clock: RunClock, ledger: RunLedger) async -> TopicFindings {
    // Every quote the run resolved: the synthesis's own plus the angles' — a synthesis marker legitimately
    // reuses an angle's already-resolved citation, so the wider index is what its claims are checked against.
    let index = angles.reduce(synthesis.evidence) { $0.merging($1.evidence) }
    let angleSources = Set(angles.flatMap { $0.findings.flatMap(\.sources) }.map(normalizeSource))
    let untraceable = Set(synthesis.findings.flatMap(\.sources).map(normalizeSource))
        .subtracting(angleSources)
        .subtracting([""])
    guard !untraceable.isEmpty else { return flooringUnverified(synthesis, in: index) }   // clean → $0

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
    return flooringUnverified(annotateCitationCheck(repaired, untraceable: remaining), in: index)
}

/// Floor a claim's confidence to `unverified` when none of its `[^c1]` markers resolved to a quote the run
/// could actually locate in a stored snapshot (PRD 03). The claim is kept — the codebase's stance is to
/// surface doubt as data, not to hide it. A run that captured no evidence at all (built-in search, nothing
/// to search against) is left untouched: there is no verification to have failed. The widened index rides
/// along on the result, so the note's footnotes can name the sources the angles captured.
func flooringUnverified(_ f: TopicFindings, in index: EvidenceIndex) -> TopicFindings {
    guard !index.citations.isEmpty else { return f }
    let floored = f.findings.map { finding -> Finding in
        guard finding.confidence != .unverified,
              !index.resolve(finding.citationIDs).contains(where: \.isVerified) else { return finding }
        return Finding(claim: finding.claim, sources: finding.sources, confidence: .unverified,
                       citationIDs: finding.citationIDs)
    }
    return rebuild(f, withFindings: floored, evidence: index)
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

private func rebuild(_ f: TopicFindings, withFindings findings: [Finding]? = nil,
                     evidence: EvidenceIndex? = nil, validation: RunValidation? = nil) -> TopicFindings {
    TopicFindings(id: f.id, status: f.status, preset: f.preset, headline: f.headline,
                  findings: findings ?? f.findings, conflicts: f.conflicts, gaps: f.gaps,
                  sourcesConsulted: f.sourcesConsulted,
                  costUSD: f.costUSD, duration: f.duration, writeupMarkdown: f.writeupMarkdown,
                  transcript: f.transcript, note: f.note, sessionID: f.sessionID, rateLimit: f.rateLimit,
                  usage: f.usage, evidence: evidence ?? f.evidence, validation: validation ?? f.validation)
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
                         transcript: f.transcript, note: note, sessionID: f.sessionID, rateLimit: f.rateLimit,
                         usage: f.usage, evidence: f.evidence)
}

/// The summariser's input: the N independent writeups, bounded so many angles can't blow the prompt.
/// This is the ONLY place angle outputs are combined — and only the summariser ever sees them.
func synthesisContext(question: String, angles: [TopicFindings],
                      template: ResearchTemplate = .general) -> String {
    var s = "You are given \(angles.count) INDEPENDENT research writeups, each investigating a "
    s += "different angle of the same question. They did not see each other. Reconcile them into ONE "
    s += "answer: state where they agree, flag conflicts and gaps, and synthesize — do not just "
    s += "concatenate them.\n\n"
    s += "Keep the full writeup under ~\(ResearchPrompts.synthesisWordBudget(angleCount: angles.count)) "
    s += "words — a tight, skimmable answer beats restating every angle.\n\n"
    let shape = template.synthesisInstructions   // template shapes the deliverable; empty for .general
    if !shape.isEmpty { s += shape + "\n\n" }
    s += "Original question: \(question)\n\n"
    let table = corroboration(angles).filter { $0.count > 1 }   // singletons add noise, not corroboration
    if !table.isEmpty {
        s += "Sources multiple angles independently cited (more angles = better corroborated):\n"
        for (url, count) in table { s += "- \(url) — \(count) of \(angles.count) angles\n" }
        s += "\n"
    }
    // Hybrid input: the angle's structured findings (compact, the load-bearing part) + a trimmed prose
    // excerpt for nuance. The findings carry claim/confidence/sources exactly; the excerpt is bounded far
    // tighter than before (angles reason at length, but the summariser only needs the top of it).
    for (i, a) in angles.enumerated() {
        s += "===== ANGLE \(i + 1): \(a.headline) (\(a.status.label)) =====\n"
        if a.findings.isEmpty {
            s += "Findings: none reported.\n"
        } else {
            s += "Findings (claim · confidence · sources):\n"
            for f in a.findings {
                s += "- \(f.claim) · \(f.confidence.rawValue) · \(f.sources.joined(separator: ", "))\n"
            }
        }
        let body = a.writeupMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = body.count > 1500 ? String(body.prefix(1500)) + "\n…(truncated)" : body
        if !excerpt.isEmpty { s += "Writeup excerpt:\n\(excerpt)\n" }
        s += "\n"
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

/// The scheduled start for angle `index` when launches are staggered by `step` off `base`, so angle 0 warms
/// the server-side prompt cache before the rest fire. `step == .zero` collapses to `base` (no stagger). Pure.
func angleStaggerTarget(base: Date, index: Int, step: Duration) -> Date {
    base.addingTimeInterval(Double(index) * step.seconds)
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

func entry(from f: TopicFindings, question: String,
           notePath: String?, noteAction: NoteAction?, transcriptPath: String?,
           isSynthesis: Bool = false, round: Int? = nil, id: String? = nil,
           sourcesConsulted: Int? = nil) -> RunReport.TopicEntry {
    // Deduped cited URLs (order preserved) so History can list the sources, not just count them — and the
    // count IS that list's length (`Reporter.distinctSources`), never the model's own tally of its reading.
    let sources = Reporter.distinctSourceURLs(f.findings)
    return RunReport.TopicEntry(
        id: id ?? f.id, question: question, status: f.status, preset: f.preset, headline: f.headline,
        confidenceSummary: Reporter.confidenceSummary(f.findings),
        sourcesConsulted: sourcesConsulted ?? sources.count,
        costUSD: f.costUSD, durationSeconds: f.duration.seconds, note: f.note,
        notePath: notePath, noteAction: noteAction, transcriptPath: transcriptPath, sessionID: f.sessionID,
        rateLimit: f.rateLimit, isSynthesis: isSynthesis, conflicts: f.conflicts, gaps: f.gaps, round: round,
        sources: sources, findings: f.findings, usage: f.usage,
        // nil, not an empty index, so a run that captured nothing leaves report.json exactly as it was.
        evidence: f.evidence.hasNothingToSay ? nil : f.evidence)
}

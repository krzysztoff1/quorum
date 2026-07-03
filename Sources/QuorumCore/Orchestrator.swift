import Foundation

/// The top-level entry. Works the queue in order, enforces the optional run time budget and run spend
/// cap between topics, supervises each topic, writes each note to disk *as it completes* (so a crash
/// never loses finished work — story 50), and folds the result into the run digest.
///
/// Not `throws`: a run always yields a report, even a partial one. Cancelling the enclosing Task is
/// the manual Stop (story 51) — the in-flight topic hands back its partial and the rest are skipped.
public func runBatch(config: RunSettings, topics: [Topic], executor: ResearchExecutor,
                     clock: RunClock, store: FindingsStore, power: PowerManager,
                     notifier: Notifier,
                     topicStartTimes: [Date]? = nil,   // optional pacing: spread topics across the window
                     onProgress: (@Sendable (_ index: Int, _ total: Int, _ title: String) -> Void)? = nil) async -> RunReport {
    let startedAt = clock.now()
    power.preventSleep(reason: "Quorum research run")
    defer { power.allowSleep() }

    let runDir = try? store.makeRunDirectory(projectURL: config.projectURL, startedAt: startedAt)
    var entries: [RunReport.TopicEntry] = []
    var runSpent: Decimal = 0
    var runStopped = false

    for (i, topic) in topics.enumerated() {
        // --- gates checked BEFORE a topic starts (no new topic starts after any of these) ---
        if runStopped {
            entries.append(skipEntry(topic, config, .skipped,
                                     note: "run spend cap reached before this topic ran"))
            continue
        }
        if Task.isCancelled {
            entries.append(skipEntry(topic, config, .skipped,
                                     note: "stopped manually before this topic ran"))
            continue
        }
        // --- optional pacing: wait until this topic's scheduled slot (spreads across the window) ---
        if let times = topicStartTimes, i < times.count, clock.now() < times[i] {
            try? await clock.sleep(until: times[i])
            if Task.isCancelled {
                entries.append(skipEntry(topic, config, .skipped,
                                         note: "stopped manually before this topic ran"))
                continue
            }
        }
        if let deadline = config.runDeadline, clock.now() >= deadline {
            entries.append(skipEntry(topic, config, .skipped,
                                     note: "run time budget reached before this topic ran"))
            continue
        }

        // --- read the brain first: related prior notes become read-only context (story 30) ---
        let priorNotes = store.relatedNotes(to: topic.question, in: config.projectURL)

        // --- run it under supervision ---
        onProgress?(entries.count + 1, topics.count, topic.question)
        let prepared = GuardrailMapper.prepare(topic: topic, run: config, priorNotes: priorNotes)
        let topicStart = clock.now()
        let outcome = await Supervisor.supervise(prepared, executor: executor, clock: clock,
                                                 runSpent: runSpent, runCap: config.runSpendCapUSD,
                                                 startedAt: topicStart)
        runSpent += outcome.findings.costUSD
        if outcome.runStopped { runStopped = true }

        // --- file it into the brain: extend an existing note or create one (crash-safe, per topic) ---
        var notePath: String?
        var transcriptPath: String?
        var noteAction: NoteAction?
        if let runDir, let res = try? store.write(outcome.findings, question: topic.question,
                                                  brain: config.projectURL, priorNotes: priorNotes,
                                                  runDir: runDir, at: clock.now()) {
            notePath = res.note.path
            transcriptPath = res.transcript.path
            noteAction = res.action
        }
        entries.append(entry(from: outcome.findings, question: topic.question,
                             notePath: notePath, noteAction: noteAction, transcriptPath: transcriptPath))
    }

    let finishedAt = clock.now()
    let report = RunReport(startedAt: startedAt, finishedAt: finishedAt, entries: entries,
                             totalCostUSD: runSpent, runSpendCapUSD: config.runSpendCapUSD)
    if let runDir { _ = try? store.writeDigest(report, inRunDirectory: runDir) }
    notifier.notifyRunFinished(report)
    return report
}

func entry(from f: TopicFindings, question: String,
           notePath: String?, noteAction: NoteAction?, transcriptPath: String?,
           isSynthesis: Bool = false, round: Int? = nil) -> RunReport.TopicEntry {
    // Deduped cited URLs (order preserved) so History can list the sources, not just count them.
    var seen = Set<String>(), sources: [String] = []
    for u in f.findings.flatMap(\.sources) where !u.isEmpty && seen.insert(u).inserted { sources.append(u) }
    return RunReport.TopicEntry(
        id: f.id, question: question, status: f.status, preset: f.preset, headline: f.headline,
        confidenceSummary: Reporter.confidenceSummary(f.findings), sourcesConsulted: f.sourcesConsulted,
        costUSD: f.costUSD, durationSeconds: f.duration.seconds, note: f.note,
        notePath: notePath, noteAction: noteAction, transcriptPath: transcriptPath, sessionID: f.sessionID,
        rateLimit: f.rateLimit, isSynthesis: isSynthesis, conflicts: f.conflicts, gaps: f.gaps, round: round,
        sources: sources)
}

private func skipEntry(_ t: Topic, _ config: RunSettings, _ status: TopicStatus, note: String) -> RunReport.TopicEntry {
    RunReport.TopicEntry(
        id: t.id, question: t.question, status: status,
        preset: t.presetOverride ?? config.defaultPreset, headline: "—", confidenceSummary: "—",
        sourcesConsulted: 0, costUSD: 0, durationSeconds: 0, note: note,
        notePath: nil, noteAction: nil, transcriptPath: nil)
}

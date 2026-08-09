import Foundation
import QuorumCore

/// Dev-only, read-only DEMO playback. Re-streams a finished run from its `report.json` (plus each angle's
/// on-disk writeup) through the SAME live fan-out viz a real run drives — planning → parallel blind angles
/// → synthesis → citation verify, round over round — so a genuine past run can be screen-recorded as if it
/// were happening live. No subprocess, no API calls, no spend, no disk writes: this replaces the old canned
/// dry-run, and because it plays the run's ACTUAL findings/sources/writeups, the recording looks exactly
/// like production (no "dry run" watermark).
///
/// Everything mutates the `@MainActor` `LiveRun`, so playback is MainActor-isolated; the per-step `nap`s
/// suspend (never block) the main actor, letting the angles of a round stream concurrently and the UI
/// animate between updates. Cancelling the run's Task (the Stop button) ends playback promptly.
/// ponytail: pacing is tuned for a ~1-minute recording; `QUORUM_REPLAY_SPEED` (>1 slower, <1 faster) is the
/// knob if a take needs a different tempo.
@MainActor
final class RunReplayer {
    private let run: LiveRun
    private let runDir: URL
    private let report: RunReport
    private let speed: Double

    init(run: LiveRun, runDir: URL, report: RunReport) {
        self.run = run
        self.runDir = runDir
        self.report = report
        self.speed = Double(ProcessInfo.processInfo.environment["QUORUM_REPLAY_SPEED"] ?? "") ?? 1
    }

    // MARK: - Recorded shape

    private typealias Entry = RunReport.TopicEntry

    /// Each iterative round's angle entries + that round's synthesis, in round order. Reconciliation
    /// (round == nil) is left out of the live fan — it surfaces as the top card of the settled digest.
    private var rounds: [(round: Int, angles: [Entry], synth: Entry?)] {
        let angles = report.entries.filter { $0.isSynthesis != true && $0.status != .skipped }
        let groups = Dictionary(grouping: angles) { $0.round ?? 1 }
        return groups.keys.sorted().map { rn in
            (rn, groups[rn] ?? [], report.entries.first { $0.isSynthesis == true && ($0.round ?? -1) == rn })
        }
    }

    // MARK: - Playback

    /// The compose-time draft: stream the planner decomposing the question, then land on the review screen
    /// with the recorded round-1 angles, so a demo starts exactly like a real plan (edit/approve, then run).
    func replayPlanning() async {
        await plan()
        if Task.isCancelled { return }
        let angles = (rounds.first?.angles ?? []).map {
            ResearchAngle(id: $0.id, title: $0.question, prompt: "Research and report on: \($0.question)")
        }
        run.propose(angles)
    }

    /// The launched run: the rounds animating live (planning already happened in the draft) → synthesis →
    /// verify, round over round, ending on the finished fan before the row settles to the on-disk digest.
    func runRounds() async {
        for r in rounds {
            if Task.isCancelled { break }
            run.startRound(r.round, angles: r.angles.map { ResearchAngle(id: $0.id, title: $0.question, prompt: "") })
            run.setPhase(.researching)
            await nap(0.4)
            await withTaskGroup(of: Void.self) { group in
                for e in r.angles { group.addTask { @MainActor in await self.streamAngle(e) } }
            }
            if Task.isCancelled { break }
            if let s = r.synth { await streamSynthesis(s); await streamVerify() }
        }
        run.setPhase(.done)
        await nap(1.5)
    }

    /// The planner decomposing the question — thinking, then round-1 angle titles forming one by one (the
    /// view reads them out of the streamed JSON, never showing the raw JSON).
    private func plan() async {
        run.setPhase(.planning)
        var snap = LiveSnapshot(topicID: "planning", question: "Planning research angles")
        let titles = rounds.first?.angles.map(\.question) ?? []
        snap.thinking = "Decomposing the question into \(titles.count) independent angles to explore in parallel."
        run.apply(snap); await nap(0.9)
        var json = ""
        for t in titles {
            if Task.isCancelled { return }
            json += (json.isEmpty ? "[" : ",") + "{\"title\":\"\(jsonEscape(t))\"}"
            snap.output = json + "]"
            run.apply(snap); await nap(0.5)
        }
        await nap(0.4)
    }

    /// One blind angle streaming: thinking → its consulted sources ticking in → the writeup growing, with
    /// cost ramping to the recorded total across every step so the fan node's spend climbs live.
    private func streamAngle(_ e: Entry) async {
        let id = e.id
        run.setAngleStatus(id, .running)
        let sources = e.sources ?? []
        let writeChunks = chunks(angleWriteup(e), into: 14)
        let steps = max(1, 1 + sources.count + writeChunks.count)
        let inc = e.costUSD / Decimal(steps)
        var snap = LiveSnapshot(topicID: id, question: e.question)
        var spent = Decimal(0), left = steps
        func charge() { left -= 1; spent = left == 0 ? e.costUSD : spent + inc; snap.costUSD = spent }

        snap.thinking = "Researching “\(e.question)” — searching the web, reading sources, and cross-checking."
        charge(); run.apply(snap); await nap(0.5)
        // Stamped as they land, not when the list was built — the trace reads `at` as the tick's position.
        for s in sources {
            if Task.isCancelled { break }
            snap.sources.append(LiveSource(kind: s.hasPrefix("http") ? "WebFetch" : "WebSearch",
                                           value: s, at: Date()))
            charge(); run.apply(snap); await nap(0.11)
        }
        for c in writeChunks {
            if Task.isCancelled { break }
            if snap.writingStartedAt == nil { snap.writingStartedAt = Date() }
            snap.output += c; charge(); run.apply(snap); await nap(0.45)
        }
        run.setAngleStatus(id, e.status)
    }

    /// The fan-in summariser reconciling the angle writeups — reconstructed from the recorded conflicts,
    /// gaps, and findings (the per-round synthesis prose isn't kept on disk).
    private func streamSynthesis(_ e: Entry) async {
        run.setPhase(.synthesizing)
        let writeChunks = chunks(synthesisWriteup(e), into: 12)
        let steps = max(1, 1 + writeChunks.count)
        let inc = e.costUSD / Decimal(steps)
        var snap = LiveSnapshot(topicID: e.id, question: e.question)   // e.id begins "synthesis-" → synthesisLive
        var spent = Decimal(0), left = steps
        func charge() { left -= 1; spent = left == 0 ? e.costUSD : spent + inc; snap.costUSD = spent }

        snap.thinking = "Reconciling the independent angle writeups — matching claims, surfacing conflicts, marking gaps."
        charge(); run.apply(snap); await nap(0.7)
        for c in writeChunks {
            if Task.isCancelled { break }
            if snap.writingStartedAt == nil { snap.writingStartedAt = Date() }
            snap.output += c; charge(); run.apply(snap); await nap(0.5)
        }
    }

    /// The cheap, gated citation-grounding re-check shown as its own stage after the synthesis.
    private func streamVerify() async {
        run.setPhase(.verifying)
        var snap = LiveSnapshot(topicID: "verify", question: "citation check")
        snap.thinking = "Checking each cited URL traces back to a source an angle actually consulted."
        run.apply(snap); await nap(0.9)
        if Task.isCancelled { return }
        snap.writingStartedAt = Date()
        snap.output = "Every citation grounded in a consulted source."
        run.apply(snap); await nap(0.9)
    }

    // MARK: - Content

    /// The angle's recorded writeup, resolved by basename within the current run dir (so it survives the
    /// folder being renamed after auto-titling, which leaves the absolute path in `report.json` stale).
    private func angleWriteup(_ e: Entry) -> String {
        if let name = (e.notePath ?? e.transcriptPath).map({ URL(fileURLWithPath: $0).lastPathComponent }) {
            let url = runDir.appendingPathComponent(name)
            if let s = try? String(contentsOf: url, encoding: .utf8), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return fallbackWriteup(e)
    }

    private func fallbackWriteup(_ e: Entry) -> String {
        var s = "## \(e.headline)\n\n"
        for f in e.findings ?? [] {
            s += "- **[\(f.confidence.rawValue)]** \(f.claim)\n"
            for src in f.sources { s += "  - \(src)\n" }
        }
        return s
    }

    private func synthesisWriteup(_ e: Entry) -> String {
        var s = "## \(e.headline)\n\nReconciled answer built from the independent angle writeups.\n"
        if let c = e.conflicts, !c.isEmpty {
            s += "\n## Open conflicts\n"
            for x in c { s += "- \(x.claim) (\(x.positions.joined(separator: "; ")))\n" }
        }
        if let g = e.gaps, !g.isEmpty {
            s += "\n## Gaps & open questions\n"
            for x in g { s += "- \(x)\n" }
        }
        if let f = e.findings, !f.isEmpty {
            s += "\n## Findings\n"
            for x in f { s += "- **[\(x.confidence.rawValue)]** \(x.claim)\n" }
        }
        return s
    }

    // MARK: - Helpers

    private func nap(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds * speed))
    }

    private func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
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
}

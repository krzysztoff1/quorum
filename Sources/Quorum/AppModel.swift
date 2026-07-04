import Foundation
import SwiftUI
import AppKit
import QuorumCore

/// Which Claude model a CLI invocation runs on. `.default` passes no `--model`, so the CLI uses its
/// own configured default. A global user preference (UserDefaults), chosen separately for the chat
/// and the research agents (the fan-out "subagents"). The CLI validates the alias — we don't.
enum ModelChoice: String, CaseIterable, Sendable {
    case `default`, opus, sonnet, haiku, fable

    /// Version-specific name shown in the picker.
    var displayName: String {
        switch self {
        case .default: return "Default"
        case .opus:    return "Opus 4.8"
        case .sonnet:  return "Sonnet 5"
        case .haiku:   return "Haiku 4.5"
        case .fable:   return "Fable 5"
        }
    }

    /// Full model ID passed to `--model`. nil for `.default` (the CLI's own default).
    /// Pinned to the exact version (not the bare `opus`/`sonnet` alias) so the version
    /// and price shown in the UI always match what actually runs.
    var modelID: String? {
        switch self {
        case .default: return nil
        case .opus:    return "claude-opus-4-8"
        case .sonnet:  return "claude-sonnet-5"
        case .haiku:   return "claude-haiku-4-5"
        case .fable:   return "claude-fable-5"
        }
    }

    /// Input / output USD per million tokens (standard list price).
    /// ponytail: hardcoded list prices — update here if Anthropic pricing changes.
    var pricing: String? {
        switch self {
        case .default: return nil
        case .opus:    return "$5 / $25"
        case .sonnet:  return "$3 / $15"
        case .haiku:   return "$1 / $5"
        case .fable:   return "$10 / $50"
        }
    }

    /// Picker row: "Opus 4.8 · $5 / $25 per Mtok".
    var menuLabel: String {
        guard let pricing else { return displayName }
        return "\(displayName) · \(pricing) per Mtok"
    }

    var args: [String] { modelID.map { ["--model", $0] } ?? [] }

    /// Read the value `@AppStorage` wrote for `key` (it stores the rawValue string).
    static func stored(_ key: String) -> ModelChoice {
        ModelChoice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .default
    }
}

enum RunState: Equatable { case idle, running, finished }

/// One angle in a fan-out run: the (editable-in-review) angle plus its live status for the viz.
struct AngleState: Identifiable {
    var angle: ResearchAngle
    var status: TopicStatus = .queued
    var id: String { angle.id }
}

/// The state of a fan-out ("explore every angle") run, driving the radial visualization.
struct FanOutState {
    var question: String
    var count: Int
    var phase: FanOutPhase
    var angles: [AngleState] = []   // proposed → user-edited → live (the CURRENT round's angles)
    // Iterative fan-out: the dive deepens round over round (round 2+ chases the synthesis's unresolved
    // conflicts + gaps). `round` is 1-based; `roundAngleCounts[i]` is how many angles round i+1 fanned out.
    var round: Int = 1
    var roundAngleCounts: [Int] = []
}

/// One fan-out run's live state, owned individually so several can run at once. Used for both the
/// compose-time draft (planning → angle approval) and a launched run watched live in History — the
/// same `FanOutView` renders either. `id` is a temp UUID while a draft, the run-dir stamp once launched.
@MainActor
@Observable
final class LiveRun: Identifiable {
    let id: String
    var fanOut: FanOutState
    var planningLive = LiveSnapshot()               // the planner's decomposition, streamed live
    var liveByAngle: [String: LiveSnapshot] = [:]   // per-angle stream, keyed by angle id
    var synthesisLive = LiveSnapshot()              // the summariser's stream
    @ObservationIgnored var task: Task<Void, Never>?

    init(id: String, fanOut: FanOutState) { self.id = id; self.fanOut = fanOut }

    /// Route a streamed snapshot to the right slot (mirrors the executor's topicID convention).
    func apply(_ snap: LiveSnapshot) {
        withAnimation(.easeOut(duration: 0.25)) {
            if snap.topicID == "planning" { planningLive = snap }
            else if snap.topicID.hasPrefix("synthesis") || snap.topicID.hasPrefix("verify") { synthesisLive = snap }
            else { liveByAngle[snap.topicID] = snap }
        }
    }
    func setPhase(_ phase: FanOutPhase) { fanOut.phase = phase }
    func setAngleStatus(_ id: String, _ status: TopicStatus) {
        if let i = fanOut.angles.firstIndex(where: { $0.id == id }) { fanOut.angles[i].status = status }
    }

    /// A new iterative round is starting — re-fan the viz onto this round's angles (round 2+ chases the
    /// prior synthesis's unresolved conflicts + gaps) so the research is seen to grow.
    func startRound(_ round: Int, angles: [ResearchAngle]) {
        withAnimation(.easeOut(duration: 0.3)) {
            fanOut.round = round
            fanOut.angles = angles.map { AngleState(angle: $0) }
            if fanOut.roundAngleCounts.count < round { fanOut.roundAngleCounts.append(angles.count) }
            liveByAngle = [:]
            synthesisLive = LiveSnapshot()
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // Project
    var projectURL: URL?
    var preflight: PreflightResult?

    // Guardrails (persisted per project)
    var runSpendCap = Decimal(20)
    var perTopicSpendCap = Decimal(2)
    var perTopicTimeoutMinutes = 20
    var defaultPreset: EffortPreset = .standard
    var useProjectContext = false   // let the parallel research agents read this project (read-only)
    var synthesisTemplate: ResearchTemplate = .general   // fan-out deliverable shape (item 8 — research templates)

    // Dev-only dry run: no subprocess, no API calls, $0 — exercises the whole flow fast. Can only be
    // true in a `swift run` launch (AppEnv.isDev); a shipped build never shows the toggle or the engine.
    var dryRun = AppEnv.isDev && AppEnv.dryRunRequested

    // Fan-out ("explore every angle") — one question → N blind parallel agents → 1 synthesis.
    // `draftRun` is the compose-time plan/approve step (one at a time); launching it moves a run into
    // `activeRuns` (keyed by run-dir stamp) where several research in parallel, each shown live in History.
    var draftRun: LiveRun?
    var activeRuns: [String: LiveRun] = [:]
    var focusRun: String?          // one-shot: tells ContentView to select this stamp, then is cleared
    var focusCompose = false       // one-shot: "Research this" from the health check → jump to the compose draft

    // History
    var runs: [URL] = []
    private var titlingTask: Task<Void, Never>?

    // Notes ("Mds") — the project's markdown files as a folder tree, browsed/edited in the sidebar.
    var noteTree: [NoteTreeNode] = []

    private let store = DiskFindingsStore()

    var projectName: String { projectURL?.lastPathComponent ?? "No project" }

    // MARK: Project

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }

    func openProject(_ url: URL) {
        // Runs belong to a project — cancel and drop any in flight before switching contexts.
        discardDraft()
        activeRuns.values.forEach { $0.task?.cancel() }
        activeRuns = [:]; focusRun = nil
        projectURL = url
        rememberProject(url)
        loadState()
        refreshRuns()
        refreshNotes()
        preflight = Preflight.check(ClaudeCLIProbe())
    }

    // MARK: Recent projects (persisted so you don't re-pick every launch)

    private let defaults = UserDefaults.standard

    var recentProjects: [URL] {
        (defaults.stringArray(forKey: "recentProjects") ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Reopen the last project on launch.
    func restoreLastProject() {
        guard projectURL == nil,
              let path = defaults.string(forKey: "lastProject"),
              FileManager.default.fileExists(atPath: path) else { return }
        openProject(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func rememberProject(_ url: URL) {
        defaults.set(url.path, forKey: "lastProject")
        var recents = defaults.stringArray(forKey: "recentProjects") ?? []
        recents.removeAll { $0 == url.path }
        recents.insert(url.path, at: 0)
        defaults.set(Array(recents.prefix(8)), forKey: "recentProjects")
    }

    // MARK: Running

    /// Is the run with this stamp still researching (in `activeRuns`)? Finished runs are removed and
    /// shown from disk. Used by the sidebar (spinner) and the detail router (live vs. digest).
    func isRunning(_ stamp: String) -> Bool { activeRuns[stamp] != nil }

    /// For the Dock badge: running if any research run is in flight or a draft is planning.
    var overallRunState: RunState {
        if !activeRuns.isEmpty || draftRun?.fanOut.phase == .planning { return .running }
        return .idle
    }

    /// Overall angle completion across all in-flight runs, 0–100, for the menu-bar readout. nil when
    /// nothing has fanned out yet (idle, or a draft still planning) so the label shows just the icon.
    var progressPercent: Int? {
        let angles = activeRuns.values.flatMap { $0.fanOut.angles }
        guard !angles.isEmpty else { return nil }
        let done = angles.filter { $0.status != .queued && $0.status != .running }.count
        return done * 100 / angles.count
    }

    /// Stop one research run — hands back its partial (runFanOut never throws) and removes it on return.
    func stop(_ run: LiveRun) { run.task?.cancel() }

    /// Stop every in-flight research run (menu-bar "Stop all"). Each hands back its partial on return.
    func stopAll() { activeRuns.values.forEach { $0.task?.cancel() } }

    /// Discard the compose-time draft (planning or awaiting approval) — cancel its planner and clear it.
    func discardDraft() { draftRun?.task?.cancel(); draftRun = nil }

    /// The research+planner engine for this run: the real Claude Code subprocess, or — in a dev launch
    /// with dry run on — a canned stand-in that makes no real calls (it reports a *plausible* cost so the
    /// spend UI still exercises, but never bills). Both conform to the same seam.
    private func makeEngine(_ onActivity: @escaping @Sendable (LiveSnapshot) -> Void)
        -> any ResearchExecutor & AnglePlanner {
        if AppEnv.isDev && dryRun { return DryRunExecutor(onActivity: onActivity, model: .stored("agentModel")) }
        return ClaudeCodeExecutor(onActivity: onActivity, model: .stored("agentModel"))
    }

    // MARK: Fan-out — decompose one question, research N angles in parallel, synthesize

    /// Step 1: ask the planner for angles (cheap), into a fresh compose-time draft shown for review.
    func planDeepDive(_ question: String, count: Int) {
        guard let config = makeConfig() else { return }
        let pf = Preflight.check(ClaudeCLIProbe()); preflight = pf
        guard pf.ok || dryRun else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        discardDraft()
        let draft = LiveRun(id: UUID().uuidString, fanOut: FanOutState(question: q, count: count, phase: .planning))
        draftRun = draft

        let planner = makeEngine { [weak draft] snap in
            DispatchQueue.main.async { draft?.apply(snap) }
        }
        let store = self.store
        draft.task = Task { [weak self, weak draft] in
            let angles = (try? await planAngles(question: q, count: count, config: config,
                                                planner: planner, store: store, clock: SystemClock())) ?? []
            await MainActor.run {
                guard let self, let draft, self.draftRun === draft else { return }   // still the current draft
                if Task.isCancelled { self.draftRun = nil; return }
                draft.fanOut.angles = angles.map { AngleState(angle: $0) }
                draft.fanOut.phase = .awaitingApproval
            }
        }
    }

    /// Step 2: launch the approved draft as a concurrent research run — it moves into History (live
    /// status), gets focused, and Compose is freed for the next question.
    func startDeepDive() {
        guard let config = makeConfig(), let projectURL, let draft = draftRun,
              !draft.fanOut.angles.isEmpty else { return }
        var fo = draft.fanOut
        let approved = fo.angles.map(\.angle)
        fo.phase = .researching

        // Unique per-second run dir → stamp identity (bump a second if a live run already took this one).
        var startedAt = Date()
        guard var dir = try? store.makeRunDirectory(projectURL: projectURL, startedAt: startedAt) else { return }
        var stamp = RunFolder.stamp(dir.lastPathComponent)
        while activeRuns[stamp] != nil {
            startedAt = startedAt.addingTimeInterval(1)
            guard let d = try? store.makeRunDirectory(projectURL: projectURL, startedAt: startedAt) else { return }
            dir = d; stamp = RunFolder.stamp(d.lastPathComponent)
        }

        let run = LiveRun(id: stamp, fanOut: fo)
        activeRuns[stamp] = run
        draftRun = nil
        focusRun = stamp
        refreshRuns()   // the (empty, report-less) folder now appears in History; titling skips it until done

        let executor = makeEngine { [weak run] snap in
            DispatchQueue.main.async { run?.apply(snap) }
        }
        let store = self.store
        let question = fo.question
        run.task = Task { [weak self, weak run] in
            _ = await runIterativeFanOut(
                question: question, angles: approved, config: config, executor: executor,
                clock: SystemClock(), store: store, power: IOKitPowerManager(), notifier: UNNotifier(),
                runDir: dir,
                onPhase: { phase in Task { @MainActor in run?.setPhase(phase) } },
                onAngle: { id, status in Task { @MainActor in run?.setAngleStatus(id, status) } },
                onRound: { round, angles in Task { @MainActor in run?.startRound(round, angles: angles) } })
            await MainActor.run {
                guard let self else { return }
                self.activeRuns[stamp] = nil   // done → its History row now opens the on-disk digest
                self.refreshRuns()
                self.refreshNotes()   // a finished run wrote/extended a note — surface it in Mds
            }
        }
    }

    private func makeConfig() -> RunSettings? {
        guard let projectURL else { return nil }
        return RunSettings(
            projectURL: projectURL,
            runSpendCapUSD: runSpendCap,
            perTopicSpendCapUSD: perTopicSpendCap,
            perTopicTimeout: .seconds(perTopicTimeoutMinutes * 60),
            defaultPreset: defaultPreset,
            useProjectContext: useProjectContext,
            synthesisTemplate: synthesisTemplate)
    }

    // MARK: History

    func refreshRuns() {
        guard let projectURL else { runs = []; return }
        runs = store.listRuns(projectURL: projectURL)
        ensureTitles()
    }

    // MARK: Notes ("Mds")

    func refreshNotes() {
        guard let projectURL else { noteTree = []; return }
        noteTree = DiskFindingsStore.noteTree(under: projectURL)
    }

    /// A short title for a run in History (parsed from the folder name), or nil for a not-yet-titled
    /// run — the sidebar falls back to the date.
    func runTitle(for runDir: URL) -> String? { RunFolder.title(runDir.lastPathComponent) }

    /// Title any not-yet-titled runs (legacy bare-timestamp folders) with the cheapest model and rename
    /// each folder to `<title> <stamp>` — one tiny Haiku call at a time in the background (no process
    /// storm on first launch), then refresh. The folder name is the title's home, so it's a one-time
    /// per-run spend.
    private func ensureTitles() {
        // Skip still-running runs: their folder has no report.json yet, and renaming it would move the
        // dir out from under the in-flight run's writes.
        let untitled = runs.filter {
            RunFolder.title($0.lastPathComponent) == nil && !isRunning(RunFolder.stamp($0.lastPathComponent))
        }
        guard !untitled.isEmpty else { return }
        titlingTask?.cancel()
        titlingTask = Task { [weak self] in
            var renamedAny = false
            for run in untitled {
                if Task.isCancelled { return }
                if await RunTitler.titleAndRename(runDir: run) != nil { renamedAny = true }
            }
            if renamedAny { await MainActor.run { self?.refreshRuns() } }
        }
    }

    func loadReport(_ runDir: URL) -> RunReport? {
        guard let data = try? Data(contentsOf: runDir.appendingPathComponent("report.json")) else { return nil }
        return try? JSONDecoder().decode(RunReport.self, from: data)
    }

    // MARK: Persistence (per-project settings.json)

    // Extra keys in older files decode fine (JSONDecoder ignores them), so dropped queue fields are safe.
    private struct ProjectState: Codable {
        var runSpendCap: Decimal
        var perTopicSpendCap: Decimal
        var perTopicTimeoutMinutes: Int
        var defaultPreset: EffortPreset
        var useProjectContext: Bool?   // optional → old queue.json files still decode
        var synthesisTemplate: ResearchTemplate?   // optional → old queue.json files still decode
    }

    private var stateURL: URL? {
        projectURL?.appendingPathComponent("Quorum", isDirectory: true)
            .appendingPathComponent("queue.json")
    }

    func saveState() {
        guard let stateURL else { return }
        let state = ProjectState(runSpendCap: runSpendCap,
                                 perTopicSpendCap: perTopicSpendCap,
                                 perTopicTimeoutMinutes: perTopicTimeoutMinutes,
                                 defaultPreset: defaultPreset, useProjectContext: useProjectContext,
                                 synthesisTemplate: synthesisTemplate)
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL) }
    }

    private func loadState() {
        guard let stateURL, let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(ProjectState.self, from: data) else { return }
        runSpendCap = s.runSpendCap
        perTopicSpendCap = s.perTopicSpendCap
        perTopicTimeoutMinutes = s.perTopicTimeoutMinutes
        defaultPreset = s.defaultPreset
        useProjectContext = s.useProjectContext ?? false
        synthesisTemplate = s.synthesisTemplate ?? .general
    }
}

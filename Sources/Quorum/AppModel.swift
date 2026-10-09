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

    /// Engine model address for the subscription (`claude-code`) backend — the engine spawns the CLI on
    /// this alias. `.default` → the CLI's own default model.
    var engineAddress: String { modelID.map { "claude-code/\($0)" } ?? "claude-code" }

    /// Read the value `@AppStorage` wrote for `key` (it stores the rawValue string).
    static func stored(_ key: String) -> ModelChoice {
        ModelChoice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .default
    }
}

extension RunProfile {
    /// The selected run profile (compose picker → UserDefaults). Default: Subscription — today's behavior.
    static func stored() -> RunProfile {
        let picked = RunProfile(rawValue: UserDefaults.standard.string(forKey: "runProfile") ?? "") ?? .subscription
        return ExperimentalProfiles.effective(picked, experimentsEnabled: ExperimentalProfiles.isEnabled())
    }
}

enum RunState: Equatable { case idle, running, finished }

/// One angle in a fan-out run: the (editable-in-review) angle plus its live status for the viz.
struct AngleState: Identifiable {
    var angle: ResearchAngle
    var status: TopicStatus = .queued
    var round: Int = 1
    var id: String { angle.id }
}

/// The state of a fan-out ("explore every angle") run, driving the radial visualization.
struct FanOutState {
    var question: String
    var count: Int
    var title: String? = nil
    var phase: FanOutPhase
    var angles: [AngleState] = []   // the CURRENT round's angles
    // Iterative fan-out: the dive deepens round over round (round 2+ chases the synthesis's unresolved
    // conflicts + gaps). `round` is 1-based; `roundAngleCounts[i]` is how many angles round i+1 fanned out.
    var round: Int = 1
    var roundAngleCounts: [Int] = []
}

@MainActor
@Observable
final class LiveRun: Identifiable {
    let id: String
    var fanOut: FanOutState
    var planningLive = LiveSnapshot()               // the planner's decomposition, streamed live
    var liveByAngle: [String: LiveSnapshot] = [:]   // per-angle stream, keyed by angle id
    var graph = ResearchGraph()
    /// What the run has written and what it wrote it from, so the rail beside the canvas reads a running
    /// angle the way the reader reads a finished one — chips resolving, sources sealed.
    var evidence = RunEvidence()
    @ObservationIgnored var approvals: RunControlChannel?
    @ObservationIgnored var spawnDir: URL?
    /// What the run has left standing for a person, and whether they have been told about it. The pill
    /// reads it; the notification is fired from it exactly once per offer.
    var pendingApprovals = PendingApprovals()
    /// A node ⌘K asked to be shown. The canvas focuses it and clears this, so asking for the same node
    /// twice works the second time too.
    var revealedNode: String?
    var synthesisLive = LiveSnapshot()              // the summariser's stream
    var verifyLive = LiveSnapshot()                 // the citation-grounding re-check's stream
    @ObservationIgnored var task: Task<Void, Never>?

    init(id: String, fanOut: FanOutState, graph: ResearchGraph? = nil) {
        self.id = id
        self.fanOut = fanOut
        self.graph = graph ?? .planning(question: fanOut.question, angleCount: fanOut.count)
    }

    /// The run's new shape, and what about it is worth interrupting someone for. The wave carries on around
    /// an offer, so an offer raised while the app is elsewhere is only ever seen because it said so.
    func absorb(_ graph: ResearchGraph, appIsActive: Bool) -> PendingApprovalAlert? {
        self.graph = graph
        return pendingApprovals.observe(graph, appIsActive: appIsActive)
    }

    /// Route a streamed snapshot to the right slot (mirrors the executor's topicID convention).
    func apply(_ snap: LiveSnapshot) {
        withAnimation(.easeOut(duration: 0.25)) {
            if snap.topicID == "planning" { planningLive = snap }
            else if snap.topicID.hasPrefix("synthesis") { synthesisLive = snap }
            else if judgesTheAnswer(snap.topicID) { verifyLive = snap }
            else { liveByAngle[snap.topicID] = snap }
        }
    }

    /// The citation check and the validators read the answer; they research nothing. Their streams belong
    /// in the checking lane rather than among the angles, whose spend the run reports as research.
    private func judgesTheAnswer(_ topicID: String) -> Bool {
        topicID.hasPrefix("verify") || topicID.hasPrefix("claim_sweep") || topicID.hasPrefix("critic_")
    }

    func setPhase(_ phase: FanOutPhase) { fanOut.phase = phase }

    func setAngleStatus(_ id: String, _ status: TopicStatus) {
        guard let i = fanOut.angles.firstIndex(where: { $0.id == id }) else { return }
        fanOut.angles[i].status = status
    }

    /// A new iterative round is starting — tag this round's angles and add them onto the SAME fan (round 2+
    /// chases the prior synthesis's unresolved conflicts + gaps) so every round stays visible as its own
    /// band on one growing diagram. Round 1's `onRound` re-states the draft-approved angles it already
    /// holds, so replace this round's slice rather than append — else round 1 lands twice (same ids), which
    /// the id-keyed cards dedup away but the index-keyed connectors draw as stray lines.
    func startRound(_ round: Int, angles: [ResearchAngle]) {
        withAnimation(.easeOut(duration: 0.3)) {
            fanOut.round = round
            fanOut.angles.removeAll { $0.round == round }
            fanOut.angles += angles.map { AngleState(angle: $0, round: round) }
            if fanOut.roundAngleCounts.count < round { fanOut.roundAngleCounts.append(angles.count) }
            synthesisLive = LiveSnapshot()
            verifyLive = LiveSnapshot()
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // Project
    var projectURL: URL?
    var preflight: PreflightResult?
    var engine = QuorumEngine.resolve()
    var showsDoctor = false

    var engineRefusal: String? { Preflight.engineRefusal(engine) }

    var canRun: Bool {
        engine.path != nil && (preflight?.ok ?? true || AppEnv.replayFixture != nil)
    }

    func refreshEngine() {
        engine = QuorumEngine.resolve()
        preflight = Preflight.check(ClaudeCLIProbe())
    }

    // Guardrails (persisted per project) — spend caps ride the effort preset, no separate manual $ dial.
    var runSpendCap: Decimal { GuardrailMapper.spec(for: defaultPreset).runSpendCapUSD }
    var perTopicSpendCap: Decimal { GuardrailMapper.spec(for: defaultPreset).perTopicSpendCapUSD }
    var perTopicTimeoutMinutes = 20
    var defaultPreset: EffortPreset = .standard
    var useProjectContext = false   // let the parallel research agents read this project (read-only)
    var synthesisTemplate: ResearchTemplate = .general   // fan-out deliverable shape (item 8 — research templates)
    /// The validator loop's wall: how many times the engine may research its own objections and re-judge
    /// the redraft. A round past the first only happens if a blocking objection is standing.
    var rounds = 4

    var activeRuns: [String: LiveRun] = [:]
    var focusRun: String?          // one-shot: tells ContentView to select this stamp, then is cleared
    var focusNote: String?         // one-shot: a note asked for from a run's graph opens in the editor
    var quickSwitchOpen = false    // ⌘K global switcher over chats, notes, and commands

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
        activeRuns.values.forEach { $0.task?.cancel() }
        activeRuns = [:]; focusRun = nil
        projectURL = url
        rememberProject(url)
        loadState()
        refreshRuns()
        refreshNotes()
        refreshEngine()
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

    var overallRunState: RunState { activeRuns.isEmpty ? .idle : .running }

    var runSummary: String {
        if activeRuns.isEmpty { return "Idle" }
        if activeRuns.values.allSatisfy({ $0.fanOut.phase == .planning }) { return "Planning…" }
        return "\(activeRuns.count) researching"
    }

    /// Overall angle completion across all in-flight runs, 0–100, for the menu-bar readout. nil when
    /// nothing has fanned out yet (idle, or still planning) so the label shows just the icon.
    var progressPercent: Int? {
        let angles = activeRuns.values.flatMap { $0.fanOut.angles }
        guard !angles.isEmpty else { return nil }
        let done = angles.filter { $0.status != .queued && $0.status != .running }.count
        return done * 100 / angles.count
    }

    /// Stop one research run — hands back its partial and removes it on return.
    func stop(_ run: LiveRun) { run.task?.cancel() }

    /// Stop every in-flight research run (menu-bar "Stop all"). Each hands back its partial on return.
    func stopAll() { activeRuns.values.forEach { $0.task?.cancel() } }

    func effectiveProfile() -> RunProfile {
        let p = RunProfile.stored()
        guard p.needsEngineKeys || p.needsCodexCLI else { return p }
        let ok = p.availability(hasModelKey: EngineKeys.hasKeyForModel(EngineKeys.configuredAngleModel()),
                                hasSearchKey: EngineKeys.hasSearchKey(),
                                hasCodexCLI: CodexCLI.resolvePath() != nil).ok
        return ok ? p : .subscription
    }

    func startRun(_ question: String, count: Int) {
        guard let config = makeConfig(), let projectURL else { return }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let replay = AppEnv.replayFixture
        refreshEngine()
        guard let launch = EngineRunFanOut.Launch(engine), preflight?.ok == true || replay != nil else { return }

        let title = RunTitle.fromQuestion(question)
        var startedAt = Date()
        guard var dir = try? store.makeRunDirectory(projectURL: projectURL, startedAt: startedAt, title: title) else { return }
        var stamp = RunFolder.stamp(dir.lastPathComponent)
        while activeRuns[stamp] != nil {
            startedAt = startedAt.addingTimeInterval(1)
            guard let d = try? store.makeRunDirectory(projectURL: projectURL, startedAt: startedAt, title: title) else { return }
            dir = d; stamp = RunFolder.stamp(d.lastPathComponent)
        }

        var state = FanOutState(question: question, count: count, phase: .planning)
        state.title = title
        let run = LiveRun(id: stamp, fanOut: state)
        activeRuns[stamp] = run
        focusRun = stamp
        refreshRuns()

        let store = self.store
        let profile = effectiveProfile()
        let handshake = engine.handshake
        let rounds = self.rounds
        let models = engineModels(for: profile)
        let onPhase: @Sendable (FanOutPhase) -> Void = { [weak run] phase in Task { @MainActor in run?.setPhase(phase) } }
        let onAngle: @Sendable (String, TopicStatus) -> Void = { [weak run] id, s in Task { @MainActor in run?.setAngleStatus(id, s) } }
        let onRound: @Sendable (Int, [ResearchAngle]) -> Void = { [weak run] r, a in Task { @MainActor in run?.startRound(r, angles: a) } }
        let onActivity: @Sendable (LiveSnapshot) -> Void = { [weak run] snap in DispatchQueue.main.async { run?.apply(snap) } }
        let onGraph: @Sendable (ResearchGraph) -> Void = { [weak run] graph in
            DispatchQueue.main.async {
                guard let alert = run?.absorb(graph, appIsActive: NSApp.isActive) else { return }
                UNNotifier().notifyPendingApproval(alert)
            }
        }
        let onEvidence: @Sendable (RunEvidence) -> Void = { [weak run] evidence in
            DispatchQueue.main.async { run?.evidence = evidence }
        }
        let onApprovals: @Sendable (RunControlChannel) -> Void = { [weak run] channel in
            DispatchQueue.main.async { run?.approvals = channel }
        }
        run.spawnDir = dir.appendingPathComponent("evidence", isDirectory: true)

        run.task = Task { [weak self] in
            let power = IOKitPowerManager()
            power.preventSleep(reason: "Quorum research run")
            defer { power.allowSleep() }
            let priorNotes = store.relatedNotes(to: question, in: config.projectURL)
            let spec = GuardrailMapper.spec(for: config.defaultPreset)
            let engineConfig = EngineRunFanOut.Config(
                question: question, angleCount: count,
                angleModel: models.angle, synthesisModel: models.synthesis,
                validatorModel: models.validator,
                effort: spec.effort.rawValue,
                perTopicBudgetUSD: (config.perTopicSpendCapUSD as NSDecimalNumber).doubleValue,
                runBudgetUSD: (config.runSpendCapUSD as NSDecimalNumber).doubleValue,
                perTopicTimeoutSec: Int(config.perTopicTimeout.seconds),
                maxTurns: spec.maxTurns,
                priorNotesExcerpt: PriorNotes.excerpt(priorNotes),
                template: (config.synthesisTemplate ?? .general).rawValue,
                rounds: rounds,
                useProjectContext: config.useProjectContext, projectDir: config.projectURL.path)
            _ = await EngineRunFanOut.run(
                launch: launch, keys: replay == nil ? EngineKeys.environment() : [:],
                engineConfig: engineConfig, run: config, priorNotes: priorNotes, store: store, runDir: dir,
                clock: SystemClock(), notifier: UNNotifier(),
                onPhase: onPhase, onAngle: onAngle, onRound: onRound, onActivity: onActivity,
                onGraph: onGraph, onEvidence: onEvidence, onApprovals: onApprovals,
                seedGraph: run.graph, engine: handshake, replaying: replay)
            await MainActor.run {
                guard let self else { return }
                self.activeRuns[stamp] = nil
                self.refreshRuns()
                self.refreshNotes()
            }
        }
    }

    /// Everything the canvas can say to a run in flight, down the one channel that says it: the verdict
    /// reaches the engine and the card answers in the same frame, rather than after a round trip nobody
    /// asked to watch.
    func steer(run: LiveRun, _ control: RunControl) {
        run.approvals?.send(control)
        withAnimation(.easeOut(duration: 0.3)) { run.graph.steer(control) }
        run.pendingApprovals.observe(run.graph, appIsActive: true)
    }

    /// A verdict given on the canvas, sent back down the engine's stdin. Nothing runs until this arrives,
    /// and if it never does the spawn expires at the freeze rather than holding the run open.
    func ruleOnSpawn(run: LiveRun, id: String, approved: Bool) {
        steer(run: run, approved ? .approve(id: id) : .reject(id: id))
    }

    /// A branch dropped off the canvas. What that withdraws is every offer standing under it, one line
    /// each, because the engine rules on one offer at a time and knows nothing of branches.
    func pruneBranch(run: LiveRun, from id: String) {
        for offer in run.graph.pendingOffers(under: id) { steer(run: run, .prune(id: offer.id)) }
    }

    /// Six offers is six clicks, which is why they went unanswered. One verdict rules on every offer the
    /// run has standing — each still travels as its own line, because the engine knows nothing of "all".
    func ruleOnEveryPendingSpawn(run: LiveRun, approved: Bool) {
        for id in run.pendingApprovals.ids { ruleOnSpawn(run: run, id: id, approved: approved) }
    }

    /// How many offers are standing across every run at once — the menu bar's number, for the person who
    /// is not looking at any of them.
    var pendingApprovalCount: Int {
        activeRuns.values.reduce(0) { $0 + $1.pendingApprovals.count }
    }

    /// Digging down from a node: the user's own spawn. It needs no approval — they are the approval — but
    /// it goes through the same gates, so depth, dedup and the count cap still hold. Filed on the same
    /// on-disk queue a Claude Code angle uses, so there is one admission path rather than two.
    func digDown(run: LiveRun, from node: GraphNode, question: String) {
        guard let dir = run.spawnDir, !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let request: [String: String] = [
            "request_id": UUID().uuidString,
            "angle_id": node.id,
            "question": question,
            "why": "asked from the canvas",
            "provoked_by": node.provokedBy ?? node.id,
            "origin": "dig",
        ]
        guard let line = try? JSONSerialization.data(withJSONObject: request) else { return }
        let path = dir.appendingPathComponent("spawn-requests.jsonl")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: path) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line + Data("\n".utf8))
        } else {
            try? (line + Data("\n".utf8)).write(to: path)
        }
    }

    /// Per-role engine model addresses for a profile (fan-out in TS). Subscription runs both roles on the
    /// `claude-code` backend (the CLI, no key); Budget puts cheap BYOK on the angles and the subscription
    /// on synthesis; Full BYOK is BYOK end to end. The validator is routed apart from both — cheap, and
    /// away from the family that wrote the answer — falling back to the keyless CLI judge when the
    /// cross-family one has no key to run on.
    private func engineModels(for profile: RunProfile) -> (angle: String, synthesis: String, validator: String) {
        let agent = ModelChoice.stored("agentModel")
        let agentEff: ModelChoice = agent == .default ? .sonnet : agent
        let synth = ModelChoice.stored("synthesisModel")
        let synthEff: ModelChoice = synth == .default ? .opus : synth
        let roles: (angle: String, synthesis: String) = {
            switch profile {
            case .subscription, .benchmark: return (agentEff.engineAddress, synthEff.engineAddress)
            case .budget:                   return (EngineKeys.configuredAngleModel(), synthEff.engineAddress)
            case .fullBYOK:                 return (EngineKeys.configuredAngleModel(), EngineKeys.configuredSynthesisModel())
            case .codex:                    return (EngineKeys.configuredCodexAngleModel().engineAddress,
                                                    EngineKeys.configuredCodexSynthesisModel().engineAddress)
            }
        }()
        let judge = profile.validator(judging: roles.synthesis)
        let validator = EngineKeys.hasKeyForModel(judge.model) ? judge.model
                                                              : RunProfile.subscriptionValidatorModel
        return (roles.angle, roles.synthesis, validator)
    }

    /// The run's wall clock: its rounds are sequential and each is bounded by the per-agent time wall, so
    /// that product is how long a run may honestly take. The engine measures its spawn freeze against it —
    /// with no deadline the freeze can never fire and a run digs until the money runs out.
    private func makeConfig() -> RunSettings? {
        guard let projectURL else { return nil }
        let perTopicTimeout = Duration.seconds(perTopicTimeoutMinutes * 60)
        return RunSettings(
            projectURL: projectURL,
            runSpendCapUSD: runSpendCap,
            perTopicSpendCapUSD: perTopicSpendCap,
            perTopicTimeout: perTopicTimeout,
            runDeadline: Date().addingTimeInterval(Double(perTopicTimeoutMinutes * 60 * max(1, rounds))),
            defaultPreset: defaultPreset,
            useProjectContext: useProjectContext,
            synthesisTemplate: synthesisTemplate,
            profile: effectiveProfile())
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

    /// Re-run the cheap titler for an existing run and rename its folder in place. Used from the chat
    /// row dropdown so a user can ask for a fresh title without touching the run contents.
    func regenerateRunTitle(_ runDir: URL) async {
        let stamp = RunFolder.stamp(runDir.lastPathComponent)
        guard !isRunning(stamp) else { return }
        let existingTitle = RunFolder.title(runDir.lastPathComponent)
        if await RunTitler.titleAndRename(runDir: runDir, avoiding: existingTitle) != nil {
            refreshRuns()
        }
    }

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
        var perTopicTimeoutMinutes: Int
        var defaultPreset: EffortPreset
        var useProjectContext: Bool?   // optional → old queue.json files still decode
        var synthesisTemplate: ResearchTemplate?   // optional → old queue.json files still decode
        var rounds: Int?   // optional → old queue.json files still decode
    }

    private var stateURL: URL? {
        projectURL?.appendingPathComponent("Quorum", isDirectory: true)
            .appendingPathComponent("queue.json")
    }

    func saveState() {
        guard let stateURL else { return }
        let state = ProjectState(perTopicTimeoutMinutes: perTopicTimeoutMinutes,
                                 defaultPreset: defaultPreset, useProjectContext: useProjectContext,
                                 synthesisTemplate: synthesisTemplate, rounds: rounds)
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL) }
    }

    private func loadState() {
        guard let stateURL, let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(ProjectState.self, from: data) else { return }
        perTopicTimeoutMinutes = s.perTopicTimeoutMinutes
        defaultPreset = s.defaultPreset
        useProjectContext = s.useProjectContext ?? false
        synthesisTemplate = s.synthesisTemplate ?? .general
        rounds = s.rounds ?? 4
    }
}

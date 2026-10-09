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
    var runID: String?
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
    var brainURL = BrainFolder.location(stored: UserDefaults.standard.string(forKey: BrainFolder.defaultsKey))
    var preflight: PreflightResult?
    var engine = QuorumEngine.resolve()
    var showsDoctor = false
    var lastRunRefusal: RunStreamParser.Refusal?

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
    var finishedLiveRuns: [String: String] = [:]
    var focusRun: String?
    var focusNote: String?         // one-shot: a note asked for from a run's graph opens in the editor
    var quickSwitchOpen = false    // ⌘K global switcher over chats, notes, and commands

    var runs: [StoredRun] = []
    var noteTree: [NoteTreeNode] = []

    var brainName: String { brainURL.lastPathComponent }

    var answersURL: URL { brainURL.appendingPathComponent("answers", isDirectory: true) }

    func start() {
        loadState()
        refreshRuns()
        refreshNotes()
        refreshEngine()
    }

    func chooseBrainFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = brainURL
        panel.prompt = "Use as Brain Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setBrainFolder(url)
    }

    func setBrainFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: BrainFolder.defaultsKey)
        brainURL = url
        refreshRuns()
        refreshNotes()
    }

    private let defaults = UserDefaults.standard

    // MARK: Running

    func isRunning(_ key: String) -> Bool { liveRun(for: key) != nil }

    func liveRun(for key: String) -> LiveRun? {
        activeRuns[key] ?? activeRuns.values.first { $0.runID == key }
    }

    func storedRun(for key: String) -> StoredRun? {
        let id = finishedLiveRuns[key] ?? key
        return runs.first { $0.id == id }
    }

    var unlistedLiveRuns: [LiveRun] {
        activeRuns.values
            .filter { live in !runs.contains { $0.id == live.runID } }
            .sorted { $0.id < $1.id }
    }

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
        guard let config = makeConfig() else { return }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let replay = AppEnv.replayFixture
        refreshEngine()
        guard let launch = EngineRunFanOut.Launch(engine), preflight?.ok == true || replay != nil else { return }

        let key = UUID().uuidString
        var state = FanOutState(question: question, count: count, phase: .planning)
        state.title = question
        let run = LiveRun(id: key, fanOut: state)
        activeRuns[key] = run
        focusRun = key

        let profile = effectiveProfile()
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
        let onRefusal: @Sendable (RunStreamParser.Refusal) -> Void = { [weak self] refusal in
            Task { @MainActor in
                self?.lastRunRefusal = refusal
                self?.showsDoctor = true
            }
        }
        let onApprovals: @Sendable (RunControlChannel) -> Void = { [weak run] channel in
            DispatchQueue.main.async { run?.approvals = channel }
        }
        let onRecord: @Sendable (RunStreamParser.RecordLocation) -> Void = { [weak self, weak run] location in
            Task { @MainActor in
                run?.runID = location.runID
                run?.spawnDir = location.runDir.appendingPathComponent("evidence", isDirectory: true)
                self?.refreshRuns()
            }
        }

        run.task = Task { [weak self] in
            let power = IOKitPowerManager()
            power.preventSleep(reason: "Quorum research run")
            defer { power.allowSleep() }
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
                template: (config.synthesisTemplate ?? .general).rawValue,
                rounds: rounds,
                useProjectContext: config.useProjectContext, projectDir: config.brainURL.path,
                brainDir: config.brainURL.path)
            let stored = await EngineRunFanOut.run(
                launch: launch, keys: replay == nil ? EngineKeys.environment() : [:],
                engineConfig: engineConfig, run: config,
                clock: SystemClock(), notifier: UNNotifier(),
                onPhase: onPhase, onAngle: onAngle, onRound: onRound, onActivity: onActivity,
                onRecord: onRecord, onGraph: onGraph, onEvidence: onEvidence, onApprovals: onApprovals,
                onRefusal: onRefusal, seedGraph: run.graph, replaying: replay)
            await MainActor.run {
                guard let self else { return }
                if let id = stored?.id ?? run.runID { self.finishedLiveRuns[key] = id }
                self.activeRuns[key] = nil
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
        let perTopicTimeout = Duration.seconds(perTopicTimeoutMinutes * 60)
        return RunSettings(
            brainURL: brainURL,
            runSpendCapUSD: runSpendCap,
            perTopicSpendCapUSD: perTopicSpendCap,
            perTopicTimeout: perTopicTimeout,
            runDeadline: Date().addingTimeInterval(Double(perTopicTimeoutMinutes * 60 * max(1, rounds))),
            defaultPreset: defaultPreset,
            useProjectContext: useProjectContext,
            synthesisTemplate: synthesisTemplate,
            profile: effectiveProfile())
    }

    func refreshRuns() {
        runs = BrainFolder.runs(in: brainURL)
    }

    func refreshNotes() {
        noteTree = NotesFolder.noteTree(under: answersURL)
    }

    private enum SettingsKey {
        static let timeout = "perTopicTimeoutMinutes"
        static let preset = "defaultPreset"
        static let projectContext = "useProjectContext"
        static let template = "synthesisTemplate"
        static let rounds = "rounds"
    }

    func saveState() {
        defaults.set(perTopicTimeoutMinutes, forKey: SettingsKey.timeout)
        defaults.set(defaultPreset.rawValue, forKey: SettingsKey.preset)
        defaults.set(useProjectContext, forKey: SettingsKey.projectContext)
        defaults.set(synthesisTemplate.rawValue, forKey: SettingsKey.template)
        defaults.set(rounds, forKey: SettingsKey.rounds)
    }

    private func loadState() {
        if defaults.object(forKey: SettingsKey.timeout) != nil { perTopicTimeoutMinutes = defaults.integer(forKey: SettingsKey.timeout) }
        defaultPreset = EffortPreset(rawValue: defaults.string(forKey: SettingsKey.preset) ?? "") ?? .standard
        useProjectContext = defaults.bool(forKey: SettingsKey.projectContext)
        synthesisTemplate = ResearchTemplate(rawValue: defaults.string(forKey: SettingsKey.template) ?? "") ?? .general
        if defaults.object(forKey: SettingsKey.rounds) != nil { rounds = defaults.integer(forKey: SettingsKey.rounds) }
    }
}

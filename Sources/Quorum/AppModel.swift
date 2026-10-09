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

struct RecordedLiveRun: Equatable {
    let key: String
    let runID: String
}

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
    var runID: String?
    var progress: RunProgress?
    @ObservationIgnored var cancelRequested = false
    @ObservationIgnored var evidenceDir: URL?
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
    var engineChecks: [EngineDoctorCheck] = []
    var lastRunRefusal: RunStreamParser.Refusal?

    var engineRefusal: String? { Preflight.engineRefusal(engine) }

    var canRun: Bool {
        engine.path != nil && (preflight?.ok ?? true || AppEnv.replayFixture != nil)
    }

    func refreshEngine() {
        engine = QuorumEngine.resolve()
        preflight = Preflight.check(ClaudeCLIProbe())
        refreshEngineChecks()
    }

    private func refreshEngineChecks() {
        guard let launch = EngineLaunch(engine) else {
            engineChecks = []
            return
        }
        let store = brainURL
        Task { [weak self] in
            let checks = await EngineRunClient.doctor(launch: launch, store: store)
            self?.engineChecks = checks
        }
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
    var recordedLiveRun: RecordedLiveRun?
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
        reattachRunning()
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

    func stop(_ run: LiveRun) {
        guard let launch = EngineLaunch(engine) else { return }
        guard let runID = run.runID else {
            run.cancelRequested = true
            return
        }
        let store = brainURL
        Task { _ = await EngineRunClient.cancel(launch: launch, runID: runID, store: store) }
    }

    func stopAll() { activeRuns.values.forEach(stop) }

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
        guard let launch = EngineLaunch(engine), preflight?.ok == true || replay != nil else { return }

        let key = UUID().uuidString
        var state = FanOutState(question: question, count: count, phase: .planning)
        state.title = question
        let run = LiveRun(id: key, fanOut: state)
        activeRuns[key] = run
        focusRun = key

        let profile = effectiveProfile()
        let rounds = self.rounds
        let models = engineModels(for: profile)
        let spec = GuardrailMapper.spec(for: config.defaultPreset)
        let engineConfig = EngineRunClient.Config(
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
        let keys = replay == nil ? EngineKeys.environment() : [:]
        let store = config.brainURL
        let deadline = config.runDeadline

        run.task = Task { [weak self, weak run] in
            guard let self, let run else { return }
            let started = await EngineRunClient.start(launch: launch, keys: keys, config: engineConfig,
                                                      deadline: deadline, store: store, replaying: replay)
            switch started {
            case .failure(let failure):
                self.lastRunRefusal = RunStreamParser.Refusal(kind: "engine_failed", reason: failure.reason)
                self.showsDoctor = true
                self.activeRuns[key] = nil
            case .success(let created):
                self.noteRecord(of: created, for: run, key: key)
                if run.cancelRequested { _ = await EngineRunClient.cancel(launch: launch, runID: created.runID, store: store) }
                await self.follow(run, key: key, launch: launch, runDir: created.runDir, store: store)
            }
        }
    }

    func reattachRunning() {
        guard let launch = EngineLaunch(engine) else { return }
        let store = brainURL
        Task { [weak self] in
            let entries = await EngineRunClient.list(launch: launch, store: store)
            guard let self else { return }
            self.refreshRuns()
            for entry in EngineReply.toReattach(entries, watching: self.watchedRunIDs) { self.attach(entry, launch: launch, store: store) }
        }
    }

    private var watchedRunIDs: Set<String> { Set(activeRuns.values.compactMap(\.runID)) }

    private func attach(_ entry: RunIndexEntry, launch: EngineLaunch, store: URL) {
        var state = FanOutState(question: entry.title, count: 0, phase: .planning)
        state.title = entry.title
        let run = LiveRun(id: entry.runID, fanOut: state, graph: ResearchGraph())
        run.runID = entry.runID
        run.evidenceDir = entry.runDir.appendingPathComponent("evidence", isDirectory: true)
        activeRuns[entry.runID] = run
        recordedLiveRun = RecordedLiveRun(key: entry.runID, runID: entry.runID)
        run.task = Task { [weak self, weak run] in
            guard let self, let run else { return }
            await self.follow(run, key: entry.runID, launch: launch, runDir: entry.runDir, store: store)
        }
    }

    private func noteRecord(of created: RunCreated, for run: LiveRun, key: String) {
        run.runID = created.runID
        run.evidenceDir = created.runDir.appendingPathComponent("evidence", isDirectory: true)
        refreshRuns()
        recordedLiveRun = RecordedLiveRun(key: key, runID: created.runID)
    }

    private func follow(_ run: LiveRun, key: String, launch: EngineLaunch, runDir: URL, store: URL) async {
        let callbacks = EngineRunClient.Callbacks(
            onPhase: { [weak run] phase in Task { @MainActor in run?.setPhase(phase) } },
            onAngle: { [weak run] id, status in Task { @MainActor in run?.setAngleStatus(id, status) } },
            onRound: { [weak run] round, angles in Task { @MainActor in run?.startRound(round, angles: angles) } },
            onActivity: { [weak run] snapshot in DispatchQueue.main.async { run?.apply(snapshot) } },
            onProgress: { [weak run] progress in DispatchQueue.main.async { run?.progress = progress } },
            onRecord: { _ in },
            onGraph: { [weak run] graph in DispatchQueue.main.async { run?.graph = graph } },
            onEvidence: { [weak run] evidence in DispatchQueue.main.async { run?.evidence = evidence } },
            onRefusal: { [weak self] refusal in
                Task { @MainActor in
                    self?.lastRunRefusal = refusal
                    self?.showsDoctor = true
                }
            })
        let stored = await EngineRunClient.watch(runDir: runDir, launch: launch, store: store, clock: SystemClock(),
                                                 notifier: UNNotifier(), callbacks: callbacks, seedGraph: run.graph)
        guard !Task.isCancelled else { return }
        if let id = stored?.id ?? run.runID { finishedLiveRuns[key] = id }
        activeRuns[key] = nil
        refreshRuns()
        refreshNotes()
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

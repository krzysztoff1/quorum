import Foundation
import SwiftUI
import AppKit
import QuorumCore

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

    var useProjectContext = false   // let the parallel research agents read this project (read-only)

    var activeRuns: [String: LiveRun] = [:]
    var finishedLiveRuns: [String: String] = [:]
    var recordedLiveRun: RecordedLiveRun?
    var focusRun: String?
    var focusNote: String?         // one-shot: a note asked for from a run's graph opens in the editor
    var quickSwitchOpen = false

    var runs: [StoredRun] = []
    var unreadableRuns: [UnreadableRun] = []
    private var upgradeAttempted: Set<String> = []
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

    static func angleCount(for tier: Tier) -> Int { tier == .quick ? 3 : 4 }

    static func tierBlurb(_ tier: Tier) -> String {
        "\(angleCount(for: tier)) angles, researched in parallel"
    }

    func scope(_ request: ScopeRequest) async -> Result<ScopeReply, EngineFailure> {
        refreshEngine()
        guard let launch = EngineLaunch(engine) else { return .failure(EngineFailure(reason: "quorum-engine was not found")) }
        return await EngineRunClient.scope(launch: launch, request: request)
    }

    func startRun(_ start: RunStart) -> Bool {
        let question = start.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return false }
        let count = Self.angleCount(for: start.tier)
        let replay = AppEnv.replayFixture
        refreshEngine()
        guard let launch = EngineLaunch(engine), preflight?.ok == true || replay != nil else { return false }

        let key = UUID().uuidString
        var state = FanOutState(question: question, count: count, phase: .planning)
        state.title = start.brief?.title
        let run = LiveRun(id: key, fanOut: state)
        activeRuns[key] = run
        focusRun = key

        let engineConfig = EngineRunClient.Config(
            question: question, tier: start.tier.rawValue,
            useProjectContext: useProjectContext, projectDir: brainURL.path, brainDir: brainURL.path,
            brief: start.brief, clarifications: start.clarifications.isEmpty ? nil : start.clarifications)
        let keys = replay == nil ? EngineKeys.environment() : [:]
        let store = brainURL

        run.task = Task { [weak self, weak run] in
            guard let self, let run else { return }
            let started = await EngineRunClient.start(launch: launch, keys: keys, config: engineConfig,
                                                      store: store, replaying: replay)
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
        return true
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
        if let title = StoredRun.load(created.runDir)?.title { run.fanOut.title = title }
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

    func refreshRuns() {
        let inventory = BrainFolder.inventory(in: brainURL)
        runs = inventory.runs
        unreadableRuns = inventory.unreadable
        upgradeWaitingRuns(inventory.unreadable)
    }

    private func upgradeWaitingRuns(_ unreadable: [UnreadableRun]) {
        let waiting = Set(unreadable.filter { if case .needsUpgrade = $0.reason { true } else { false } }.map(\.id))
        guard !waiting.subtracting(upgradeAttempted).isEmpty, let launch = EngineLaunch(engine) else { return }
        upgradeAttempted.formUnion(waiting)
        let store = brainURL
        Task { [weak self] in
            _ = await EngineRunClient.migrate(launch: launch, store: store)
            self?.refreshRuns()
        }
    }

    func refreshNotes() {
        noteTree = NotesFolder.noteTree(under: answersURL)
    }

    private enum SettingsKey {
        static let projectContext = "useProjectContext"
    }

    func saveState() {
        defaults.set(useProjectContext, forKey: SettingsKey.projectContext)
    }

    private func loadState() {
        useProjectContext = defaults.bool(forKey: SettingsKey.projectContext)
    }
}

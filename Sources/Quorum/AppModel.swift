import Foundation
import SwiftUI
import AppKit
import QuorumCore

enum Selection: Hashable {
    case new
    case question(String)
}

struct PendingStart: Equatable {
    let question: String
    let tier: Tier
}

@MainActor
@Observable
final class LiveRun: Identifiable {
    let id: String
    let startedAt = Date()
    var planningLive = LiveSnapshot()
    var liveByAngle: [String: LiveSnapshot] = [:]
    var synthesisLive = LiveSnapshot()
    var verifyLive = LiveSnapshot()
    var graph = ResearchGraph()
    var evidence = RunEvidence()
    var progress: RunProgress?
    var revealedNode: String?
    @ObservationIgnored var evidenceDir: URL?
    @ObservationIgnored var task: Task<Void, Never>?

    init(id: String, graph: ResearchGraph? = nil) {
        self.id = id
        self.graph = graph ?? ResearchGraph()
    }

    func apply(_ snap: LiveSnapshot) {
        if snap.topicID == "planning" { planningLive = snap }
        else if snap.topicID.hasPrefix("synthesis") { synthesisLive = snap }
        else if judgesTheAnswer(snap.topicID) { verifyLive = snap }
        else { liveByAngle[snap.topicID] = snap }
    }

    private func judgesTheAnswer(_ topicID: String) -> Bool {
        topicID.hasPrefix("verify") || topicID.hasPrefix("claim_sweep") || topicID.hasPrefix("critic_")
    }
}

@MainActor
@Observable
final class AppModel {
    var brainURL = BrainFolder.location(stored: AppShot.current.brain ?? UserDefaults.standard.string(forKey: BrainFolder.defaultsKey))
    var preflight: PreflightResult?
    var engine = QuorumEngine.resolve()
    var engineChecks: [EngineDoctorCheck] = []
    var capabilities = EngineCapabilities.none
    var showsDoctor = false
    var lastRunRefusal: RunStreamParser.Refusal?

    var runs: [StoredRun] = []
    var unreadableRuns: [UnreadableRun] = []
    var threads: [QuestionThread] = []
    var ui = UIState()
    var progress: [String: RunProgress] = [:]
    var liveRuns: [String: LiveRun] = [:]
    var pendingStart: PendingStart?
    var selection: Selection = .new
    var paletteOpen = false
    var sidebarVisible = true
    var showsWork = false
    var followUpFocus = 0
    var composerSeed: String?
    var showsEarlier = false
    var viewing: [String: String] = [:]
    var pendingCite: String?
    var paletteSeed: String?
    var railOpen = false
    static let notifyKey = "notifyOnFinish"
    var notifyOnFinish = UserDefaults.standard.object(forKey: AppModel.notifyKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnFinish, forKey: AppModel.notifyKey) }
    }
    @ObservationIgnored var reading: AnswerFocus?
    let composer = ComposerModel()
    private var upgradeAttempted: Set<String> = []

    init() { composer.app = self }

    var engineRefusal: String? { Preflight.engineRefusal(engine) }

    var canRun: Bool {
        engine.path != nil && (preflight?.ok ?? true || AppEnv.replayFixture != nil)
    }

    var brainName: String { brainURL.lastPathComponent }

    var sections: [InboxSection] {
        Inbox.sections(threads: threads, progress: progress, ui: ui, now: Date(), calendar: .current)
    }

    var order: [String] { Inbox.order(sections) }

    var menuSummary: String { Inbox.menuSummary(running: threads.filter(\.isRunning).count, unread: unreadCount) }

    var unreadCount: Int { sections.flatMap(\.rows).filter(\.unread).count }

    var anyRunning: Bool { threads.contains { $0.isRunning } }

    var selectedThread: QuestionThread? {
        guard case .question(let id) = selection else { return nil }
        return threads.first { $0.id == id }
    }

    func thread(_ id: String) -> QuestionThread? { threads.first { $0.id == id } }

    func viewingRunID(_ thread: QuestionThread) -> String? { page(for: thread).viewingOverride(viewing[thread.id]) }

    func viewedAnswer(of thread: QuestionThread) -> StoredRun? { page(for: thread).viewed(override: viewing[thread.id]) }

    func page(for thread: QuestionThread) -> ThreadPage {
        ThreadPage(thread: thread, capabilities: capabilities)
    }

    func start() {
        refreshRuns()
        refreshEngine()
        reattachRunning()
    }

    func refreshEngine() {
        engine = QuorumEngine.resolve()
        preflight = Preflight.check(ClaudeCLIProbe())
        refreshEngineChecks()
    }

    private func refreshEngineChecks() {
        guard let launch = EngineLaunch(engine) else {
            engineChecks = []
            capabilities = AppEnv.assumesThreads ? EngineCapabilities(checks: [EngineDoctorCheck(id: "threads", ok: true, detail: "", fix: nil)]) : .none
            return
        }
        let store = brainURL
        Task { [weak self] in
            let checks = await EngineRunClient.doctor(launch: launch, store: store)
            guard let self else { return }
            self.engineChecks = checks
            let assumed = AppEnv.assumesThreads ? [EngineDoctorCheck(id: "threads", ok: true, detail: "", fix: nil)] : []
            self.capabilities = EngineCapabilities(checks: checks + assumed)
        }
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
        selection = .new
        refreshRuns()
    }

    func refreshRuns() {
        let inventory = BrainFolder.inventory(in: brainURL)
        runs = inventory.runs
        unreadableRuns = inventory.unreadable
        threads = ThreadIndex.build(runs: runs)
        ui = UIState.loadOrSeed(in: brainURL, threads: threads)
        upgradeWaitingRuns(inventory.unreadable)
        keepSelectedRead()
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

    func select(_ selection: Selection) {
        self.selection = selection
        showsWork = false
        keepSelectedRead()
    }

    func select(question id: String) { select(.question(id)) }

    func selectNext(by delta: Int) {
        guard let next = Inbox.step(from: selectedThread?.id, by: delta, in: order) else { return }
        select(question: next)
    }

    func selectNth(_ position: Int) {
        if let id = Inbox.nth(position, in: order) { select(question: id) }
    }

    private func keepSelectedRead() {
        guard let thread = selectedThread, let finish = thread.latestFinish else { return }
        guard ui.isUnread(question: thread.id, latestFinish: finish) else { return }
        ui.markRead(question: thread.id, at: finish)
        try? ui.save(in: brainURL)
    }

    func isRunning(_ runID: String) -> Bool { liveRuns[runID] != nil }

    func startRun(_ start: RunStart) -> Bool {
        let question = start.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return false }
        let replay = AppEnv.replayFixture
        refreshEngine()
        guard let launch = EngineLaunch(engine), preflight?.ok == true || replay != nil else { return false }

        let plan = TierPlan.plan(for: start.tier)
        let config = EngineRunConfig(start: start, brainDir: brainURL, deadlineSeconds: plan.deadlineSeconds)
        let keys = replay == nil ? EngineKeys.environment() : [:]
        let store = brainURL
        pendingStart = PendingStart(question: question, tier: start.tier)

        Task { [weak self] in
            let started = await EngineRunClient.start(launch: launch, keys: keys, config: config, store: store, replaying: replay)
            guard let self else { return }
            self.pendingStart = nil
            switch started {
            case .failure(let failure):
                self.composer.starting = false
                self.lastRunRefusal = RunStreamParser.Refusal(kind: "engine_failed", reason: failure.reason)
                self.showsDoctor = true
            case .success(let created):
                self.attach(created: created, launch: launch, store: store)
            }
        }
        return true
    }

    private func attach(created: RunCreated, launch: EngineLaunch, store: URL) {
        let run = LiveRun(id: created.runID)
        run.evidenceDir = created.runDir.appendingPathComponent("evidence", isDirectory: true)
        liveRuns[created.runID] = run
        refreshRuns()
        select(question: created.questionID)
        composer.reset()
        follow(run, runDir: created.runDir, launch: launch, store: store)
    }

    func reattachRunning() {
        guard let launch = EngineLaunch(engine) else { return }
        let store = brainURL
        Task { [weak self] in
            let entries = await EngineRunClient.list(launch: launch, store: store)
            guard let self else { return }
            self.refreshRuns()
            for entry in EngineReply.toReattach(entries, watching: Set(self.liveRuns.keys)) {
                let run = LiveRun(id: entry.runID, graph: ResearchGraph())
                run.evidenceDir = entry.runDir.appendingPathComponent("evidence", isDirectory: true)
                self.liveRuns[entry.runID] = run
                self.follow(run, runDir: entry.runDir, launch: launch, store: store)
            }
        }
    }

    private func follow(_ run: LiveRun, runDir: URL, launch: EngineLaunch, store: URL) {
        let id = run.id
        let callbacks = EngineRunClient.Callbacks(
            onActivity: { [weak run] snapshot in DispatchQueue.main.async { run?.apply(snapshot) } },
            onProgress: { [weak self, weak run] progress in
                DispatchQueue.main.async {
                    run?.progress = progress
                    self?.progress[id] = progress
                }
            },
            onGraph: { [weak run] graph in DispatchQueue.main.async { run?.graph = graph } },
            onEvidence: { [weak run] evidence in DispatchQueue.main.async { run?.evidence = evidence } },
            onRefusal: { [weak self] refusal in
                Task { @MainActor in
                    self?.lastRunRefusal = refusal
                    self?.showsDoctor = true
                }
            })
        run.task = Task { [weak self, weak run] in
            _ = run
            _ = await EngineRunClient.watch(runDir: runDir, launch: launch, store: store, clock: SystemClock(),
                                            notifier: GatedNotifier(enabled: { UserDefaults.standard.object(forKey: AppModel.notifyKey) as? Bool ?? true }), callbacks: callbacks, seedGraph: run?.graph ?? ResearchGraph())
            guard !Task.isCancelled, let self else { return }
            self.liveRuns[id] = nil
            self.progress[id] = nil
            self.refreshRuns()
        }
    }

    func stop(runID: String) {
        guard let launch = EngineLaunch(engine) else { return }
        let store = brainURL
        Task { _ = await EngineRunClient.cancel(launch: launch, runID: runID, store: store) }
    }

    func stopAll() {
        for thread in threads { if let running = thread.runningRun { stop(runID: running.id) } }
    }

    func scope(_ request: ScopeRequest) async -> Result<ScopeReply, EngineFailure> {
        refreshEngine()
        guard let launch = EngineLaunch(engine) else { return .failure(EngineFailure(reason: "quorum-engine was not found")) }
        return await EngineRunClient.scope(launch: launch, request: request)
    }

    func goDeeper(_ thread: QuestionThread) {
        if let start = page(for: thread).goDeeperStart() { _ = startRun(start) }
    }

    func followUp(_ thread: QuestionThread, text: String) -> Bool {
        guard let start = page(for: thread).followUpStart(text) else { return false }
        return startRun(start)
    }

    func copyMarkdown(_ thread: QuestionThread) {
        guard let url = AnswerExport.url(forQuestion: thread.id, in: brainURL),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    func reveal(_ thread: QuestionThread) {
        guard let run = thread.latest else { return }
        NSWorkspace.shared.activateFileViewerSelecting([run.runDir.appendingPathComponent(StoredRun.recordFile)])
    }

    func openInClaudeCode(_ thread: QuestionThread) {
        if let url = AnswerExport.url(forQuestion: thread.id, in: brainURL) {
            ClaudeCodeLauncher.openNote(url)
        } else if let run = thread.latest {
            ClaudeCodeLauncher.openNote(run.runDir.appendingPathComponent(StoredRun.recordFile))
        }
    }

    func trash(_ thread: QuestionThread) {
        guard let run = thread.latest else { return }
        stopAllRuns(in: thread)
        let questionDir = run.runDir.deletingLastPathComponent().deletingLastPathComponent()
        do { try FileManager.default.trashItem(at: questionDir, resultingItemURL: nil) } catch { return }
        if selectedThread?.id == thread.id { selection = .new }
        refreshRuns()
    }

    private func stopAllRuns(in thread: QuestionThread) {
        if let running = thread.runningRun { stop(runID: running.id) }
    }
}

import Foundation
import SwiftUI
import AppKit
import QuorumCore

struct EngineProbe: Sendable {
    let engine: EngineResolution
    let preflight: PreflightResult
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
    var engine = EngineResolution.unresolved
    var engineProbed = false
    var engineChecks: [EngineDoctorCheck] = []
    var capabilities = EngineCapabilities.none
    var showsDoctor = false
    var lastRunRefusal: RunStreamParser.Refusal?

    var runs: [StoredRun] = []
    var unreadableRuns: [UnreadableRun] = []
    var threads: [QuestionThread] = [] { didSet { recomputeInbox() } }
    var ui = UIState() { didSet { recomputeInbox() } }
    var progress: [String: RunProgress] = [:] { didSet { recomputeInbox() } }
    private(set) var sections: [InboxSection] = []
    private(set) var order: [String] = []
    private(set) var unreadCount = 0
    var exports: [String: URL] = [:]
    var liveRuns: [String: LiveRun] = [:]
    var gate = RunStartGate()
    var selection: Selection = .new
    var paletteOpen = false
    var sidebarVisible = true
    var showsWork = false
    var followUps = FollowUpRequests()
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
    @ObservationIgnored private var upgradeAttempted: Set<String> = []
    @ObservationIgnored private var probeCache = Expiring<EngineProbe>(ttl: 20)
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var trashing: Set<String> = []
    @ObservationIgnored private(set) var startup: Task<Void, Never>?

    init() { composer.app = self }

    var engineRefusal: String? { engineProbed ? Preflight.engineRefusal(engine) : nil }

    var canRun: Bool {
        engine.path != nil && (preflight?.ok ?? true || AppEnv.replayFixture != nil)
    }

    var brainName: String { brainURL.lastPathComponent }

    var menuSummary: String { Inbox.menuSummary(running: threads.filter(\.isRunning).count, unread: unreadCount) }

    var unreadableRows: [UnreadableRow] { Inbox.unreadableRows(unreadableRuns) }

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

    func isStarting(question: String) -> Bool { gate.isPending(question: question) }

    private func recomputeInbox() {
        sections = Inbox.sections(threads: threads, progress: progress, ui: ui, now: Date(), calendar: .current)
        order = Inbox.order(sections)
        unreadCount = sections.flatMap(\.rows).filter(\.unread).count
        DockStatus.update(unread: unreadCount)
    }

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.reload()
                await self.reattachRunning()
            }
        }
        startup = Task { [weak self] in
            guard let self else { return }
            async let loaded: Void = self.reload()
            await self.refreshEngine(force: true)
            await loaded
            await self.reattachRunning()
        }
    }

    func refreshEngine(force: Bool = false) async {
        if !force, probeCache.value(at: Date()) != nil { return }
        let probe = await Task.detached(priority: .userInitiated) {
            EngineProbe(engine: QuorumEngine.resolve(), preflight: Preflight.check(ClaudeCLIProbe()))
        }.value
        probeCache.store(probe, at: Date())
        engine = probe.engine
        preflight = probe.preflight
        engineProbed = true
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
            self.capabilities = EngineCapabilities(checks: checks)
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
        for run in liveRuns.values { run.task?.cancel() }
        liveRuns = [:]
        progress = [:]
        threads = []
        exports = [:]
        viewing = [:]
        brainURL = url
        selection = .new
        probeCache.invalidate()
        Task { [weak self] in
            guard let self else { return }
            async let loaded: Void = self.reload()
            await self.refreshEngine(force: true)
            await loaded
            await self.reattachRunning()
        }
    }

    func reload() async {
        let previous = reloadTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.loadSnapshot()
        }
        reloadTask = task
        await task.value
    }

    private func loadSnapshot() async {
        let brain = brainURL
        let snapshot = await Task.detached(priority: .userInitiated) { BrainSnapshot.load(brain: brain) }.value
        guard brain == brainURL else { return }
        runs = snapshot.runs
        unreadableRuns = snapshot.unreadable
        exports = snapshot.exports
        ui = snapshot.ui
        threads = snapshot.threads
        upgradeWaitingRuns(snapshot.unreadable)
        keepSelectedRead()
    }

    private func upgradeWaitingRuns(_ unreadable: [UnreadableRun]) {
        let waiting = Set(unreadable.filter { if case .needsUpgrade = $0.reason { true } else { false } }.map(\.id))
        guard !waiting.subtracting(upgradeAttempted).isEmpty, let launch = EngineLaunch(engine) else { return }
        upgradeAttempted.formUnion(waiting)
        let store = brainURL
        Task { [weak self] in
            _ = await EngineRunClient.migrate(launch: launch, store: store)
            await self?.reload()
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

    func startRun(_ start: RunStart, origin: RunOrigin) -> Bool {
        guard !start.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard gate.begin(start, runningQuestions: Set(threads.filter(\.isRunning).map(\.id))) else { return false }
        let selectionAtStart = selection

        Task { [weak self] in
            guard let self else { return }
            defer { self.gate.finish(start) }
            await self.refreshEngine()
            let replay = AppEnv.replayFixture
            guard let launch = EngineLaunch(self.engine), self.preflight?.ok == true || replay != nil else {
                if origin == .composer { self.composer.starting = false }
                self.showsDoctor = true
                return
            }
            let config = EngineRunConfig(start: start, brainDir: self.brainURL)
            let store = self.brainURL
            let started = await EngineRunClient.start(launch: launch, config: config, store: store, replaying: replay)
            switch started {
            case .failure(let failure):
                if origin == .composer { self.composer.starting = false }
                self.lastRunRefusal = RunStreamParser.Refusal(kind: "engine_failed", reason: failure.reason)
                self.showsDoctor = true
            case .success(let created):
                await self.attach(created: created, origin: origin, selectionAtStart: selectionAtStart, launch: launch, store: store)
            }
        }
        return true
    }

    private func attach(created: RunCreated, origin: RunOrigin, selectionAtStart: Selection, launch: EngineLaunch, store: URL) async {
        let run = LiveRun(id: created.runID)
        run.evidenceDir = created.runDir.appendingPathComponent("evidence", isDirectory: true)
        liveRuns[created.runID] = run
        await reload()
        let plan = AttachPlan.decide(origin: origin, selectionAtStart: selectionAtStart, selectionNow: selection)
        if plan.select { select(question: created.questionID) }
        if plan.resetComposer { composer.reset() }
        follow(run, runDir: created.runDir, launch: launch, store: store)
    }

    func reattachRunning() async {
        guard let launch = EngineLaunch(engine) else { return }
        let store = brainURL
        let entries = await EngineRunClient.list(launch: launch, store: store)
        guard store == brainURL else { return }
        await reload()
        for entry in EngineReply.toReattach(entries, watching: Set(liveRuns.keys)) {
            let run = LiveRun(id: entry.runID)
            run.evidenceDir = entry.runDir.appendingPathComponent("evidence", isDirectory: true)
            liveRuns[entry.runID] = run
            follow(run, runDir: entry.runDir, launch: launch, store: store)
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
                    if Preflight.opensDoctor(for: refusal) { self?.showsDoctor = true }
                }
            })
        run.task = Task { [weak self] in
            _ = await EngineRunClient.watch(runDir: runDir, launch: launch, store: store, clock: SystemClock(),
                                            notifier: GatedNotifier(enabled: { UserDefaults.standard.object(forKey: AppModel.notifyKey) as? Bool ?? true }), callbacks: callbacks)
            guard !Task.isCancelled, let self else { return }
            self.liveRuns[id] = nil
            self.progress[id] = nil
            await self.reload()
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
        await refreshEngine()
        guard let launch = EngineLaunch(engine) else { return .failure(EngineFailure(reason: "quorum-engine was not found")) }
        return await EngineRunClient.scope(launch: launch, request: request)
    }

    func goDeeper(_ thread: QuestionThread) {
        if let start = page(for: thread).goDeeperStart() { _ = startRun(start, origin: .thread(thread.id)) }
    }

    func followUp(_ thread: QuestionThread, text: String) -> Bool {
        guard let start = page(for: thread).followUpStart(text) else { return false }
        return startRun(start, origin: .thread(thread.id))
    }

    func copyMarkdown(_ thread: QuestionThread) {
        guard let url = exports[thread.id],
              let markdown = try? String(contentsOf: url, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    func reveal(_ thread: QuestionThread) {
        guard let run = thread.latest else { return }
        NSWorkspace.shared.activateFileViewerSelecting([run.runDir.appendingPathComponent(StoredRun.recordFile)])
    }

    func openInClaudeCode(_ thread: QuestionThread) {
        if let url = exports[thread.id] {
            ClaudeCodeLauncher.openNote(url)
        } else if let run = thread.latest {
            ClaudeCodeLauncher.openNote(run.runDir.appendingPathComponent(StoredRun.recordFile))
        }
    }

    func trash(_ thread: QuestionThread) {
        guard trashing.insert(thread.id).inserted else { return }
        let brain = brainURL
        let launch = EngineLaunch(engine)
        let runDirs = Dictionary(uniqueKeysWithValues: thread.runs.map { ($0.id, $0.runDir) })
        Task { [weak self] in
            let outcome = await ThreadTrash.perform(
                thread: thread, brain: brain,
                stop: { runID in
                    guard let launch else { return }
                    _ = await EngineRunClient.cancel(launch: launch, runID: runID, store: brain)
                },
                isStillRunning: { runID in
                    guard let dir = runDirs[runID] else { return false }
                    return await Task.detached { StoredRun.load(dir)?.isRunning ?? false }.value
                },
                trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
            guard let self else { return }
            self.trashing.remove(thread.id)
            switch outcome {
            case .trashed:
                for run in thread.runs { self.liveRuns[run.id]?.task?.cancel(); self.liveRuns[run.id] = nil; self.progress[run.id] = nil }
                if self.selectedThread?.id == thread.id { self.selection = .new }
                await self.reload()
            case .stillRunning:
                Self.alert("The run is still going, so the question was left where it is. Try again in a moment.")
            case .failed:
                Self.alert("The question could not be moved to the Trash.")
            }
        }
    }

    private static func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}

import SwiftUI
import AppKit
import WebKit
import QuorumCore

// MARK: - Root

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var selection: Panel = .compose
    @State private var collapsedFolders: Set<String> = []   // Notes tree: folders default open (track the closed ones)
    @State private var renaming: URL?
    @State private var renameText = ""

    enum Panel: Hashable { case compose, note(String), run(String) }

    private var sidebar: some View {
        List(selection: $selection) {
            Button { model.chooseBrainFolder() } label: {
                Label(model.brainName, systemImage: "folder")
            }
            .buttonStyle(.plain)
            .help("Brain folder: \(model.brainURL.path). Click to choose another.")

            Section {
                Label("New run", systemImage: "point.3.connected.trianglepath.dotted").tag(Panel.compose)
            }
            Section("Questions") {
                ForEach(model.unlistedLiveRuns) { live in
                    liveRow(live).tag(Panel.run(live.id))
                }
                ForEach(model.runs) { run in
                    historyRow(run)
                        .tag(Panel.run(run.id))
                        .contextMenu {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([run.runDir]) }
                            Button("Move to Trash", role: .destructive) { deleteRun(run) }
                        }
                }
                if model.runs.isEmpty && model.activeRuns.isEmpty { Text("No past runs").foregroundStyle(.secondary) }
            }
            Section("Answers") {
                if model.noteTree.isEmpty {
                    Text("No exported answers").foregroundStyle(.secondary)
                } else {
                    NoteTreeRows(nodes: model.noteTree, collapsed: $collapsedFolders,
                                 onDelete: deleteNote, onRename: beginRename, onDuplicate: duplicateNote)
                }
            }
        }
        .frame(minWidth: 230)
        .id(model.brainURL)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .compose: ComposeView(model: model)
        case .note(let path): NoteEditorView(path: path, model: model, onDelete: deleteNote).id(path)
        case .run(let key):
            if let run = model.liveRun(for: key) {
                FanOutView(model: model, run: run)
            } else if let stored = model.storedRun(for: key) {
                RunDetailView(model: model, run: stored)
            } else {
                ComposeView(model: model)
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Quorum")
        .sheet(isPresented: $model.quickSwitchOpen) {
            QuickSwitchView(items: quickSwitchItems()) { model.quickSwitchOpen = false }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { commitRename() }
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            model.start()
        }
        // Focus a run the instant it launches (added to History, watched live there).
        .onChange(of: model.recordedLiveRun) { _, recorded in
            guard let recorded, case .run(let key) = selection, key == recorded.key else { return }
            selection = .run(recorded.runID)
        }
        .onChange(of: model.focusRun) { _, stamp in
            if let stamp { selection = .run(stamp); model.focusRun = nil }
        }
        // "Open note" from a run's graph — the export opens in the same editor the notes browser uses.
        .onChange(of: model.focusNote) { _, path in
            if let path { selection = .note(path); model.focusNote = nil }
        }
        // Dock badge reflects whether anything is running; per-run completion alerts via notifications.
        .onChange(of: model.overallRunState) { _, state in DockStatus.update(runState: state, progress: nil) }
    }

    @ViewBuilder private func historyRow(_ run: StoredRun) -> some View {
        if let live = model.liveRun(for: run.id) {
            liveRow(live)
        } else {
            Label(run.title, systemImage: run.isRunning ? "hourglass" : "doc.text")
        }
    }

    private func liveRow(_ live: LiveRun) -> some View {
        Label {
            Text(live.fanOut.title ?? live.fanOut.question).lineLimit(1)
        } icon: {
            ProgressView().controlSize(.small)
        }
        .badge(Text(phaseWord(live.fanOut.phase)))
    }

    /// Everything the ⌘K switcher can jump to: the fixed commands (New run / project picking), then recent
    /// projects, past questions, and every note. Order here is the pre-typing order; `QuickSwitch` re-ranks as
    /// you type.
    private func quickSwitchItems() -> [QuickSwitchItem] {
        var items: [QuickSwitchItem] = [
            QuickSwitchItem(id: "cmd.compose", title: "New run", subtitle: "Command",
                            systemImage: "point.3.connected.trianglepath.dotted") { selection = .compose },
            QuickSwitchItem(id: "cmd.brain", title: "Choose Brain Folder…", subtitle: "Command",
                            systemImage: "folder.badge.gearshape") { model.chooseBrainFolder(); selection = .compose },
        ]
        if !model.activeRuns.isEmpty {
            items.append(QuickSwitchItem(id: "cmd.stopall", title: "Stop all runs", subtitle: "Command",
                                         systemImage: "stop.fill") { model.stopAll() })
        }
        for run in model.runs {
            items.append(QuickSwitchItem(id: "run." + run.id, title: run.title,
                                         subtitle: "Question", systemImage: "doc.text") { selection = .run(run.id) })
        }
        items += openRunNodeItems()
        for note in flattenNotes(model.noteTree) {
            items.append(QuickSwitchItem(id: "note." + note.url.path, title: note.name,
                                         subtitle: "Answer", systemImage: "doc.plaintext") {
                selection = .note(note.url.path)
            })
        }
        return items
    }

    /// The canvas of the run being watched, searchable by node. A run that grew past one screen is still
    /// navigable by the name of the thing you are looking for rather than by hunting across ranks.
    private func openRunNodeItems() -> [QuickSwitchItem] {
        guard case let .run(stamp) = selection, let run = model.liveRun(for: stamp) else { return [] }
        return run.graph.nodesMatching("").map { node in
            QuickSwitchItem(id: "node." + stamp + "." + node.id, title: node.title,
                            subtitle: "In this run",
                            systemImage: "point.3.filled.connected.trianglepath.dotted") {
                selection = .run(stamp)
                run.revealedNode = node.id
            }
        }
    }

    private func flattenNotes(_ nodes: [NoteTreeNode]) -> [NoteTreeNode] {
        nodes.flatMap { node in node.childrenOrNil.map(flattenNotes) ?? [node] }
    }

    private func deleteRun(_ run: StoredRun) {
        if let live = model.liveRun(for: run.id) { model.stop(live); model.activeRuns[live.id] = nil }
        do { try FileManager.default.trashItem(at: run.runDir, resultingItemURL: nil) } catch { return }
        if case .run(let key) = selection, key == run.id { selection = .compose }
        model.refreshRuns()
    }

    /// Move a note or folder to the Trash (reversible), drop it from the tree, and leave the editor if the
    /// open note was the one deleted (or lived inside the deleted folder).
    private func deleteNote(_ url: URL) {
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { return }
        if case .note(let p) = selection, p == url.path || p.hasPrefix(url.path + "/") { selection = .compose }
        model.refreshNotes()
    }

    /// Prefill the rename field with the base name (extension re-applied on commit) and open the dialog.
    private func beginRename(_ url: URL) {
        renaming = url
        renameText = url.deletingPathExtension().lastPathComponent
    }

    /// Rename on disk, keeping the file's extension, and follow the open note (or a note under a renamed
    /// folder) to its new path so the editor stays put.
    private func commitRename() {
        guard let old = renaming else { return }
        renaming = nil
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ext = old.pathExtension
        let newName = (ext.isEmpty || (trimmed as NSString).pathExtension == ext) ? trimmed : "\(trimmed).\(ext)"
        let dest = old.deletingLastPathComponent().appendingPathComponent(newName)
        guard dest.path != old.path else { return }
        do { try FileManager.default.moveItem(at: old, to: dest) } catch { return }
        if case .note(let p) = selection {
            if p == old.path { selection = .note(dest.path) }
            else if p.hasPrefix(old.path + "/") { selection = .note(dest.path + String(p.dropFirst(old.path.count))) }
        }
        model.refreshNotes()
    }

    /// Copy a note or folder next to itself under the first free "… copy" name.
    private func duplicateNote(_ url: URL) {
        let dir = url.deletingLastPathComponent(), ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        func candidate(_ suffix: String) -> URL {
            dir.appendingPathComponent(ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)")
        }
        var dest = candidate(" copy"), n = 2
        while FileManager.default.fileExists(atPath: dest.path) { dest = candidate(" copy \(n)"); n += 1 }
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return }
        model.refreshNotes()
    }

    private func phaseWord(_ p: FanOutPhase) -> String {
        switch p {
        case .planning:     return "planning"
        case .researching:  return "researching"
        case .synthesizing: return "synthesizing"
        case .verifying, .validating: return "checking"
        case .done:         return ""
        }
    }
}

/// The Notes folder tree as recursive rows. A folder is a `DisclosureGroup` whose whole label (icon +
/// name) toggles it open — not just the chevron; a file is tagged so selecting it opens the editor.
/// Expansion is tracked as the *collapsed* set, so folders default open and a newly-written note's
/// folder shows up already expanded.
private struct NoteTreeRows: View {
    let nodes: [NoteTreeNode]
    @Binding var collapsed: Set<String>
    let onDelete: (URL) -> Void
    let onRename: (URL) -> Void
    let onDuplicate: (URL) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.childrenOrNil {
                DisclosureGroup(isExpanded: expansion(node.id)) {
                    NoteTreeRows(nodes: children, collapsed: $collapsed,
                                 onDelete: onDelete, onRename: onRename, onDuplicate: onDuplicate)
                } label: {
                    Button { toggle(node.id) } label: {
                        Label(node.name, systemImage: "folder")
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(node.url) }
                }
            } else {
                Label(node.name, systemImage: "doc.plaintext")
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .tag(ContentView.Panel.note(node.url.path))
                    .contextMenu { menu(node.url) }
            }
        }
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(id) },
                set: { isOpen in if isOpen { collapsed.remove(id) } else { collapsed.insert(id) } })
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    @ViewBuilder private func menu(_ url: URL) -> some View {
        Button("Open in Claude Code") { ClaudeCodeLauncher.openNote(url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        Button("Duplicate") { onDuplicate(url) }
        Button("Rename…") { onRename(url) }
        Divider()
        Button("Move to Trash", role: .destructive) { onDelete(url) }
    }
}

// MARK: - Compose & Run

struct ComposeView: View {
    @Bindable var model: AppModel
    @AppStorage("agentModel") private var agentModel: ModelChoice = .default
    @AppStorage("synthesisModel") private var synthesisModel: ModelChoice = .default
    @AppStorage("runProfile") private var storedRunProfile: RunProfile = .subscription
    @AppStorage(ExperimentalProfiles.defaultsKey) private var experimentsEnabled = false

    private var runProfile: RunProfile {
        ExperimentalProfiles.effective(storedRunProfile, experimentsEnabled: experimentsEnabled)
    }

    var body: some View {
        content
            .onChange(of: model.perTopicTimeoutMinutes) { _, _ in model.saveState() }
            .onChange(of: model.defaultPreset) { _, _ in model.saveState() }
            .onChange(of: model.synthesisTemplate) { _, _ in model.saveState() }
            .onChange(of: model.useProjectContext) { _, _ in model.saveState() }
            .onChange(of: model.rounds) { _, _ in model.saveState() }
            .sheet(isPresented: $model.showsDoctor) { DoctorView(model: model) }
    }

    @ViewBuilder private var content: some View {
        home
    }

    /// A single, centered, readable-width column — not a full-bleed List. The ask box leads; a CLI
    /// problem (if any) surfaces above it; confirmation + advanced settings + the dev toggle sit below.
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let pf = model.preflight, !pf.ok { preflightRow(pf) }
                if let refusal = model.engineRefusal { refusalRow(refusal) }
                heroSection
                settingsSection
            }
            .padding(28)
            .readableColumn()
        }
    }

    private var heroSection: some View {
        ScopingView(model: model)
    }

    /// Always $-format the cost — it's priced in dollars, so don't let the OS locale render "12,00 US$".
    private func usd(_ d: Decimal) -> String {
        d.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    /// A CLI problem that blocks a run — shown prominently above the ask box so it's seen before typing.
    private func preflightRow(_ pf: PreflightResult) -> some View {
        warningRow(pf.message)
    }

    private func refusalRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message).font(.callout)
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            Button("Open Doctor") { model.showsDoctor = true }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private func warningRow(_ message: String) -> some View {
        Label {
            Text(message).font(.callout)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var settingsSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                profilePicker
                Divider()
                Picker("Default effort", selection: $model.defaultPreset) {
                    ForEach(EffortPreset.allCases) { Text($0.displayName).tag($0) }
                }
                Text("Spend caps: \(usd(model.perTopicSpendCap))/agent · \(usd(model.runSpendCap))/run")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Deliverable", selection: $model.synthesisTemplate) {
                    ForEach(ResearchTemplate.allCases) { Text($0.displayName).tag($0) }
                }
                Stepper("Per-agent time wall: \(model.perTopicTimeoutMinutes) min",
                        value: $model.perTopicTimeoutMinutes, in: 1...240)
                Divider()
                Toggle(isOn: $model.useProjectContext) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Read this project as context")
                        Text("Each angle's agent may read your project files (read-only) alongside the web.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Stepper("Round cap: \(model.rounds)", value: $model.rounds, in: 1...8)
                    Text("A round past the first only runs if the validators still object — each one researches those objections and re-judges the answer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Picker("Research agents", selection: $agentModel) {
                    ForEach(ModelChoice.allCases, id: \.self) { Text($0.menuLabel).tag($0) }
                }
                Picker("Synthesis & reconciliation", selection: $synthesisModel) {
                    ForEach(ModelChoice.allCases, id: \.self) {
                        Text($0 == .default ? "Same as agents" : $0.menuLabel).tag($0)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label("Run settings", systemImage: "gearshape")
                let profilePrefix = runProfile == .subscription ? "" : "\(runProfile.displayName) · "
                let angleModelName = runProfile == .codex
                    ? EngineKeys.configuredCodexAngleModel().displayName : agentModel.displayName
                Text("\(profilePrefix)\(model.defaultPreset.displayName) · \(angleModelName) agents\(model.useProjectContext ? " · reads project" : "") · up to \(model.rounds) rounds")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Engine profile chooser (PRD 02 R2/R4). BYOK profiles stay disabled with a one-line reason until
    /// the needed keys exist; a stale unavailable selection is flagged and falls back to Subscription.
    private var profilePicker: some View {
        let hasModel = EngineKeys.hasKeyForModel(EngineKeys.configuredAngleModel())
        let hasSearch = EngineKeys.hasSearchKey()
        let hasCodex = CodexCLI.resolvePath() != nil
        return VStack(alignment: .leading, spacing: 4) {
            Menu {
                ForEach(ExperimentalProfiles.selectable(experimentsEnabled: experimentsEnabled)) { p in
                    let avail = p.availability(hasModelKey: hasModel, hasSearchKey: hasSearch, hasCodexCLI: hasCodex)
                    Button {
                        storedRunProfile = p
                    } label: {
                        if runProfile == p { Label(p.displayName, systemImage: "checkmark") }
                        else { Text(p.displayName) }
                    }
                    .disabled(!avail.ok)
                }
            } label: {
                HStack {
                    Text("Engine profile")
                    Spacer()
                    Text(runProfile.displayName).foregroundStyle(.secondary)
                }
            }
            let avail = runProfile.availability(hasModelKey: hasModel, hasSearchKey: hasSearch, hasCodexCLI: hasCodex)
            Text(avail.reason.map { "⚠️ \($0) — running as Subscription until then." } ?? runProfile.blurb)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The right-side sidebar that renders a tapped source in-app. "Open in browser" is the escape hatch
/// for sites that refuse to embed (X-Frame-Options / CSP frame-ancestors).
struct SourceInspector: View {
    let url: URL?
    let onClose: () -> Void

    var body: some View {
        if let url {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "safari").foregroundStyle(.secondary)
                    Text(url.host ?? url.absoluteString).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(.borderless).help("Open in browser")
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Close")
                }
                .padding(10)
                Divider()
                WebView(url: url).id(url)   // fresh load per source — no reload bookkeeping
            }
        } else {
            ContentUnavailableView("No source selected", systemImage: "link")
        }
    }
}

/// Minimal in-app browser. Recreated per-URL via `.id(url)` at the call site, so a one-shot load in
/// makeNSView is all it needs — no update/reload logic. ponytail: swap to a shared WKWebView + navigate
/// if we ever want back/forward history across sources.
struct WebView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.load(URLRequest(url: url))
        return web
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - A saved run → its brief (right pane), each topic opening its writeup

struct TopicTarget: Hashable {
    let question: String
    let writeup: String?
    let sessionID: String?
    let brainPath: String
    var runDir: URL? = nil
    var isSynthesis = false
    var status: TopicStatus = .complete
    var headline = ""
    var claimsSummary = ""
    var sourcesLabel = ""
    var conflicts: [Conflict] = []
    var gaps: [String] = []
    var sources: [String] = []
    var caveat: String? = nil
    var angleCount = 0
    var rounds = 1
    var wasEngineRun = false
    var evidence: EvidenceContext? = nil
}

extension TopicTarget {
    static func from(_ task: RecordTask, in run: StoredRun) -> TopicTarget {
        let record = run.record
        let isAnswer = task.id == run.answerTask?.id
        let cited = Set(record.sources.filter(\.cited).map(\.url))
        return TopicTarget(
            question: isAnswer ? run.title : task.title,
            writeup: run.writeup(forNode: task.nodeID),
            sessionID: task.sessionID,
            brainPath: run.runDir.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().path,
            runDir: run.runDir,
            isSynthesis: task.kind == .synthesis || task.kind == .reconciliation,
            status: TopicStatus(record: task.status),
            headline: (isAnswer ? record.answer?.headline : nil) ?? task.headline ?? task.title,
            claimsSummary: isAnswer ? run.claimsSummary : "",
            sourcesLabel: isAnswer ? run.sourcesSummary : "\(task.sourceIDs.count) read",
            conflicts: isAnswer ? record.conflicts.map { Conflict(claim: $0.statement, positions: $0.positions) } : [],
            gaps: isAnswer ? record.gaps.map(\.text) : [],
            sources: isAnswer ? record.sources.filter(\.cited).map(\.url) : Array(cited),
            caveat: task.note ?? (isAnswer ? record.statusNote : nil),
            angleCount: record.stats.tasks,
            rounds: max(1, record.stats.rounds),
            wasEngineRun: task.backend != "cli",
            evidence: run.evidence(forNode: task.nodeID))
    }
}

struct RunDetailView: View {
    let model: AppModel
    let run: StoredRun
    @State private var showSummary = false

    var body: some View {
        let summary = run.answerTask.map { TopicTarget.from($0, in: run) }
        return NavigationStack {
            FinishedRunView(run: run)
                .navigationTitle(run.title)
                .navigationDestination(for: TopicTarget.self) {
                    TopicDetailView(target: $0, model: model, showSummary: $showSummary, summary: summary)
                }
        }
    }
}

struct TopicDetailView: View {
    let target: TopicTarget
    let model: AppModel
    @Binding var showSummary: Bool
    let summary: TopicTarget?
    @State private var exploring: URL?
    @State private var citation: Citation?

    init(target: TopicTarget, model: AppModel, showSummary: Binding<Bool>, summary: TopicTarget?) {
        self.target = target
        self.model = model
        self._showSummary = showSummary
        self.summary = summary
    }

    var body: some View {
        Group {
            if let writeup = target.writeup, let evidence = target.evidence {
                CitedReader(writeup: writeup, evidence: evidence.index, selected: $citation,
                            documentID: target.runDir?.path ?? target.question)
            } else if let writeup = target.writeup {
                ScrollView { MarkdownView(markdown: writeup).padding(28) }
            } else {
                ContentUnavailableView("No writeup yet", systemImage: "doc.text")
            }
        }
        .navigationTitle(target.question)
        .inspector(isPresented: Binding(get: { citation != nil || (showSummary && summary != nil) },
                                       set: { showSummary = $0; if !$0 { exploring = nil; citation = nil } })) {
            Group {
                if let citation, let evidence = target.evidence {
                    CitedSourceInspector(citation: citation, document: evidence.index.document(for: citation),
                                         evidenceDir: evidence.directory,
                                         grounding: evidence.grounding,
                                         tier: evidence.index.tier(citation.id)) { self.citation = nil }
                } else if let url = exploring {
                    SourceInspector(url: url) { exploring = nil }
                } else if let summary {
                    ScrollView { SynthesisSummary(target: summary) { exploring = $0 }.padding(20) }
                }
            }
            .inspectorColumnWidth(min: 360, ideal: 420, max: 900)
        }
        .toolbar {
            if target.sessionID != nil && !target.wasEngineRun {
                Button {
                    ClaudeCodeLauncher.openTerminal(projectPath: target.brainPath, resumeSessionID: target.sessionID)
                } label: { Label("Continue in Claude Code", systemImage: "terminal") }
                .help("Open this topic’s session in Terminal to keep going interactively")
                Button {
                    ClaudeCodeLauncher.openTerminal(projectPath: target.brainPath, resumeSessionID: target.sessionID, fork: true)
                } label: { Label("Fork", systemImage: "arrow.triangle.branch") }
                .help("Fork this session into a new Terminal — branches off the same history and diverges independently; open as many as you want")
            }
            if let runDir = target.runDir {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([runDir.appendingPathComponent(StoredRun.recordFile)])
                } label: { Label("Reveal", systemImage: "folder") }
                .help("Show this run’s run.json in Finder")
            }
            if summary != nil {
                Button { showSummary.toggle(); if !showSummary { exploring = nil } } label: {
                    Label("Summary", systemImage: "sidebar.right")
                }
                .help("Show the run’s synthesis summary alongside this view")
            }
        }
    }
}

/// The synthesis "what was done / what was verified" summary — the honest audit of a fan-out run:
/// the pipeline it ran, how well-corroborated the answer is, where the angles disagreed, and whether
/// every citation traced back to a source. Reads only the entry data (no re-parsing the note).
struct SynthesisSummary: View {
    let target: TopicTarget
    var onExplore: (URL) -> Void

    /// The citation-check outcome is carried in the caveat the grounding step wrote (see FanOut.groundCitations).
    private var citationFlag: String? {
        guard let c = target.caveat, c.lowercased().contains("untraceable") || c.lowercased().contains("citation") else { return nil }
        return c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { StatusBadge(status: target.status); Spacer() }
                Text(target.headline).font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("What was done", icon: "point.3.connected.trianglepath.dotted") {
                if target.rounds > 1 {
                    step("Ran \(target.rounds) rounds — each round after the first fed the previous synthesis’s unresolved conflicts & gaps back as fresh angles")
                }
                step("Researched \(target.angleCount) independent angle\(target.angleCount == 1 ? "" : "s") in parallel — each agent blind to the others")
                step("Reconciled every angle into one answer, weighting sources by how many angles corroborated them")
                step("Verified each citation traces back to a source an angle actually consulted")
            }

            section("How solid it is", icon: "checkmark.shield") {
                labeled("Claims", target.claimsSummary.isEmpty ? "—" : target.claimsSummary)
                labeled("Sources", target.sourcesLabel)
                if target.rounds > 1 { labeled("Rounds", "\(target.rounds)") }
            }

            section("Open conflicts", icon: target.conflicts.isEmpty ? "checkmark.circle" : "exclamationmark.triangle.fill",
                    tint: target.conflicts.isEmpty ? .green : .orange) {
                if target.conflicts.isEmpty {
                    Text("None — the angles agreed on the load-bearing claims.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(target.conflicts) { c in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.claim).font(.callout.weight(.medium))
                            ForEach(c.positions, id: \.self) { p in
                                Label(p, systemImage: "arrow.turn.down.right")
                                    .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            section("Open questions", icon: target.gaps.isEmpty ? "checkmark.circle" : "questionmark.diamond.fill",
                    tint: target.gaps.isEmpty ? .green : .orange) {
                if target.gaps.isEmpty {
                    Text(target.rounds > 1 ? "None left — the follow-up rounds closed the open questions."
                                            : "None — the research answered the question without leaving gaps.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(target.gaps, id: \.self) { g in
                        Label(g, systemImage: "arrow.turn.down.right")
                            .font(.callout).labelStyle(.titleAndIcon)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            section("Citation check", icon: citationFlag == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    tint: citationFlag == nil ? .green : .orange) {
                if let flag = citationFlag {
                    Text(flag).font(.callout).foregroundStyle(.orange)
                } else {
                    Text("Every cited source was consulted by at least one angle — no untraceable citations.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if !target.sources.isEmpty {
                section("Sources", icon: "link") {
                    ForEach(target.sources.prefix(25), id: \.self) { s in sourceLink(s) }
                    if target.sources.count > 25 {
                        Text("+ \(target.sources.count - 25) more — see the Answer tab").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A cited source: a real link if it parses as a web URL, otherwise selectable text (some citations
    /// are titles, not URLs).
    @ViewBuilder private func sourceLink(_ s: String) -> some View {
        if let url = URL(string: s), url.scheme?.hasPrefix("http") == true {
            Button { onExplore(url) } label: {
                Label(s, systemImage: "arrow.up.right.square").font(.caption).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.link)
        } else {
            Label(s, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    @ViewBuilder private func section(_ title: String, icon: String, tint: Color = .accentColor,
                                      @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(tint)
            content()
        }
    }

    private func step(_ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) }
        icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        .font(.callout)
    }

    private func labeled(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).fontWeight(.medium)
        }.font(.callout)
    }
}

// MARK: - Bits

struct StatusBadge: View {
    let status: TopicStatus
    var body: some View {
        let style = NodeStyle.status(status)
        Text(style.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(style.color.opacity(0.18), in: Capsule())
            .foregroundStyle(style.color)
    }
}

// MARK: - Fan-out ("explore every angle") — the run's one canvas

/// One question fanning out to N blind parallel agents and converging on an answer its own validators argue
/// with — drawn on ONE surface for every phase of it. The question is a node before the planner has said
/// anything, the plan is edited on the cards that will run, and those same cards then research: no second
/// diagram of the same run, and nothing to re-find when the research starts.
struct FanOutView: View {
    @Bindable var model: AppModel
    let run: LiveRun
    private var state: FanOutState { run.fanOut }   // read-only alias so `state.xxx` reads stay unchanged

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title ?? state.question).font(.headline).lineLimit(2)
                Text(run.progress?.label ?? phaseSummary.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) { model.stop(run) } label: { Label("Stop", systemImage: "stop.fill") }
        }
        .padding()
    }

    private var phaseSummary: RunPhaseSummary {
        RunPhaseSummary(phase: state.phase, angleCount: state.count,
                        round: state.round,
                        runningAngles: state.roundAngleCounts.last ?? state.angles.count,
                        spendUSD: run.liveByAngle.values.reduce(Decimal(0)) { $0 + $1.costUSD })
    }

    /// What the rail reads beside the canvas while the run is still going: the writeup a node has already
    /// filed, or what it is streaming right now, against the evidence the run has captured so far.
    private func liveReading(_ node: GraphNode) -> NodeReading {
        guard let dir = run.evidenceDir else { return NodeReading() }
        return NodeReading(writeup: run.evidence.writeup(for: node.id),
                           evidence: EvidenceContext(index: run.evidence.index(for: node), directory: dir))
    }

    /// One canvas for the whole run: the question, the planner's reasoning streaming on it, the angles as
    /// cards that are edited where they will run — and then those same cards researching, the answer they
    /// feed, and the verdicts filed against it. Every affordance is drawn only where the graph says it lands,
    /// so one call site serves a draft and a run in flight without pretending to be two surfaces.
    private var canvas: some View {
        ResearchGraphView(
            graph: run.graph,
            live: { id in
                switch id {
                case ResearchGraph.rootID:      return run.planningLive
                case ResearchGraph.synthesisID: return run.synthesisLive
                default:                        return run.liveByAngle[id]
                }
            },
            reading: { liveReading($0) },
            reveal: run.revealedNode,
            onRevealed: { run.revealedNode = nil })
    }
}

// MARK: - Layout

extension View {
    /// Constrain content to a centered, readable-width column instead of letting lines run the full
    /// width of a wide window. HIG: restrict text width (~50–75 characters) for readability.
    func readableColumn(_ maxWidth: CGFloat = 640) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }
}

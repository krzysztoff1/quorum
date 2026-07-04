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

    // A run is identified by its stable trailing timestamp, not its URL, so selection survives the
    // folder being renamed when the run gets its auto-title.
    enum Panel: Hashable { case compose, ask, lint, note(String), run(String) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Menu {
                    Button("Choose Project…") { model.chooseProject(); selection = .compose }
                    if !model.recentProjects.isEmpty {
                        Divider()
                        ForEach(model.recentProjects, id: \.self) { proj in
                            Button(proj.lastPathComponent) { model.openProject(proj); selection = .compose }
                        }
                    }
                } label: {
                    Label(model.projectURL == nil ? "Choose Project…" : model.projectName,
                          systemImage: model.projectURL == nil ? "folder.badge.plus" : "folder")
                }

                if model.projectURL != nil {
                    Section {
                        Label("New run", systemImage: "point.3.connected.trianglepath.dotted").tag(Panel.compose)
                        Label("Ask your brain", systemImage: "sparkle.magnifyingglass").tag(Panel.ask)
                        Label("Health check", systemImage: "stethoscope").tag(Panel.lint)
                    }
                    Section("Chats") {
                        ForEach(model.runs, id: \.self) { run in
                            historyRow(run).tag(Panel.run(RunFolder.stamp(run.lastPathComponent)))
                        }
                        if model.runs.isEmpty { Text("No past runs").foregroundStyle(.secondary) }
                    }
                    Section("Notes") {
                        if model.noteTree.isEmpty {
                            Text("No markdown notes").foregroundStyle(.secondary)
                        } else {
                            NoteTreeRows(nodes: model.noteTree, collapsed: $collapsedFolders,
                                         onDelete: deleteNote, onRename: beginRename, onDuplicate: duplicateNote)
                        }
                    }
                }
            }
            .frame(minWidth: 230)
            // Rebuild the sidebar per project — macOS List diffs stale History rows when the list shape
            // is unchanged (same sections), so switching projects otherwise keeps the old runs on screen.
            .id(model.projectURL)
        } detail: {
            switch selection {
            case .compose: ComposeView(model: model)
            case .ask: AskView(model: model).id(model.projectURL)
            case .lint: LintView(model: model).id(model.projectURL)
            case .note(let path): NoteEditorView(path: path, onDelete: deleteNote).id(path)
            case .run(let stamp):
                if let run = model.activeRuns[stamp] {
                    FanOutView(model: model, run: run)   // still researching → watch it live
                } else if let url = model.runs.first(where: { RunFolder.stamp($0.lastPathComponent) == stamp }) {
                    RunDetailView(model: model, runDir: url)
                } else {
                    ComposeView(model: model)   // run not (yet) listed — e.g. mid-refresh after a rename
                }
            }
        }
        .navigationTitle("Quorum")
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { commitRename() }
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            model.restoreLastProject()
        }
        // Focus a run the instant it launches (added to History, watched live there).
        .onChange(of: model.focusRun) { _, stamp in
            if let stamp { selection = .run(stamp); model.focusRun = nil }
        }
        // "Research this" from the health check kicked off a compose draft — jump to it so the user sees the plan.
        .onChange(of: model.focusCompose) { _, go in
            if go { selection = .compose; model.focusCompose = false }
        }
        // Dock badge reflects whether anything is running; per-run completion alerts via notifications.
        .onChange(of: model.overallRunState) { _, state in DockStatus.update(runState: state, progress: nil) }
    }

    /// A History sidebar row — a spinner + phase while the run is still researching, else a doc icon.
    @ViewBuilder private func historyRow(_ run: URL) -> some View {
        let stamp = RunFolder.stamp(run.lastPathComponent)
        if let live = model.activeRuns[stamp] {
            Label {
                Text(live.fanOut.question).lineLimit(1)
            } icon: {
                ProgressView().controlSize(.small)
            }
            .badge(Text(phaseWord(live.fanOut.phase)))
        } else {
            Label(model.runTitle(for: run) ?? prettyRunName(run), systemImage: "doc.text")
        }
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
        case .verifying:    return "checking"
        case .awaitingApproval, .done: return ""
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
    @State private var deepQuestion = ""
    @State private var angleCount = 5
    @FocusState private var questionFocused: Bool
    @AppStorage("chatModel") private var chatModel: ModelChoice = .default
    @AppStorage("agentModel") private var agentModel: ModelChoice = .default

    var body: some View {
        content
            .animation(.easeInOut(duration: 0.25), value: model.draftRun?.id)
            .onChange(of: model.runSpendCap) { _, _ in model.saveState() }
            .onChange(of: model.perTopicSpendCap) { _, _ in model.saveState() }
            .onChange(of: model.perTopicTimeoutMinutes) { _, _ in model.saveState() }
            .onChange(of: model.defaultPreset) { _, _ in model.saveState() }
            .onChange(of: model.synthesisTemplate) { _, _ in model.saveState() }
            .onChange(of: model.useProjectContext) { _, _ in model.saveState() }
            .onChange(of: model.autoresearch) { _, _ in model.saveState() }
    }

    @ViewBuilder private var content: some View {
        if model.projectURL == nil {
            ContentUnavailableView {
                Label("Pick a project folder", systemImage: "folder.badge.plus")
            } description: {
                Text("Your brain — its queue and notes — is anchored to a project folder. Choose one to begin.")
            } actions: {
                Button("Choose Project…") { model.chooseProject() }.buttonStyle(.borderedProminent)
            }
        } else if let draft = model.draftRun {
            FanOutView(model: model, run: draft).transition(.opacity)   // planning → angle approval
        } else {
            home.transition(.opacity)
        }
    }

    /// A single, centered, readable-width column — not a full-bleed List. The ask box leads; a CLI
    /// problem (if any) surfaces above it; confirmation + advanced settings + the dev toggle sit below.
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let pf = model.preflight, !pf.ok { preflightRow(pf) }   // a blocker → up top
                heroSection
                settingsSection
                if AppEnv.isDev { devSection }
            }
            .padding(28)
            .readableColumn()
        }
        .onAppear { questionFocused = true }   // cursor ready in the ask box on open
    }

    /// Dev-only (`swift run Quorum`): simulate the whole run with instant, canned results — no
    /// external API calls, no token spend. Absent in shipped builds.
    private var devSection: some View {
        Toggle(isOn: $model.dryRun) {
            Label("Dry run — no API calls, no spend", systemImage: "testtube.2")
        }
        .font(.callout).foregroundStyle(.secondary)
    }

    // MARK: The headline feature — ask one question, explore it from every angle

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Explore every angle", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title2.bold())
                if deepQuestion.trimmingCharacters(in: .whitespaces).isEmpty {   // explainer only before you type
                    Text("Ask one big question — Quorum researches it from many angles at once, then merges the findings into one answer.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextField("What do you want to explore?", text: $deepQuestion, axis: .vertical)
                .textFieldStyle(.plain).font(.title3).lineLimit(3...10)
                .focused($questionFocused)
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))

            angleCountControl

            Button {
                model.planDeepDive(deepQuestion, count: angleCount)
                deepQuestion = ""   // the question now lives in the draft; Compose resets
            } label: {
                Label("Plan \(angleCount) angles", systemImage: "sparkles")
                    .font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)   // ⌘↩ submits — HIG: honor the default button
            .disabled(deepQuestion.trimmingCharacters(in: .whitespaces).isEmpty)

            Text("Nothing runs until you review.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var angleCountControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How many angles?").font(.headline)
            Picker("How many angles?", selection: $angleCount) {
                ForEach(2...8, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()   // all 7 choices visible, one click — no repeated stepper taps
            Text("\(angleHint) · up to \(usd(estCeiling)) total")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var angleHint: String {
        switch angleCount {
        case ...3:  return "focused — a few sharp angles"
        case 4...6: return "balanced coverage"
        default:    return "widest net · higher cost"
        }
    }

    /// Hard spending ceiling for the run: (angles + synthesis) each capped, never past the run cap.
    private var estCeiling: Decimal {
        min(model.runSpendCap, model.perTopicSpendCap * Decimal(angleCount + 1))
    }

    /// Always $-format the cost — it's priced in dollars, so don't let the OS locale render "12,00 US$".
    private func usd(_ d: Decimal) -> String {
        d.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    /// A CLI problem that blocks a run — shown prominently above the ask box so it's seen before typing.
    private func preflightRow(_ pf: PreflightResult) -> some View {
        Label {
            Text(pf.message).font(.callout)
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
                Picker("Default effort", selection: $model.defaultPreset) {
                    ForEach(EffortPreset.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Deliverable", selection: $model.synthesisTemplate) {
                    ForEach(ResearchTemplate.allCases) { Text($0.displayName).tag($0) }
                }
                TextField("Run spend cap", value: $model.runSpendCap, format: .currency(code: "USD"))
                TextField("Per-agent spend cap", value: $model.perTopicSpendCap, format: .currency(code: "USD"))
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
                Toggle(isOn: $model.autoresearch) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Autoresearch")
                        Text("Keep digging in deeper rounds until the answer is concrete — or the run spend cap is hit.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Picker("Research agents", selection: $agentModel) {
                    ForEach(ModelChoice.allCases, id: \.self) { Text($0.menuLabel).tag($0) }
                }
                Picker("Chat", selection: $chatModel) {
                    ForEach(ModelChoice.allCases, id: \.self) { Text($0.menuLabel).tag($0) }
                }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label("Run settings", systemImage: "gearshape")
                Text("\(model.defaultPreset.displayName) · \(agentModel.displayName) agents\(model.useProjectContext ? " · reads project" : "")\(model.autoresearch ? " · autoresearch" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Live research feed (thinking / output / sources, streaming)

struct LiveView: View {
    let progress: String?
    let live: LiveSnapshot
    let onStop: () -> Void
    @State private var showThinking = true
    @State private var exploring: URL?   // tapped source → opened in the right-side inspector, not the browser

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(live.question.isEmpty ? "Researching…" : live.question).font(.headline).lineLimit(1)
                    if let p = progress { Text(p).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button(role: .destructive) { onStop() } label: { Label("Stop", systemImage: "stop.fill") }
            }
            .padding()
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !live.sources.isEmpty { sourcesCard }
                        if !live.thinking.isEmpty { thinkingCard }
                        outputCard
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: live.output) { _, _ in withAnimation(.easeOut) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
        .inspector(isPresented: Binding(get: { exploring != nil }, set: { if !$0 { exploring = nil } })) {
            SourceInspector(url: exploring) { exploring = nil }
                .inspectorColumnWidth(min: 320, ideal: 460, max: 900)
        }
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Sources consulted (\(live.sources.count))", systemImage: "link").font(.headline)
            ForEach(live.sources) { source in
                SourceRow(source: source) { exploring = $0 }.font(.callout)
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .animation(.spring(duration: 0.35), value: live.sources.count)
    }

    private var thinkingCard: some View {
        DisclosureGroup(isExpanded: $showThinking) {
            Text(live.thinking)
                .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
        } label: {
            Label("Thinking", systemImage: "brain").font(.headline)
        }
    }

    @ViewBuilder private var outputCard: some View {
        if live.output.isEmpty {
            Label("Fanning out searches…", systemImage: "sparkles").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Findings so far").font(.headline)
                Text(live.output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct SourceRow: View {
    let source: LiveSource
    var onOpen: (URL) -> Void

    var body: some View {
        if source.isURL, let url = URL(string: source.value) {
            Button { onOpen(url) } label: {
                Label { Text(url.host.map { $0 + url.path } ?? source.value).lineLimit(1) }
                icon: { Image(systemName: icon) }
            }
            .buttonStyle(.link)
        } else {
            Label { Text(source.value).lineLimit(1).foregroundStyle(.secondary) }
            icon: { Image(systemName: sourceIcon(source)).foregroundStyle(.secondary) }
        }
    }

    private var icon: String { sourceIcon(source) }
}

/// SF Symbol for a live source, by tool kind / URL. Shared by the sources list and the fan satellites.
func sourceIcon(_ source: LiveSource) -> String {
    if source.kind == "WebSearch" { return "magnifyingglass" }
    if source.isURL {
        let v = source.value.lowercased()
        if v.contains("youtube") || v.contains("youtu.be") || v.contains("vimeo") { return "play.rectangle.fill" }
        return "safari"
    }
    return "doc.text"
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

// MARK: - A saved run → its brief (right pane), each topic opening writeup + chat

struct TopicTarget: Hashable {
    let question: String
    let notePath: String?
    let sessionID: String?
    let projectPath: String
    // Synthesis-only: enough to render a "what was done / verified" summary without re-reading the note.
    var isSynthesis = false
    var status: TopicStatus = .complete
    var headline = ""
    var confidenceSummary = ""
    var sourcesConsulted = 0
    var conflicts: [Conflict] = []
    var gaps: [String] = []
    var sources: [String] = []
    var caveat: String? = nil
    var angleCount = 0
    var rounds = 1
}

struct RunDetailView: View {
    let model: AppModel
    let runDir: URL

    var body: some View {
        NavigationStack {
            Group {
                if let report = model.loadReport(runDir) {
                    DigestView(report: report, projectPath: model.projectURL?.path ?? runDir.deletingLastPathComponent().deletingLastPathComponent().path)
                } else {
                    ContentUnavailableView("Couldn’t load this run", systemImage: "questionmark.folder",
                                           description: Text(runDir.path))
                }
            }
            .navigationDestination(for: TopicTarget.self) { TopicDetailView(target: $0) }
        }
        .navigationTitle(prettyRunName(runDir))
    }
}

/// A static fan-out diagram rebuilt from a finished run's report, so the shape of the research is visible
/// in History too — not only in the live radial fan during processing. Question at the top → each
/// iterative round's angles as a row (the research is seen to GROW round over round) → the synthesis at
/// the bottom, badged with how many conflicts/gaps it surfaced.
struct FanDiagram: View {
    let report: RunReport

    private var synthesis: RunReport.TopicEntry? { report.entries.first { $0.isSynthesis == true } }
    private var rounds: [(round: Int, angles: [RunReport.TopicEntry])] {
        let angles = report.entries.filter { $0.isSynthesis != true && $0.status != .skipped }
        let groups = Dictionary(grouping: angles) { $0.round ?? 1 }
        return groups.keys.sorted().map { (round: $0, angles: groups[$0] ?? []) }
    }
    private var questionText: String { synthesis?.question ?? rounds.first?.angles.first?.question ?? "Question" }

    var body: some View {
        VStack(spacing: 6) {
            card(questionText, tint: .accentColor)
            ForEach(rounds, id: \.round) { r in
                connector
                if rounds.count > 1 {
                    Text("Round \(r.round)").font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary).textCase(.uppercase)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) { ForEach(r.angles, id: \.id) { angleChip($0) } }
                        .padding(.horizontal, 2).padding(.bottom, 4)
                }
            }
            connector
            if let s = synthesis { synthesisCard(s) }
        }
        .frame(maxWidth: .infinity)
    }

    private var connector: some View { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2, height: 16) }

    private func card(_ text: String, tint: Color) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center).lineLimit(3)
            .padding(10).frame(maxWidth: 340)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.5)))
    }

    private func angleChip(_ e: RunReport.TopicEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                statusDot(e.status)
                Text(e.question).font(.caption.weight(.semibold)).lineLimit(2)
            }
            Text("\(e.sourcesConsulted) source\(e.sourcesConsulted == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8).frame(width: 150, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
    }

    private func synthesisCard(_ e: RunReport.TopicEntry) -> some View {
        VStack(spacing: 4) {
            Label("Synthesis", systemImage: "sparkles").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
            Text(e.headline).font(.caption).multilineTextAlignment(.center).lineLimit(3)
            HStack(spacing: 12) {
                if let c = e.conflicts, !c.isEmpty {
                    Label("\(c.count) conflict\(c.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if let g = e.gaps, !g.isEmpty {
                    Label("\(g.count) gap\(g.count == 1 ? "" : "s")", systemImage: "questionmark.diamond.fill").foregroundStyle(.orange)
                }
            }.font(.caption2)
        }
        .padding(10).frame(maxWidth: 340)
        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.5)))
    }

    @ViewBuilder private func statusDot(_ s: TopicStatus) -> some View {
        switch s {
        case .complete:     Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .inconclusive: Image(systemName: "questionmark.circle.fill").foregroundStyle(.yellow)
        case .haltedSpend, .haltedTime, .haltedManual, .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        default:            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

struct DigestView: View {
    let report: RunReport
    let projectPath: String
    private var synthesis: RunReport.TopicEntry? { report.entries.first { $0.isSynthesis == true } }
    private var angleCount: Int { report.entries.filter { $0.isSynthesis != true && $0.status != .skipped }.count }
    private var isFanOut: Bool { synthesis != nil }
    private var rounds: Int { report.entries.compactMap(\.round).max() ?? 1 }

    var body: some View {
        List {
            if let s = synthesis {
                Section { NavigationLink(value: target(for: s)) { answerHeader(s) } }
            }

            if isFanOut {
                Section {
                    DisclosureGroup {
                        FanDiagram(report: report).padding(.vertical, 6)
                    } label: {
                        Label("How it fanned out — \(angleCount) angle\(angleCount == 1 ? "" : "s")\(rounds > 1 ? " · \(rounds) rounds" : "")",
                              systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.callout.weight(.medium))
                    }
                }
            }

            ForEach(Array(report.entries.filter { $0.isSynthesis != true }.enumerated()), id: \.offset) { _, e in
                Section {
                    if e.notePath != nil || e.sessionID != nil {
                        NavigationLink(value: target(for: e)) { entryCard(e) }
                    } else {
                        entryCard(e)
                    }
                }
            }

            Section {
                HStack {
                    Label(Reporter.fmtDuration(report.totalDurationSeconds), systemImage: "clock")
                    Spacer()
                    Label(money(report.totalCostUSD) + " / " + money(report.runSpendCapUSD),
                          systemImage: report.stayedUnderCap ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(report.stayedUnderCap ? .green : .orange)
                }.font(.callout)
                if rounds > 1 {
                    Label("\(rounds) rounds — deepened on each round's unresolved conflicts & gaps", systemImage: "arrow.trianglehead.clockwise")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .readableColumn()
    }

    private func target(for e: RunReport.TopicEntry) -> TopicTarget {
        TopicTarget(question: e.question, notePath: e.notePath, sessionID: e.sessionID,
                    projectPath: projectPath, isSynthesis: e.isSynthesis == true, status: e.status,
                    headline: e.headline, confidenceSummary: e.confidenceSummary,
                    sourcesConsulted: e.sourcesConsulted, conflicts: e.conflicts ?? [],
                    gaps: e.gaps ?? [], sources: e.sources ?? [], caveat: e.note,
                    angleCount: report.entries.filter { $0.isSynthesis != true && $0.status != .skipped }.count,
                    rounds: report.entries.compactMap(\.round).max() ?? 1)
    }

    @ViewBuilder private func answerHeader(_ e: RunReport.TopicEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusBadge(status: e.status)
                Label("Synthesis", systemImage: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Text(e.question).font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            if e.status != .skipped {
                Text(e.headline).font(.title3).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Label(e.confidenceSummary, systemImage: "checkmark.shield")
                    if let c = e.conflicts, !c.isEmpty {
                        Label("\(c.count) conflict\(c.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if let g = e.gaps, !g.isEmpty {
                        Label("\(g.count) gap\(g.count == 1 ? "" : "s")", systemImage: "questionmark.diamond.fill")
                            .foregroundStyle(.orange)
                    }
                    Label("\(e.sourcesConsulted) source\(e.sourcesConsulted == 1 ? "" : "s")", systemImage: "link")
                }
                .font(.caption).foregroundStyle(.secondary)
                Label("Full synthesis, sources & citation check", systemImage: "arrow.right")
                    .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func entryCard(_ e: RunReport.TopicEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StatusBadge(status: e.status)
                if e.isSynthesis == true {
                    Label("Synthesis", systemImage: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text(e.preset.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Text(e.question).font(.headline)
            if e.status != .skipped {
                Text(e.headline).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Label(e.confidenceSummary, systemImage: "checkmark.shield")
                    Label("\(e.sourcesConsulted) sources", systemImage: "link")
                    Label(money(e.costUSD), systemImage: "dollarsign.circle")
                    Label(Reporter.fmtDuration(e.durationSeconds), systemImage: "clock")
                }
                .font(.caption).foregroundStyle(.secondary)
                if let a = e.noteAction {
                    Label(a.digestLabel, systemImage: a == .extended ? "arrow.triangle.merge" : "doc.badge.plus")
                        .font(.caption).foregroundStyle(a == .extended ? Color.accentColor : .secondary)
                }
            }
            if let note = e.note { Text(note).font(.caption).italic().foregroundStyle(.secondary) }
            if let rl = e.rateLimit {
                Label(rl, systemImage: "gauge.medium")
                    .font(.caption2)
                    .foregroundStyle(rl.contains("allowed") && !rl.contains("warning") ? Color.secondary : Color.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func money(_ d: Decimal) -> String { Reporter.money(d) }
}

/// One topic in place on the right pane: its formatted writeup and a chat that continues the topic's
/// own research session, plus a one-click hand-off to the real Claude Code CLI.
struct TopicDetailView: View {
    let target: TopicTarget
    @State private var tab: Tab
    @State private var chat: ChatModel?
    @State private var exploring: URL?   // tapped source → in-app right inspector, matching the live feed
    enum Tab { case summary, writeup, chat }

    init(target: TopicTarget) {
        self.target = target
        // Synthesis rows default to the "what was done / verified" summary; others to the note.
        _tab = State(initialValue: target.isSynthesis ? .summary : (target.notePath != nil ? .writeup : .chat))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                if target.isSynthesis { Text("Summary").tag(Tab.summary) }
                if target.notePath != nil { Text("Note").tag(Tab.writeup) }
                Text("Chat").tag(Tab.chat)
            }
            .pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top])

            Divider().padding(.top, 8)

            Group {
                if tab == .summary {
                    ScrollView { SynthesisSummary(target: target) { exploring = $0 }.padding(24) }
                } else if tab == .writeup, let path = target.notePath {
                    MarkdownFileEditor(path: path)
                } else if let chat {
                    ChatView(chat: chat)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(target.question)
        .inspector(isPresented: Binding(get: { exploring != nil }, set: { if !$0 { exploring = nil } })) {
            SourceInspector(url: exploring) { exploring = nil }
                .inspectorColumnWidth(min: 320, ideal: 460, max: 900)
        }
        .toolbar {
            if target.sessionID != nil {
                Button {
                    ClaudeCodeLauncher.openTerminal(projectPath: target.projectPath, resumeSessionID: target.sessionID)
                } label: { Label("Continue in Claude Code", systemImage: "terminal") }
                .help("Open this topic’s session in Terminal to keep going interactively")
                Button {
                    ClaudeCodeLauncher.openTerminal(projectPath: target.projectPath, resumeSessionID: target.sessionID, fork: true)
                } label: { Label("Fork", systemImage: "arrow.triangle.branch") }
                .help("Fork this session into a new Terminal — branches off the same history and diverges independently; open as many as you want")
            }
            if let path = target.notePath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: { Label("Reveal", systemImage: "folder") }
            }
        }
        .task {
            if chat == nil {
                chat = ChatModel(projectURL: URL(fileURLWithPath: target.projectPath, isDirectory: true),
                                 resumeSessionID: target.sessionID, model: .stored("chatModel"))
            }
        }
    }
}

/// Read-only note preview (engine-rendered, syntax-highlighted) for sheets — the health-check and Ask
/// note peeks. The editable path is `MarkdownFileEditor` (the Notes sidebar + a run's Note tab).
struct WriteupContent: View {
    let path: String
    @State private var text = ""
    var body: some View {
        MarkdownView(markdown: text, documentId: path)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "Couldn’t read the note." }
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
                labeled("Confidence", target.confidenceSummary.isEmpty ? "—" : target.confidenceSummary)
                labeled("Sources consulted", "\(target.sourcesConsulted)")
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
                    Text("Open the Note tab's “Citation check” section for the specific URLs.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Every cited source was consulted by at least one angle — no untraceable citations.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if !target.sources.isEmpty {
                section("Sources", icon: "link") {
                    ForEach(target.sources.prefix(25), id: \.self) { s in sourceLink(s) }
                    if target.sources.count > 25 {
                        Text("+ \(target.sources.count - 25) more — see the Note tab").font(.caption).foregroundStyle(.secondary)
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
        Text(status.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        switch status {
        case .complete: return .green
        case .inconclusive: return .yellow
        case .haltedSpend, .haltedTime, .haltedManual, .error: return .red
        case .skipped: return .purple
        default: return .secondary
        }
    }
}

private func prettyRunName(_ url: URL) -> String {
    let name = url.lastPathComponent
    let inFmt = DateFormatter(); inFmt.dateFormat = "yyyy-MM-dd-HHmmss"; inFmt.locale = Locale(identifier: "en_US_POSIX")
    guard let date = inFmt.date(from: RunFolder.stamp(name)) else { return name }
    let out = DateFormatter(); out.dateStyle = .medium; out.timeStyle = .short
    return out.string(from: date)
}

// MARK: - Fan-out ("explore every angle") — radial visualization

/// One question fanning out to N blind parallel agents and converging on a synthesis. Drives all four
/// phases: planning spinner → editable review → the live radial fan (research + synthesis).
struct FanOutView: View {
    @Bindable var model: AppModel
    let run: LiveRun
    private var state: FanOutState { run.fanOut }   // read-only alias so `state.xxx` reads stay unchanged
    @State private var detail: AngleState?   // tapped angle node → its live stream in a sheet
    @State private var synthesisOpen = false  // tapped synthesis node → its live stream
    @State private var shown = false          // staggers the nodes in, so the fan "draws out"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch state.phase {
                case .planning:                              planning
                case .awaitingApproval:                      review
                case .researching, .synthesizing, .verifying: researchingBody
                case .done:                                  ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $detail) { a in angleSheet(a.id) }
        .sheet(isPresented: $synthesisOpen) {
            LiveView(progress: "synthesis", live: run.synthesisLive) { synthesisOpen = false }
                .frame(minWidth: 720, idealWidth: 1040, minHeight: 560, idealHeight: 720)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if state.phase != .awaitingApproval { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 1) {
                Text(state.question).font(.headline).lineLimit(2)
                Text(phaseLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Draft (planning / awaiting approval) → discard; a launched research run → stop.
            if state.phase == .planning || state.phase == .awaitingApproval {
                Button("Discard") { model.discardDraft() }
            } else {
                Button(role: .destructive) { model.stop(run) } label: { Label("Stop", systemImage: "stop.fill") }
            }
        }
        .padding()
    }

    private var phaseLabel: String {
        switch state.phase {
        case .planning:         return "decomposing into \(state.count) angles…"
        case .awaitingApproval: return "\(state.angles.count) angles — review, edit, then research"
        case .researching:
            let spent = run.liveByAngle.values.reduce(Decimal(0)) { $0 + $1.costUSD }
            let roundPart = state.round > 1 ? "round \(state.round) · " : ""
            let running = state.roundAngleCounts.last ?? state.angles.count
            return "\(roundPart)\(running) blind agents in parallel · \(money(spent))"
        case .synthesizing:     return "one agent reconciling all findings…"
        case .verifying:        return "checking every citation traces to a source…"
        case .done:             return "done"
        }
    }

    private var planning: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Decomposing your question into \(state.count) angles…", systemImage: "sparkles")
                        .font(.headline).foregroundStyle(.secondary)
                    let live = run.planningLive
                    let titles = streamingTitles(live.output)
                    if !titles.isEmpty {   // the angles as they form — never the raw JSON
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "\(min(i + 1, 50)).circle.fill").foregroundStyle(Color.accentColor)
                                    Text(t).font(.callout.weight(.medium))
                                }
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                        }
                        .animation(.spring(duration: 0.4), value: titles.count)
                    }
                    if !live.thinking.isEmpty {   // reasoning trace, subtle
                        Text(live.thinking)
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if titles.isEmpty && live.thinking.isEmpty {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("thinking…").foregroundStyle(.secondary) }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: run.planningLive.output) { _, _ in
                withAnimation(.easeOut) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    /// Angle titles pulled from the planner's streaming JSON, so they appear (formatted) as they form —
    /// the raw JSON is never shown. Escaped quotes handled; a half-streamed title just doesn't match yet.
    private func streamingTitles(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "\"title\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"") else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > 1 else { return nil }
            return ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: " ")
        }
    }

    @ViewBuilder private var review: some View {
        if state.angles.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t plan angles", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The planner didn’t return usable angles. Try again, or discard and rephrase your question.")
            } actions: {
                Button("Try again") { model.planDeepDive(state.question, count: state.count) }
                    .buttonStyle(.borderedProminent)
                Button("Discard") { model.discardDraft() }
            }
        } else {
            List {
                Section {
                    Text("Here’s how Quorum will explore your question. Edit any angle, drop the ones you don’t need, or add your own. Nothing runs — and nothing is charged — until you start.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("The \(state.angles.count) angles") {
                    ForEach(Array(state.angles.enumerated()), id: \.element.id) { i, a in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("\(i + 1)")
                                    .font(.caption.bold()).foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Color.accentColor, in: Circle())
                                TextField("Angle title", text: angleBinding(a.id, \.title)).font(.headline)
                                Button {
                                    ClaudeCodeLauncher.forkAngle(projectPath: model.projectURL?.path ?? NSHomeDirectory(),
                                                                 prompt: a.angle.prompt)
                                } label: {
                                    Image(systemName: "arrow.branch")
                                }.buttonStyle(.borderless)
                                    .help("Fork this angle into an interactive Claude Code session in Terminal")
                                    .disabled(a.angle.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button(role: .destructive) {
                                    run.fanOut.angles.removeAll { $0.id == a.id }
                                } label: {
                                    Image(systemName: "trash")
                                }.buttonStyle(.borderless).help("Remove this angle")
                            }
                            TextField("What should this angle investigate?",
                                      text: angleBinding(a.id, \.prompt), axis: .vertical)
                                .font(.callout).foregroundStyle(.secondary).lineLimit(2...6)
                                .padding(8)
                                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .padding(.vertical, 4)
                    }
                    Button {
                        run.fanOut.angles.append(AngleState(angle: ResearchAngle(title: "New angle", prompt: "")))
                    } label: { Label("Add an angle", systemImage: "plus.circle.fill") }
                }
                Section {
                    Button { model.startDeepDive() } label: {
                        Label("Research all \(state.angles.count) angles", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(state.angles.contains { $0.angle.prompt.trimmingCharacters(in: .whitespaces).isEmpty })
                    Text("Runs \(state.angles.count) agents in parallel, then merges their findings into one note. This is when spending starts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .readableColumn()
        }
    }

    /// The live fan plus, once the dive has iterated, a strip showing the rounds growing (R1 → R2 → …).
    private var researchingBody: some View {
        VStack(spacing: 0) {
            if state.round > 1 || state.roundAngleCounts.count > 1 {
                roundStrip
                Divider()
            }
            radialFan
        }
    }

    /// Rounds as they accumulate — the research visibly growing: each follow-up round chases the prior
    /// synthesis's unresolved conflicts & gaps. The current round is highlighted.
    private var roundStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.trianglehead.clockwise").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(state.roundAngleCounts.enumerated()), id: \.offset) { i, count in
                let r = i + 1
                HStack(spacing: 4) {
                    Text("R\(r)").font(.caption2.weight(.bold))
                    Text("\(count) angle\(count == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((r == state.round ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(r == state.round ? 0.6 : 0)))
                if r < state.roundAngleCounts.count {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 6)
        .animation(.easeOut(duration: 0.3), value: state.roundAngleCounts)
    }

    private var radialFan: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let top = CGPoint(x: w / 2, y: 70)
            let bottom = CGPoint(x: w / 2, y: h - 70)
            let n = max(state.angles.count, 1)
            let slot = w / CGFloat(n + 1)
            // Node is 176 wide; when the row can't give each that much (many angles / narrow window)
            // the boxes collide. Zig-zag onto two bands so neighbours clear vertically instead.
            // ponytail: two bands cover the 2…8 angles the stepper allows; add a 3rd if that cap grows.
            let band: CGFloat = slot < 192 ? 66 : 0   // 176 node + 16 gap
            let pos = state.angles.indices.map {
                CGPoint(x: slot * CGFloat($0 + 1), y: h / 2 + ($0.isMultiple(of: 2) ? -band : band))
            }
            ZStack {
                ForEach(state.angles.indices, id: \.self) { i in
                    curvePath(top, pos[i]).stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                    curvePath(pos[i], bottom).stroke(
                        Color.accentColor.opacity(state.angles[i].status == .complete ? 0.6 : 0.12),
                        style: StrokeStyle(lineWidth: 1.5, dash: state.phase == .synthesizing ? [] : [4]))
                        .opacity(shown ? 1 : 0)
                }
                // Each angle's consulted sources hang below it as a short, dimmed column of small nodes,
                // nudged to the outward side so their connectors diverge from the (inward-curving) synthesis
                // line instead of lying on top of it. ponytail: only in the uncrowded single row (band == 0);
                // crowded runs keep the "N src" count on the node.
                if band == 0 {
                    ForEach(state.angles.indices, id: \.self) { i in
                        let dx: CGFloat = pos[i].x <= w / 2 ? -40 : 40
                        let sats = satellitePositions(for: state.angles[i], at: pos[i], dx: dx)
                        ForEach(sats.indices, id: \.self) { j in
                            Path { $0.move(to: pos[i]); $0.addLine(to: sats[j]) }
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1).opacity(shown ? 1 : 0)
                        }
                    }
                }
                questionNode.position(top)
                ForEach(Array(state.angles.enumerated()), id: \.element.id) { i, a in
                    angleNode(a)
                        .scaleEffect(shown ? 1 : 0.1).opacity(shown ? 1 : 0)
                        .animation(.spring(duration: 0.5).delay(Double(i) * 0.08), value: shown)
                        .position(pos[i])
                        .onTapGesture { detail = a }
                }
                if band == 0 {
                    ForEach(state.angles.indices, id: \.self) { i in
                        let dx: CGFloat = pos[i].x <= w / 2 ? -40 : 40
                        satelliteNodes(for: state.angles[i], at: pos[i], dx: dx, delay: Double(i))
                    }
                }
                synthesisNode.position(bottom)
                    .scaleEffect(shown ? 1 : 0.1).opacity(shown ? 1 : 0)
                    .animation(.spring(duration: 0.5).delay(Double(n) * 0.08), value: shown)
            }
            .padding()
            .onAppear { shown = true }
        }
    }

    private var questionNode: some View {
        Text(state.question)
            .font(.subheadline.weight(.semibold)).lineLimit(3).multilineTextAlignment(.center)
            .padding(10).frame(width: 190)
            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.5)))
    }

    private func angleNode(_ a: AngleState) -> some View {
        let live = run.liveByAngle[a.id]
        let trace = liveTrace(live)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                statusIcon(a.status)
                Text(a.angle.title.isEmpty ? "Angle" : a.angle.title)
                    .font(.caption.weight(.semibold)).lineLimit(2)
            }
            if let live, live.costUSD > 0 || !live.sources.isEmpty {
                Text("\(live.sources.count) src · \(money(live.costUSD))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !trace.isEmpty {   // live trace of what this agent is doing right now (max 2 lines)
                Text(trace).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(9).frame(width: 176, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(nodeColor(a.status).opacity(0.5)))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }

    // MARK: source satellites — an angle's consulted sources as small nodes fanned above it

    private let satCap = 3   // beyond this the last slot is a "+N" node; the full list is in the angle's sheet

    /// A short vertical column of source-node positions hanging below the angle, offset by `dx` toward the
    /// outward side. Vertical + capped so same-angle chips never overlap; the ≥1-slot gap between angles and
    /// the modest `dx` keep neighbouring columns clear too.
    /// ponytail: on a very short window the deepest chip can approach the synthesis node — cap/step are the knobs.
    private func satellitePositions(for a: AngleState, at center: CGPoint, dx: CGFloat) -> [CGPoint] {
        let total = run.liveByAngle[a.id]?.sources.count ?? 0
        let count = min(total, satCap) + (total > satCap ? 1 : 0)
        guard count > 0 else { return [] }
        let base = 60.0, step = 22.0   // base clears a tall (researching) node; step ≥ chip height
        return (0..<count).map { j in
            CGPoint(x: center.x + dx, y: center.y + CGFloat(base + Double(j) * step))
        }
    }

    @ViewBuilder private func satelliteNodes(for a: AngleState, at center: CGPoint, dx: CGFloat, delay: Double) -> some View {
        let srcs = run.liveByAngle[a.id]?.sources ?? []
        let positions = satellitePositions(for: a, at: center, dx: dx)
        ForEach(positions.indices, id: \.self) { j in
            let overflow = srcs.count > satCap && j == satCap
            sourceSatellite(source: overflow ? nil : srcs[j], overflow: overflow ? srcs.count - satCap : 0)
                .position(positions[j])
                .scaleEffect(shown ? 1 : 0.1).opacity(shown ? 0.55 : 0)   // dimmed — sources recede behind the angles
                .animation(.spring(duration: 0.4).delay(delay * 0.08 + 0.12), value: shown)
        }
    }

    @ViewBuilder private func sourceSatellite(source: LiveSource?, overflow: Int) -> some View {
        if let source {
            HStack(spacing: 4) {
                Image(systemName: sourceIcon(source)).font(.caption2)
                Text(satelliteLabel(source)).font(.caption2).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .frame(maxWidth: 112)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            .help(source.value)
        } else {
            Text("+\(overflow)")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        }
    }

    private func satelliteLabel(_ s: LiveSource) -> String {
        if s.isURL, let host = URL(string: s.value)?.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if s.value.contains("/") { return (s.value as NSString).lastPathComponent }   // file path → basename
        return s.value
    }

    /// The tail of an agent's live thinking/output, newlines flattened — a 2-line "what it's doing now".
    private func liveTrace(_ live: LiveSnapshot?) -> String {
        let raw = (live?.output.isEmpty == false ? live?.output : live?.thinking) ?? ""
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        let tail = s.count > 140 ? "…" + String(s.suffix(140)) : s
        return tail.replacingOccurrences(of: "\n", with: " ")
    }

    private var synthesisNode: some View {
        let verifying = state.phase == .verifying
        let active = state.phase == .synthesizing || verifying
        let live = run.synthesisLive
        let trace = active ? liveTrace(live) : ""
        let statusText: String = verifying ? "checking citations…"
            : (active ? (live.output.isEmpty ? "reconciling…" : "writing…") : "waits for all angles")
        return HStack(alignment: .top, spacing: 7) {
            if active { ProgressView().controlSize(.mini) }
            else { Image(systemName: "sparkles").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Synthesis").font(.caption.weight(.semibold))
                Text(statusText)
                    .font(.caption2).foregroundStyle(.secondary)
                if active && (live.costUSD > 0 || !live.sources.isEmpty) {
                    Text("\(live.sources.count) src · \(money(live.costUSD))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !trace.isEmpty {   // live trace (max 2 lines)
                    Text(trace).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
        }
        .padding(10).frame(width: 240, alignment: .leading)
        .background((active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1)),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(active ? 0.6 : 0.25)))
        .contentShape(Rectangle())
        .onTapGesture { if active { synthesisOpen = true } }
    }

    private func angleSheet(_ id: String) -> some View {
        let snap = run.liveByAngle[id] ?? LiveSnapshot()
        return LiveView(progress: state.angles.first { $0.id == id }?.status.label, live: snap) { detail = nil }
            .frame(minWidth: 720, idealWidth: 1040, minHeight: 560, idealHeight: 720)
    }

    // MARK: helpers

    private func angleBinding(_ id: String, _ kp: WritableKeyPath<ResearchAngle, String>) -> Binding<String> {
        Binding(
            get: { run.fanOut.angles.first { $0.id == id }?.angle[keyPath: kp] ?? "" },
            set: { newVal in
                guard let i = run.fanOut.angles.firstIndex(where: { $0.id == id }) else { return }
                run.fanOut.angles[i].angle[keyPath: kp] = newVal
            })
    }

    @ViewBuilder private func statusIcon(_ s: TopicStatus) -> some View {
        switch s {
        case .running:      ProgressView().controlSize(.mini)
        case .complete:     Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .inconclusive: Image(systemName: "questionmark.circle.fill").foregroundStyle(.yellow)
        case .haltedSpend, .haltedTime, .haltedManual, .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        default:            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private func nodeColor(_ s: TopicStatus) -> Color {
        switch s {
        case .complete: return .green
        case .running:  return .accentColor
        case .haltedSpend, .haltedTime, .haltedManual, .error: return .red
        default:        return .secondary
        }
    }

    private func money(_ d: Decimal) -> String { Reporter.money(d) }
}

/// A curved connector between two nodes in the fan (S-curve via vertical control points).
private func curvePath(_ a: CGPoint, _ b: CGPoint) -> Path {
    var p = Path()
    p.move(to: a)
    let midY = (a.y + b.y) / 2
    p.addCurve(to: b, control1: CGPoint(x: a.x, y: midY), control2: CGPoint(x: b.x, y: midY))
    return p
}

// MARK: - Layout

extension View {
    /// Constrain content to a centered, readable-width column instead of letting lines run the full
    /// width of a wide window. HIG: restrict text width (~50–75 characters) for readability.
    func readableColumn(_ maxWidth: CGFloat = 640) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }
}

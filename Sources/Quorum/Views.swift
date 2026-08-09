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
    @State private var showSavedToast = false   // brief "Saved to Keepers" confirmation after ⌘⇧K

    // A run is identified by its stable trailing timestamp, not its URL, so selection survives the
    // folder being renamed when the run gets its auto-title.
    enum Panel: Hashable { case compose, ask, lint, keepers, note(String), run(String) }

    private var sidebar: some View {
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
                    Label("Keepers", systemImage: "bookmark")
                        .badge(model.keepers.count)
                        .tag(Panel.keepers)
                }
                Section("Chats") {
                    ForEach(model.runs, id: \.self) { run in
                        historyRow(run)
                            .tag(Panel.run(RunFolder.stamp(run.lastPathComponent)))
                            .contextMenu {
                                let stamp = RunFolder.stamp(run.lastPathComponent)
                                Button {
                                    Task { await model.regenerateRunTitle(run) }
                                } label: {
                                    Label("Regenerate Title", systemImage: "arrow.clockwise")
                                }
                                .disabled(model.isRunning(stamp))
                                if AppEnv.isDev {
                                    Button("Replay") { model.replay(run) }   // demo recording
                                }
                                Button("Move to Trash", role: .destructive) { deleteRun(run) }
                            }
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
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .compose: ComposeView(model: model)
        case .ask: AskView(model: model).id(model.projectURL)
        case .lint: LintView(model: model).id(model.projectURL)
        case .keepers: KeepersView(model: model, onOpenNote: { selection = .note($0) },
                                   onResearch: { model.discardDraft(); model.composePrefill = $0; selection = .compose }).id(model.projectURL)
        case .note(let path): NoteEditorView(path: path, model: model, onDelete: deleteNote).id(path)
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

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Quorum")
        .overlay(alignment: .bottom) { savedToast }
        .onChange(of: model.keeperSavedTick) { _, _ in flashSavedToast() }
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
            SelectionSaveController.shared.model = model
            model.restoreLastProject()
        }
        // Keep the floating Save button's link target in step with what's on screen (a sidebar note here;
        // a run's writeup sets it from TopicDetailView). Non-note panels clear it, so no stray bubble.
        .onChange(of: selection) { _, sel in
            if case .note(let path) = sel { model.currentNotePath = path } else { model.currentNotePath = nil }
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

    /// Everything the ⌘K switcher can jump to: the fixed commands (New run / Ask / Health check / project
    /// picking — Ask & Health check live here now that they're off the sidebar), then recent projects,
    /// past chats, and every note. Order here is the pre-typing order; `QuickSwitch` re-ranks as you type.
    @ViewBuilder private var savedToast: some View {
        if showSavedToast {
            Label("Saved to Keepers", systemImage: "bookmark.fill")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
                .shadow(radius: 12, y: 4)
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func flashSavedToast() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showSavedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.25)) { showSavedToast = false }
        }
    }

    private func quickSwitchItems() -> [QuickSwitchItem] {
        var items: [QuickSwitchItem] = [
            QuickSwitchItem(id: "cmd.compose", title: "New run", subtitle: "Command",
                            systemImage: "point.3.connected.trianglepath.dotted") { selection = .compose },
            QuickSwitchItem(id: "cmd.ask", title: "Ask your brain", subtitle: "Command",
                            systemImage: "sparkle.magnifyingglass") { selection = .ask },
            QuickSwitchItem(id: "cmd.lint", title: "Health check", subtitle: "Command",
                            systemImage: "stethoscope") { selection = .lint },
            QuickSwitchItem(id: "cmd.keepers", title: "Keepers", subtitle: "Command",
                            systemImage: "bookmark") { selection = .keepers },
            QuickSwitchItem(id: "cmd.project", title: "Choose Project…", subtitle: "Command",
                            systemImage: "folder.badge.plus") { model.chooseProject(); selection = .compose },
        ]
        if !model.activeRuns.isEmpty {
            items.append(QuickSwitchItem(id: "cmd.stopall", title: "Stop all runs", subtitle: "Command",
                                         systemImage: "stop.fill") { model.stopAll() })
        }
        for proj in model.recentProjects where proj != model.projectURL {
            items.append(QuickSwitchItem(id: "proj." + proj.path, title: proj.lastPathComponent,
                                         subtitle: "Recent project", systemImage: "folder") {
                model.openProject(proj); selection = .compose
            })
        }
        for run in model.runs {
            let stamp = RunFolder.stamp(run.lastPathComponent)
            items.append(QuickSwitchItem(id: "run." + stamp, title: model.runTitle(for: run) ?? prettyRunName(run),
                                         subtitle: "Chat", systemImage: "doc.text") { selection = .run(stamp) })
        }
        for note in flattenNotes(model.noteTree) {
            items.append(QuickSwitchItem(id: "note." + note.url.path, title: note.name,
                                         subtitle: "Note", systemImage: "doc.plaintext") {
                selection = .note(note.url.path)
            })
        }
        return items
    }

    private func flattenNotes(_ nodes: [NoteTreeNode]) -> [NoteTreeNode] {
        nodes.flatMap { node in node.childrenOrNil.map(flattenNotes) ?? [node] }
    }

    /// Move a chat's run folder to the Trash (reversible): cancel it first if it's still researching so it
    /// stops writing to the trashed folder, then leave its detail pane if it was the one showing.
    private func deleteRun(_ url: URL) {
        let stamp = RunFolder.stamp(url.lastPathComponent)
        if let live = model.activeRuns[stamp] { model.stop(live); model.activeRuns[stamp] = nil }
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { return }
        if case .run(let s) = selection, s == stamp { selection = .compose }
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
    @AppStorage("synthesisModel") private var synthesisModel: ModelChoice = .default
    @AppStorage("runProfile") private var runProfile: RunProfile = .subscription

    var body: some View {
        content
            .animation(.easeInOut(duration: 0.25), value: model.draftRun?.id)
            .onChange(of: model.perTopicTimeoutMinutes) { _, _ in model.saveState() }
            .onChange(of: model.defaultPreset) { _, _ in model.saveState() }
            .onChange(of: model.synthesisTemplate) { _, _ in model.saveState() }
            .onChange(of: model.useProjectContext) { _, _ in model.saveState() }
            .onChange(of: model.autoresearch) { _, _ in model.saveState() }
            // Demo replay staged a question — seed the ask box as if it were just typed.
            .onChange(of: model.composePrefill) { _, v in applyPrefill(v) }
            .onAppear { applyPrefill(model.composePrefill) }
    }

    /// Seed the ask box (and angle count) from a staged demo replay, then clear the one-shot.
    private func applyPrefill(_ value: String?) {
        guard let value else { return }
        deepQuestion = value
        if let n = model.pendingReplay?.round1Count { angleCount = max(2, min(8, n)) }
        model.composePrefill = nil
        questionFocused = true
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
            }
            .padding(28)
            .readableColumn()
        }
        .onAppear { questionFocused = true }   // cursor ready in the ask box on open
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
                Toggle(isOn: $model.autoresearch) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Autoresearch")
                        Text("Keep digging in deeper rounds until the answer is concrete — or the run spend cap is hit.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if AppEnv.isDev {
                    Toggle(isOn: $model.mockTSCore) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Mock TS core (dev)")
                            Text("Drive the next run from a canned engine transcript — the real new-core pipeline, no binary, no keys, no spend.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
                Picker("Chat", selection: $chatModel) {
                    ForEach(ModelChoice.allCases, id: \.self) { Text($0.menuLabel).tag($0) }
                }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label("Run settings", systemImage: "gearshape")
                let profilePrefix = runProfile == .subscription ? "" : "\(runProfile.displayName) · "
                let angleModelName = runProfile == .codex
                    ? EngineKeys.configuredCodexAngleModel().displayName : agentModel.displayName
                Text("\(profilePrefix)\(model.defaultPreset.displayName) · \(angleModelName) agents\(model.useProjectContext ? " · reads project" : "")\(model.autoresearch ? " · autoresearch" : "")")
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
                ForEach([RunProfile.subscription, .codex, .budget, .fullBYOK]) { p in
                    let avail = p.availability(hasModelKey: hasModel, hasSearchKey: hasSearch, hasCodexCLI: hasCodex)
                    Button {
                        runProfile = p
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
    var wasEngineRun = false   // ran on the BYOK engine → chat reopens fresh + seeded, not --resume (R8)
    var evidence: EvidenceContext? = nil   // captured sources + resolved quotes → the cited reader (PRD 03); nil for a legacy run
}

extension TopicTarget {
    static func from(_ e: RunReport.TopicEntry, report: RunReport, projectPath: String) -> TopicTarget {
        TopicTarget(question: e.question, notePath: e.notePath, sessionID: e.sessionID,
                    projectPath: projectPath, isSynthesis: e.isSynthesis == true, status: e.status,
                    headline: e.headline, confidenceSummary: e.confidenceSummary,
                    sourcesConsulted: e.sourcesConsulted, conflicts: e.conflicts ?? [],
                    gaps: e.gaps ?? [], sources: e.sources ?? [], caveat: e.note,
                    angleCount: report.entries.filter { $0.isSynthesis != true && $0.status != .skipped }.count,
                    rounds: report.entries.compactMap(\.round).max() ?? 1,
                    wasEngineRun: e.wasEngineRun,
                    evidence: EvidenceContext.make(e, report: report))
    }
}

struct RunDetailView: View {
    let model: AppModel
    let runDir: URL
    @State private var showSummary = false

    var body: some View {
        let report = model.loadReport(runDir)
        let projectPath = model.projectURL?.path ?? runDir.deletingLastPathComponent().deletingLastPathComponent().path
        let summary = report.flatMap { r in r.entries.first { $0.isSynthesis == true }.map { TopicTarget.from($0, report: r, projectPath: projectPath) } }
        return NavigationStack {
            Group {
                if let report {
                    DigestView(report: report, projectPath: projectPath)
                } else {
                    ContentUnavailableView("Couldn’t load this run", systemImage: "questionmark.folder",
                                           description: Text(runDir.path))
                }
            }
            .navigationDestination(for: TopicTarget.self) {
                TopicDetailView(target: $0, model: model, showSummary: $showSummary, summary: summary)
            }
        }
        .navigationTitle(prettyRunName(runDir))
        .toolbar {
            // Dev-only: re-stream this finished run live through the fan-out viz — for demo recording.
            if AppEnv.isDev {
                Button { model.replay(runDir) } label: { Label("Replay", systemImage: "play.circle") }
                    .help("Replay this run live — for a demo recording")
            }
        }
    }
}

/// A static fan-out diagram rebuilt from a finished run's report, so the shape of the research is visible
/// in History too — not only in the live radial fan during processing. Question at the top → each
/// iterative round's angles as a row (the research is seen to GROW round over round) → the synthesis at
/// the bottom, badged with how many conflicts/gaps it surfaced.
struct FanDiagram: View {
    let report: RunReport
    let makeTarget: (RunReport.TopicEntry) -> TopicTarget

    private var synthesis: RunReport.TopicEntry? { report.entries.first { $0.isSynthesis == true } }
    private var rounds: [(round: Int, angles: [RunReport.TopicEntry])] {
        let angles = report.entries.filter { $0.isSynthesis != true && $0.status != .skipped }
        let groups = Dictionary(grouping: angles) { $0.round ?? 1 }
        return groups.keys.sorted().map { (round: $0, angles: groups[$0] ?? []) }
    }
    private var questionText: String { synthesis?.question ?? rounds.first?.angles.first?.question ?? "Question" }
    private var totalSources: Int {
        report.entries.filter { $0.isSynthesis != true }.reduce(0) { $0 + $1.sourcesConsulted }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            card(questionText, kind: .question)
            ForEach(rounds, id: \.round) { r in
                connector()
                roundLabel(r.round)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) { ForEach(r.angles, id: \.id) { angleChip($0) } }
                        .padding(.horizontal, 2).padding(.bottom, 4)
                }
            }
            connector()
            if let s = synthesis { synthesisNode(s) }
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Research shape", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(rounds.count) round\(rounds.count == 1 ? "" : "s") · \(report.entries.filter { $0.isSynthesis != true && $0.status != .skipped }.count) angles · \(totalSources) sources consulted")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            legend
        }
        .padding(.horizontal, 4)
    }

    private var legend: some View {
        HStack(spacing: 6) {
            legendItem("Question", tint: .accentColor.opacity(0.16), stroke: .accentColor.opacity(0.45))
            legendItem("Angle", tint: .secondary.opacity(0.10), stroke: .secondary.opacity(0.28))
            legendItem("Synthesis", tint: .accentColor.opacity(0.14), stroke: .accentColor.opacity(0.45))
            legendItem("Verify", tint: Color.green.opacity(0.10), stroke: Color.green.opacity(0.35))
        }
    }

    private func legendItem(_ text: String, tint: Color, stroke: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint, in: Capsule())
            .overlay(Capsule().strokeBorder(stroke))
    }

    private func connector(height: CGFloat = 12) -> some View {
        Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 2, height: height)
    }

    private func roundLabel(_ round: Int) -> some View {
        let count = rounds.first(where: { $0.round == round })?.angles.count ?? 0
        return HStack(spacing: 6) {
            Text("Round \(round)")
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
            Text("\(count) angle\(count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Color.secondary.opacity(0.08), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ text: String, kind: NodeKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: kind.icon)
                Text(kind.label.uppercased())
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(kind.fg)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(kind.badgeFill, in: Capsule())

            Text(text)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .lineLimit(3)
            if kind == .question {
                Text("Entry point for the whole fan-out")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .frame(minHeight: kind == .question ? 96 : 88, alignment: .leading)
        .background(kind.fill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(kind.stroke))
    }

    private func angleChip(_ e: RunReport.TopicEntry) -> some View {
        NavigationLink(value: makeTarget(e)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    statusDot(e.status)
                    Text(e.question)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Text("\(e.sourcesConsulted) src")
                    if !e.confidenceSummary.isEmpty {
                        Text("·")
                        Text(e.confidenceSummary)
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(width: 172, height: 118, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(strokeColor(for: e.status)))
        }
        .buttonStyle(.plain)
    }

    private func synthesisNode(_ e: RunReport.TopicEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("SYNTHESIS")
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12), in: Capsule())

            Text(e.headline)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .lineLimit(3)

            HStack(spacing: 8) {
                detailBadge("\(e.sourcesConsulted) src", systemImage: "link", tint: .secondary)
                if let c = e.conflicts, !c.isEmpty {
                    detailBadge("\(c.count) conflict\(c.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
                if let g = e.gaps, !g.isEmpty {
                    detailBadge("\(g.count) gap\(g.count == 1 ? "" : "s")", systemImage: "questionmark.diamond.fill", tint: .orange)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .frame(minHeight: 96, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.42)))
    }

    private func detailBadge(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.10), in: Capsule())
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

    private func strokeColor(for status: TopicStatus) -> Color {
        switch status {
        case .complete: return Color.green.opacity(0.40)
        case .inconclusive: return Color.yellow.opacity(0.45)
        case .haltedSpend, .haltedTime, .haltedManual, .error: return Color.red.opacity(0.45)
        default: return Color.secondary.opacity(0.30)
        }
    }

    private enum NodeKind {
        case question, angle, synthesis

        var label: String {
            switch self {
            case .question: return "Question"
            case .angle: return "Angle"
            case .synthesis: return "Synthesis"
            }
        }

        var icon: String {
            switch self {
            case .question: return "questionmark.diamond"
            case .angle: return "point.3.connected.trianglepath.dotted"
            case .synthesis: return "sparkles"
            }
        }

        var fg: Color {
            switch self {
            case .question, .synthesis: return .accentColor
            case .angle: return .secondary
            }
        }

        var fill: Color {
            switch self {
            case .question: return .accentColor.opacity(0.14)
            case .angle: return .secondary.opacity(0.10)
            case .synthesis: return .accentColor.opacity(0.12)
            }
        }

        var badgeFill: Color {
            switch self {
            case .question, .synthesis: return .accentColor.opacity(0.10)
            case .angle: return .secondary.opacity(0.08)
            }
        }

        var stroke: Color {
            switch self {
            case .question: return .accentColor.opacity(0.42)
            case .angle: return .secondary.opacity(0.28)
            case .synthesis: return .accentColor.opacity(0.42)
            }
        }
    }
}

struct DigestView: View {
    let report: RunReport
    let projectPath: String
    // Last synthesis wins — the reconciliation (appended after the rounds) is the dive's CURRENT answer;
    // absent one, the final round's synthesis. FanDiagram keeps its own first-match, so the process viz is
    // unchanged (story 17).
    private var synthesis: RunReport.TopicEntry? { report.entries.last { $0.isSynthesis == true } }
    private var angleCount: Int { report.entries.filter { $0.isSynthesis != true && $0.status != .skipped }.count }
    private var isFanOut: Bool { synthesis != nil }
    private var rounds: Int { report.entries.compactMap(\.round).max() ?? 1 }
    @State private var graphOpen = false

    var body: some View {
        List {
            if let s = synthesis {
                Section { NavigationLink(value: target(for: s)) { answerHeader(s) } }
            }

            if isFanOut {
                Section {
                    // Opened in its own window rather than inline: the canvas pans and zooms, and a
                    // scroll view nested in a List row cannot resolve a height, which blanks the digest.
                    Button { graphOpen = true } label: {
                        Label("How the research grew — \(angleCount) angle\(angleCount == 1 ? "" : "s")\(rounds > 1 ? " · \(rounds) rounds" : "")",
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
                if let profile = report.profile, profile != .subscription {
                    Label("\(profile.displayName)\(report.engineCostUSD > 0 ? " · \(money(report.engineCostUSD)) on BYOK engine" : "")",
                          systemImage: "dial.medium")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if rounds > 1 {
                    Label("\(rounds) rounds — deepened on each round's unresolved conflicts & gaps", systemImage: "arrow.trianglehead.clockwise")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .readableColumn()
        .sheet(isPresented: $graphOpen) {
            VStack(spacing: 0) {
                HStack {
                    Label("How the research grew", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("Done") { graphOpen = false }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
                Divider()
                ResearchGraphView(graph: ResearchGraph.from(report: report))
            }
            .frame(minWidth: 900, idealWidth: 1200, minHeight: 600, idealHeight: 780)
        }
    }

    private func target(for e: RunReport.TopicEntry) -> TopicTarget {
        TopicTarget.from(e, report: report, projectPath: projectPath)
    }

    @ViewBuilder private func answerHeader(_ e: RunReport.TopicEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusBadge(status: e.status)
                Label(e.noteAction == .reconciled ? "Reconciled" : "Synthesis",
                      systemImage: e.noteAction == .reconciled ? "arrow.triangle.merge" : "sparkles")
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
    let model: AppModel
    @Binding var showSummary: Bool
    let summary: TopicTarget?   // the run's synthesis overview — shown alongside every view of the run, not just the synthesis
    @State private var tab: Tab
    @State private var chat: ChatModel?
    @State private var exploring: URL?   // tapped source temporarily overrides the summary in the same inspector
    @State private var citation: Citation?   // tapped citation chip → its source, highlighted, in the same inspector
    enum Tab { case note, edit, chat }

    init(target: TopicTarget, model: AppModel, showSummary: Binding<Bool>, summary: TopicTarget?) {
        self.target = target
        self.model = model
        self._showSummary = showSummary
        self.summary = summary
        _tab = State(initialValue: target.notePath != nil ? .note : .chat)
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        let active = tab == value
        return Button { tab = value } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                RoundedRectangle(cornerRadius: 1)
                    .fill(active ? Color.accentColor : .clear)
                    .frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 0) {
            if target.notePath != nil {
                HStack(spacing: 24) {
                    tabButton("Note", .note)
                    if target.evidence != nil { tabButton("Edit", .edit) }
                    tabButton("Chat", .chat)
                }
                .padding(.horizontal, 28).padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().padding(.top, 10)

            Group {
                if tab == .note, let path = target.notePath, let evidence = target.evidence {
                    CitedNoteReader(path: path, evidence: evidence.index, selected: $citation)
                } else if tab != .chat, let path = target.notePath {
                    MarkdownFileEditor(path: path, readingWidth: nil)
                } else if let chat {
                    ChatView(chat: chat)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(target.question)
        .onAppear { model.currentNotePath = target.notePath }
        .onDisappear { if model.currentNotePath == target.notePath { model.currentNotePath = nil } }
        .inspector(isPresented: Binding(get: { citation != nil || (showSummary && summary != nil) },
                                       set: { showSummary = $0; if !$0 { exploring = nil; citation = nil } })) {
            Group {
                if let citation, let evidence = target.evidence {
                    CitedSourceInspector(citation: citation, document: evidence.index.document(for: citation),
                                         evidenceDir: evidence.directory) { self.citation = nil }
                } else if let url = exploring {
                    SourceInspector(url: url) { exploring = nil }
                } else if let summary {
                    ScrollView { SynthesisSummary(target: summary) { exploring = $0 }.padding(20) }
                }
            }
            .inspectorColumnWidth(min: 360, ideal: 420, max: 900)
        }
        .toolbar {
            // Terminal continue/fork rely on `claude --resume`, which only works for CLI sessions —
            // an engine topic's synthetic id isn't resumable, so these are offered for CLI topics only.
            if target.sessionID != nil && !target.wasEngineRun {
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
                Button { model.keepSelection(source: path) } label: { Label("Keep", systemImage: "bookmark") }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .help("Keep the selected text — saved to Keepers, linked back to this note (⌘⇧K)")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: { Label("Reveal", systemImage: "folder") }
            }
            if summary != nil {
                Button { showSummary.toggle(); if !showSummary { exploring = nil } } label: {
                    Label("Summary", systemImage: "sidebar.right")
                }
                .help("Show the run’s synthesis summary alongside this view")
            }
        }
        .task {
            if chat == nil {
                let project = URL(fileURLWithPath: target.projectPath, isDirectory: true)
                // Engine topics can't be --resumed → open a fresh session seeded with the writeup (R8).
                if target.wasEngineRun {
                    chat = ChatModel(projectURL: project, seed: ChatSeed.make(notePath: target.notePath,
                                                                              question: target.question),
                                     model: .stored("chatModel"))
                } else {
                    chat = ChatModel(projectURL: project, resumeSessionID: target.sessionID,
                                     model: .stored("chatModel"))
                }
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

// MARK: - Keepers

/// The dedicated Keepers flow: snippets kept from writeups (⌘C, then ⌘⇧K), newest first, each a card you
/// can copy or delete on hover. Backed by one portable `Quorum/keepers.md`, so the same clips appear when
/// the brain is opened in Obsidian.
struct KeepersView: View {
    @Bindable var model: AppModel
    var onOpenNote: (String) -> Void = { _ in }
    var onResearch: (String) -> Void = { _ in }

    var body: some View {
        Group {
            if model.keepers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.keepers) { keeper in
                            KeeperCard(keeper: keeper, onOpen: onOpenNote, onResearch: onResearch) { model.deleteKeeper($0) }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Keepers")
        .toolbar {
            Button { model.saveClipping() } label: { Label("Add from Clipboard", systemImage: "plus") }
                .help("Save whatever you last copied (⌘⇧K)")
            if let url = model.keepersFileURL, FileManager.default.fileExists(atPath: url.path) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .help("Reveal keepers.md — a plain markdown file that drops into Obsidian")
            }
        }
        .task { model.refreshKeepers() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No keepers yet", systemImage: "bookmark")
        } description: {
            Text("Reading a run’s writeup or a note? Select a great link, sentence, or name — a Save button pops up (or press ⌘⇧K). It’s kept here, linked back to that note.")
        }
    }
}

private struct KeeperCard: View {
    let keeper: Keeper
    var onOpen: (String) -> Void = { _ in }
    var onResearch: (String) -> Void = { _ in }
    let onDelete: (String) -> Void
    @State private var hovering = false

    private var noteName: String {
        URL(fileURLWithPath: keeper.source).deletingPathExtension().lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(keeper.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if !keeper.source.isEmpty {
                    Button { onOpen(keeper.source) } label: {
                        Label(noteName, systemImage: "doc.text").font(.caption).lineLimit(1)
                    }
                    .buttonStyle(.link)
                    .help("Open the research note this came from")
                }
                Spacer(minLength: 8)
                Text(keeper.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.tertiary)
                if hovering {
                    Button { onResearch(keeper.text) } label: {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                    }
                    .buttonStyle(.borderless)
                    .help("Research this further — start a new run seeded from this snippet")
                    if !keeper.source.isEmpty {
                        Button { ClaudeCodeLauncher.openNote(URL(fileURLWithPath: keeper.source)) } label: {
                            Image(systemName: "terminal")
                        }
                        .buttonStyle(.borderless)
                        .help("Dig in with Claude Code — opens this note and the research it links, in context")
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: keeper.source)]) } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless).help("Reveal the source note in Finder")
                    }
                    Button { copy() } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy")
                    Button { onDelete(keeper.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete keeper")
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: hovering ? 1 : 0))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(keeper.text, forType: .string)
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
    @State private var digFrom: GraphNode?    // "research further from here" → the question box
    @State private var shown = false          // staggers the nodes in, so the fan "draws out"
    @State private var reading: Reading = .graph

    enum Reading: String, CaseIterable, Identifiable {
        case graph, trace, fan
        var id: String { rawValue }
        var label: String {
            switch self {
            case .graph: return "Graph"
            case .trace: return "Timeline"
            case .fan:   return "Fan"
            }
        }
        var icon: String {
            switch self {
            case .graph: return "point.3.filled.connected.trianglepath.dotted"
            case .trace: return "chart.bar.xaxis"
            case .fan:   return "point.3.connected.trianglepath.dotted"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch state.phase {
                // Planning happens on the canvas: the question is already a node, and the decomposition
                // streams on it. The run's surface is the same from the first second to the last.
                case .planning:                              planningGraph
                case .awaitingApproval:                      review
                // `.done` keeps the finished fan on screen (all angles green, citations grounded) rather
                // than flashing a spinner — the terminal frame before the run settles to its digest.
                case .researching, .synthesizing, .verifying, .done: researchingBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $detail) { a in angleSheet(a.id) }
        .sheet(isPresented: $synthesisOpen) {
            LiveView(progress: "synthesis", live: run.synthesisLive) { synthesisOpen = false }
                .frame(minWidth: 720, idealWidth: 1040, minHeight: 560, idealHeight: 720)
        }
        .sheet(item: $digFrom) { node in
            DigDownSheet(node: node) { question in
                model.digDown(run: run, from: node, question: question)
                digFrom = nil
            } onCancel: { digFrom = nil }
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

    /// The question as a node, with the planner's reasoning streaming on it. `run.graph` is still empty at
    /// this point — the engine has not spoken — so the root is seeded locally and handed over the moment
    /// the `plan` event arrives.
    private var planningGraph: some View {
        ResearchGraphView(
            graph: run.graph.node(ResearchGraph.rootID) == nil
                ? ResearchGraph.planning(question: state.question, angleCount: state.count)
                : run.graph,
            live: { id in id == ResearchGraph.rootID ? run.planningLive : run.liveByAngle[id] })
    }

    /// Three readings of the same run: the graph (what the run is and what it found — the surface you work
    /// on), the time-lane trace (duration, stalls, where two blind angles met the same source), and the old
    /// fan. The graph leads.
    private var researchingBody: some View {
        VStack(spacing: 0) {
            Picker("", selection: $reading) {
                ForEach(Reading.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.horizontal, 14).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            switch reading {
            case .trace:
                RunTimelineTrace(run: run) { lane in
                    switch lane.role {
                    case .angle:     detail = state.angles.first { $0.id == lane.id }
                    case .synthesis: if state.phase != .researching { synthesisOpen = true }
                    case .verify:    break
                    }
                }
            case .graph:
                ResearchGraphView(
                    graph: run.graph,
                    live: { id in run.liveByAngle[id] },
                    onApprove: { model.ruleOnSpawn(run: run, id: $0, verdict: .approved) },
                    onReject: { model.ruleOnSpawn(run: run, id: $0, verdict: .rejected) },
                    onDig: { digFrom = $0 })
            case .fan:
                if state.round > 1 || state.roundAngleCounts.count > 1 {
                    roundStrip
                    Divider()
                }
                radialFan
            }
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

    // Each iterative round is its own band, stacked top→bottom: round 1 fans from the question, and every
    // later round fans from the round before its synthesis (round 2+ chases that synthesis's unresolved
    // conflicts + gaps). The final synthesis then flows into one "verify sources" node — the cheap
    // citation-grounding re-check. Connectors and cards both key off the global angle index, so no id
    // collision can leave a stray line without a card.
    private var radialFan: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let layout = fanLayout(w: w, h: geo.size.height)
            let lastRound = layout.rounds.last?.round
            ZStack {
                ForEach(layout.rounds) { r in
                    ForEach(r.angles) { a in
                        curvePath(r.source, a.pos).stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                        curvePath(a.pos, r.synthesis).stroke(
                            Color.accentColor.opacity(state.angles[a.index].status == .complete ? 0.6 : 0.12),
                            style: StrokeStyle(lineWidth: 1.5,
                                               dash: state.angles[a.index].status == .complete ? [] : [4]))
                            .opacity(shown ? 1 : 0)
                    }
                }
                let grounded = state.phase == .verifying || state.phase == .done
                curvePath(layout.lastSynthesis, layout.verify).stroke(
                    Color.accentColor.opacity(grounded ? 0.6 : 0.15),
                    style: StrokeStyle(lineWidth: 1.5, dash: grounded ? [] : [4]))
                    .opacity(shown ? 1 : 0)

                questionNode.position(layout.question)

                ForEach(layout.rounds) { r in
                    ForEach(r.angles) { a in
                        angleNode(state.angles[a.index])
                            .scaleEffect(shown ? 1 : 0.1).opacity(shown ? 1 : 0)
                            .animation(.spring(duration: 0.5).delay(Double(a.index) * 0.08), value: shown)
                            .position(a.pos)
                            .onTapGesture { detail = state.angles[a.index] }
                    }
                    roundSynthesisNode(r, isLast: r.round == lastRound)
                        .scaleEffect(shown ? 1 : 0.1).opacity(shown ? 1 : 0)
                        .position(r.synthesis)
                }

                verifyNode.position(layout.verify)
                    .scaleEffect(shown ? 1 : 0.1).opacity(shown ? 1 : 0)
            }
            .padding()
            .onAppear { shown = true }
        }
    }

    private struct AnglePlacement: Identifiable { let index: Int; let pos: CGPoint; var id: Int { index } }
    private struct RoundLayout: Identifiable {
        let round: Int, source: CGPoint, angles: [AnglePlacement], synthesis: CGPoint, banded: Bool
        var id: Int { round }
    }
    private struct FanLayout { let question: CGPoint, rounds: [RoundLayout], verify: CGPoint, lastSynthesis: CGPoint }

    /// Places the question, each round's angle row + synthesis, and the trailing verify node on evenly
    /// spaced horizontal levels. Angles within a round spread across the width; a narrow window zig-zags
    /// them onto a shallow band so neighbours clear. Each round's synthesis is the next round's source.
    private func fanLayout(w: CGFloat, h: CGFloat) -> FanLayout {
        let groups = Dictionary(grouping: state.angles.indices) { state.angles[$0].round }
        let roundNumbers = groups.keys.sorted()
        let rounds = max(roundNumbers.count, 1)
        let pad: CGFloat = 60
        let stops = 2 * rounds + 2                       // question + (angles, synthesis)·rounds + verify
        let gap = (h - 2 * pad) / CGFloat(max(stops - 1, 1))
        func y(_ level: Int) -> CGFloat { pad + gap * CGFloat(level) }
        let cx = w / 2
        let question = CGPoint(x: cx, y: y(0))
        var placed: [RoundLayout] = []
        var source = question
        for (j, rn) in roundNumbers.enumerated() {
            let idxs = (groups[rn] ?? []).sorted()
            let slot = w / CGFloat(max(idxs.count, 1) + 1)
            let band: CGFloat = slot < 192 ? min(gap * 0.3, 36) : 0
            let rowY = y(1 + 2 * j)
            let angles = idxs.enumerated().map { k, gi in
                AnglePlacement(index: gi, pos: CGPoint(x: slot * CGFloat(k + 1),
                                                       y: rowY + (k.isMultiple(of: 2) ? -band : band)))
            }
            let synthesis = CGPoint(x: cx, y: y(2 + 2 * j))
            placed.append(RoundLayout(round: rn, source: source, angles: angles, synthesis: synthesis, banded: band > 0))
            source = synthesis
        }
        return FanLayout(question: question, rounds: placed,
                         verify: CGPoint(x: cx, y: y(stops - 1)), lastSynthesis: source)
    }

    /// A past round's synthesis is a compact "done" marker; the current (last) round's is the full live node.
    @ViewBuilder private func roundSynthesisNode(_ r: RoundLayout, isLast: Bool) -> some View {
        if isLast {
            synthesisNode
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Synthesis · R\(r.round)").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                statusIcon(a.status)
                Text(a.angle.title.isEmpty ? "Angle" : a.angle.title)
                    .font(.caption.weight(.semibold)).lineLimit(2)
                if let live, !live.sources.isEmpty {
                    Text("\(live.sources.count) src")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            if let live, live.costUSD > 0 {
                Text(money(live.costUSD))
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

    /// The tail of an agent's live thinking/output, newlines flattened — a 2-line "what it's doing now".
    private func liveTrace(_ live: LiveSnapshot?) -> String {
        let raw = (live?.output.isEmpty == false ? live?.output : live?.thinking) ?? ""
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        let tail = s.count > 140 ? "…" + String(s.suffix(140)) : s
        return tail.replacingOccurrences(of: "\n", with: " ")
    }

    private var synthesisNode: some View {
        let active = state.phase == .synthesizing
        let done = state.phase == .verifying || state.phase == .done
        let live = run.synthesisLive
        let trace = active ? liveTrace(live) : ""
        let statusText: String = done ? "reconciled"
            : (active ? (live.output.isEmpty ? "reconciling…" : "writing…") : "waits for all angles")
        return HStack(alignment: .top, spacing: 7) {
            if active { ProgressView().controlSize(.mini) }
            else { Image(systemName: done ? "checkmark.circle.fill" : "sparkles").foregroundStyle(done ? .green : .secondary) }
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
        .background(((active || done) ? Color.accentColor.opacity(active ? 0.18 : 0.1) : Color.secondary.opacity(0.1)),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(active ? 0.6 : (done ? 0.4 : 0.25))))
        .contentShape(Rectangle())
        .onTapGesture { if active || done { synthesisOpen = true } }
    }

    /// The cheap, gated citation re-check that grounds every synthesized claim in a real source, shown as
    /// its own stage after the synthesis. Streams `run.verifyLive` while the `.verifying` phase runs.
    private var verifyNode: some View {
        let active = state.phase == .verifying
        let done = state.phase == .done
        let live = run.verifyLive
        let trace = active ? liveTrace(live) : ""
        let statusText: String = active ? (live.output.isEmpty ? "checking citations…" : "grounding claims…")
            : (done ? "citations grounded" : "waits for the synthesis")
        return HStack(alignment: .top, spacing: 7) {
            if active { ProgressView().controlSize(.mini) }
            else { Image(systemName: done ? "checkmark.seal.fill" : "checkmark.shield").foregroundStyle(done ? .green : .secondary) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Verify sources").font(.caption.weight(.semibold))
                Text(statusText).font(.caption2).foregroundStyle(.secondary)
                if !trace.isEmpty {
                    Text(trace).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
        }
        .padding(10).frame(width: 240, alignment: .leading)
        .background((active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1)),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(active ? 0.6 : (done ? 0.4 : 0.25))))
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

/// A curved connector between two nodes in the fan: vertical tangents at each end, short hold so the
/// mid-section runs close to a straight diagonal instead of bulging out to the sides.
private func curvePath(_ a: CGPoint, _ b: CGPoint) -> Path {
    var p = Path()
    p.move(to: a)
    let hold = (b.y - a.y) * 0.32
    p.addCurve(to: b, control1: CGPoint(x: a.x, y: a.y + hold), control2: CGPoint(x: b.x, y: b.y - hold))
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

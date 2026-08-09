import SwiftUI
import AppKit
import Combine
import MarkdownEngine
import MarkdownEngineCodeBlocks

/// One shared syntax highlighter (HighlighterSwift, auto light/dark) across every markdown view — it
/// spins up a JS highlighter + caches, so a per-view instance (one per chat message!) would be wasteful.
private let sharedHighlighter = HighlighterSwiftBridge()

private extension MarkdownEditorConfiguration {
    /// The app's markdown config: syntax-highlighted fenced code blocks, plus the caller's width/height mode.
    static func quorum(readingWidth: CGFloat? = nil,
                       textInsets: TextInsets = .default,
                       heightBehavior: HeightBehavior = .scrolls,
                       bus: MarkdownEditorBus = .default) -> MarkdownEditorConfiguration {
        MarkdownEditorConfiguration(
            services: MarkdownEditorServices(syntaxHighlighter: sharedHighlighter, bus: bus),
            textInsets: textInsets,
            readingWidth: readingWidth,
            heightBehavior: heightBehavior)
    }
}

/// Read-only Markdown for every viewer in the app — chat messages, the Ask answer, note writeups.
/// Backed by MarkdownEngine's live-styling TextKit-2 view in read-only mode, sized to its content
/// (`.fitsContent`) so it drops straight into an enclosing `ScrollView`. Editing lives in `NoteEditorView`.
struct MarkdownView: View {
    let markdown: String
    var documentId: String? = nil

    var body: some View {
        NativeTextViewWrapper(
            text: .constant(markdown),
            configuration: .quorum(heightBehavior: .fitsContent),
            documentId: documentId ?? "read-\(markdown.hashValue)",
            isEditable: false
        )
    }
}

/// Editable Markdown over one project `.md` file — MarkdownEngine's live-styled editor (bold reads bold,
/// headings scale, all while editable; no separate preview). Loads the file before showing the editor so
/// its initial text is the document (not an empty→content edit that would poison the undo stack), adds a
/// ⌘S Save to the surrounding toolbar, and autosaves when you navigate away so an edit is never dropped.
/// Reused by the Notes sidebar (`NoteEditorView`) and a run's Note tab.
struct MarkdownFileEditor: View {
    let path: String
    var readingWidth: CGFloat? = 720
    @State private var text = ""
    @State private var saved = ""
    @State private var frontmatter = ""   // hidden from the editor, re-attached verbatim on save
    @State private var loaded = false
    @State private var loadError: String?
    @State private var findOpen = false
    @State private var findText = ""
    @State private var findCount = 0
    @State private var findIndex = 0
    @FocusState private var findFocused: Bool

    private var url: URL { URL(fileURLWithPath: path) }
    private var dirty: Bool { text != saved }

    // Per-file bus names so a find in this editor never lights up matches in another open editor.
    private var findQueryName: Notification.Name { Notification.Name("quorum.md.findQuery." + path) }
    private var findResultsName: Notification.Name { Notification.Name("quorum.md.findResults." + path) }
    private var findClearName: Notification.Name { Notification.Name("quorum.md.findClear." + path) }
    private var bus: MarkdownEditorBus {
        MarkdownEditorBus(findClearHighlights: findClearName, findQuery: findQueryName, findResults: findResultsName)
    }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView("Couldn’t open this note", systemImage: "doc.questionmark",
                                       description: Text(loadError))
            } else if loaded {
                NativeTextViewWrapper(text: $text, configuration: .quorum(readingWidth: readingWidth, textInsets: TextInsets(horizontal: 28, vertical: 18), bus: bus), documentId: path)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .topTrailing) { if findOpen && loaded { findBar.padding(10) } }
        .background { Button(action: openFind) { }.keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0, height: 0) }
        .onChange(of: findText) { _, _ in runFind(resetIndex: true) }
        .onReceive(NotificationCenter.default.publisher(for: findResultsName)) { note in
            findCount = note.userInfo?["count"] as? Int ?? 0
            if findIndex >= findCount { findIndex = max(0, findCount - 1) }
        }
        .toolbar {
            Button { save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!dirty || loadError != nil)
        }
        .task { load() }
        .onDisappear { if dirty { save() } }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Find", text: $findText)
                .textFieldStyle(.plain).frame(width: 180)
                .focused($findFocused)
                .onSubmit { advanceMatch(by: NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
            if !findText.isEmpty {
                Text(findCount == 0 ? "Not found" : "\(findIndex + 1) of \(findCount)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button { advanceMatch(by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(findCount == 0)
            Button { advanceMatch(by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(findCount == 0)
            Button { closeFind() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .onExitCommand { closeFind() }
    }

    private func openFind() {
        findOpen = true
        DispatchQueue.main.async { findFocused = true }
        if !findText.isEmpty { runFind(resetIndex: true) }
    }

    private func closeFind() {
        findOpen = false
        findText = ""
        NotificationCenter.default.post(name: findClearName, object: nil)
    }

    private func runFind(resetIndex: Bool) {
        guard findOpen else { return }
        if resetIndex { findIndex = 0 }
        NotificationCenter.default.post(name: findQueryName, object: nil,
                                        userInfo: ["query": findText, "currentIndex": findIndex])
    }

    private func advanceMatch(by delta: Int) {
        guard findCount > 0 else { return }
        findIndex = ((findIndex + delta) % findCount + findCount) % findCount
        runFind(resetIndex: false)
    }

    private func load() {
        guard !loaded, loadError == nil else { return }
        do {
            let s = try String(contentsOf: url, encoding: .utf8)
            (frontmatter, text) = Self.splitFrontmatter(s)
            saved = text; loaded = true
        } catch { loadError = error.localizedDescription }
    }

    private func save() {
        guard dirty else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }   // don't resurrect a note deleted out from under us
        do {
            let full = frontmatter.isEmpty ? text : frontmatter + "\n" + text
            try full.write(to: url, atomically: true, encoding: .utf8)
            saved = text
        } catch { loadError = error.localizedDescription }
    }

    /// Peel a `---`-fenced frontmatter block off the top so the editor shows only the note body.
    /// Returns (verbatim frontmatter through its closing fence, body); no frontmatter → ("", whole text).
    static func splitFrontmatter(_ s: String) -> (front: String, body: String) {
        let lines = s.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return ("", s) }
        return (lines[0...close].joined(separator: "\n"), lines[(close + 1)...].joined(separator: "\n"))
    }
}

/// The Notes-sidebar detail: the shared editor for the selected file, titled by filename with a Reveal.
struct NoteEditorView: View {
    let path: String
    let model: AppModel
    var onDelete: (URL) -> Void = { _ in }
    var body: some View {
        MarkdownFileEditor(path: path)
            .navigationTitle(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
            .toolbar {
                Button {
                    ClaudeCodeLauncher.openNote(URL(fileURLWithPath: path))
                } label: { Label("Open in Claude Code", systemImage: "terminal") }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: { Label("Reveal", systemImage: "folder") }
                Button(role: .destructive) {
                    onDelete(URL(fileURLWithPath: path))
                } label: { Label("Move to Trash", systemImage: "trash") }
            }
    }
}

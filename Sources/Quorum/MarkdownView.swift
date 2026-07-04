import SwiftUI
import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks

/// One shared syntax highlighter (HighlighterSwift, auto light/dark) across every markdown view — it
/// spins up a JS highlighter + caches, so a per-view instance (one per chat message!) would be wasteful.
private let sharedHighlighter = HighlighterSwiftBridge()

private extension MarkdownEditorConfiguration {
    /// The app's markdown config: syntax-highlighted fenced code blocks, plus the caller's width/height mode.
    static func quorum(readingWidth: CGFloat? = nil,
                       heightBehavior: HeightBehavior = .scrolls) -> MarkdownEditorConfiguration {
        MarkdownEditorConfiguration(
            services: MarkdownEditorServices(syntaxHighlighter: sharedHighlighter),
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
    @State private var text = ""
    @State private var saved = ""
    @State private var frontmatter = ""   // hidden from the editor, re-attached verbatim on save
    @State private var loaded = false
    @State private var loadError: String?

    private var url: URL { URL(fileURLWithPath: path) }
    private var dirty: Bool { text != saved }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView("Couldn’t open this note", systemImage: "doc.questionmark",
                                       description: Text(loadError))
            } else if loaded {
                NativeTextViewWrapper(text: $text, configuration: .quorum(readingWidth: 720), documentId: path)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            Button { save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!dirty || loadError != nil)
        }
        .task { load() }
        .onDisappear { if dirty { save() } }
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
    var body: some View {
        MarkdownFileEditor(path: path)
            .navigationTitle(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
            .toolbar {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: { Label("Reveal", systemImage: "folder") }
            }
    }
}

import Foundation
import SwiftUI
import AppKit
import QuorumCore

/// A Claude-desktop-style chat, grounded in the current project (read-only tools). Multi-turn via a
/// persistent Claude Code session; replies stream in and render as formatted markdown.
@MainActor
@Observable
final class ChatModel {
    struct Message: Identifiable {
        let id = UUID()
        let role: Role
        var text: String
        enum Role { case user, assistant }
    }

    var messages: [Message] = []
    var input = ""
    var isStreaming = false
    var model: ModelChoice = .default

    /// When on (default), the chat gets read-only file tools + the project as `--add-dir`, so it can
    /// read the codebase. Off = web only (`WebSearch`/`WebFetch`), no file access — a plainer, cheaper
    /// chat. Per-turn, so it can be flipped mid-conversation.
    var useProjectContext = true

    // @-mention + attach: `files` is the project index (relative paths), `attachedDirs` the extra
    // `--add-dir` roots for files picked from outside the project (so the read-only tools can reach them).
    var files: [String] = []
    private var attachedDirs: Set<String> = []

    var mentionQuery: String? { Mention.activeQuery(in: input) }
    var mentionMatches: [String] { mentionQuery.map { Mention.rank($0, in: files) } ?? [] }

    let projectURL: URL
    private var sessionID: String
    private var started: Bool
    private var seed: String?
    private var task: Task<Void, Never>?

    /// `resumeSessionID` continues an existing CLI research session so the chat has its full context;
    /// nil starts a fresh conversation. `seed` grounds a fresh session with a prior topic's writeup —
    /// used for engine-run topics, whose synthetic session ids the CLI cannot `--resume` (PRD 02 R8).
    init(projectURL: URL, resumeSessionID: String? = nil, seed: String? = nil, model: ModelChoice = .default) {
        self.projectURL = projectURL
        self.sessionID = resumeSessionID ?? UUID().uuidString
        self.started = (resumeSessionID != nil)
        self.seed = seed
        self.model = model
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        messages.append(Message(role: .user, text: text))
        let assistantIndex = messages.count           // index the assistant reply will occupy
        messages.append(Message(role: .assistant, text: ""))
        isStreaming = true

        let resume = started; started = true
        // A seeded (engine-run) chat carries the prior writeup into its first CLI turn only; the visible
        // message stays the user's. After that the fresh CLI session continues normally.
        let cliMessage = (!resume && seed != nil) ? seed! + "\n\n---\n\n" + text : text
        seed = nil
        let sid = sessionID, project = projectURL, dirs = Array(attachedDirs), mdl = model, ctx = useProjectContext
        task = Task { [weak self] in
            await ChatRunner.stream(message: cliMessage, sessionID: sid, resume: resume, projectURL: project, extraDirs: dirs, model: mdl, useProjectContext: ctx) { full in
                DispatchQueue.main.async {   // FIFO: full cumulative text, latest wins
                    guard let self, self.messages.indices.contains(assistantIndex) else { return }
                    self.messages[assistantIndex].text = full
                }
            }
            await MainActor.run {
                guard let self else { return }
                if self.messages.indices.contains(assistantIndex), self.messages[assistantIndex].text.isEmpty {
                    self.messages[assistantIndex].text = "_(no response)_"
                }
                self.isStreaming = false
            }
        }
    }

    func stop() { task?.cancel() }

    /// Recover the prior conversation from Claude Code's on-disk session transcript, so a *resumed*
    /// chat shows its history instead of a blank screen. Read + parsed off-main; only fills an empty
    /// chat (never clobbers a live one).
    func loadHistory() {
        guard started, messages.isEmpty else { return }
        let sid = sessionID, project = projectURL
        Task.detached(priority: .utility) {
            let history = SessionHistory.load(sessionID: sid, projectURL: project)
            guard !history.isEmpty else { return }
            await MainActor.run { if self.messages.isEmpty { self.messages = history } }
        }
    }

    // MARK: @-mention + attach

    /// Build the project file index off the main thread (a big repo shouldn't hitch the composer).
    func loadFileIndex() {
        let root = projectURL
        Task.detached(priority: .utility) {
            let list = ProjectFileScan.list(root)
            await MainActor.run { self.files = list }
        }
    }

    /// Accept a suggestion: replace the active `@query` with the file path.
    func complete(with path: String) { input = Mention.complete(input, with: path) }

    /// Paperclip: pick files (or folders) and reference them. In-project paths mention relatively;
    /// anything outside also gets its folder added to `--add-dir` so the read-only tools can read it.
    func attach() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let rel = Mention.relativePath(of: url, under: projectURL) {
                appendToken("@\(rel)")
            } else {
                attachedDirs.insert(url.hasDirectoryPath ? url.path : url.deletingLastPathComponent().path)
                appendToken("@\(url.path)")
            }
        }
    }

    private func appendToken(_ token: String) {
        if !input.isEmpty, !input.hasSuffix(" ") { input += " " }
        input += token + " "
    }
}

/// Relative paths of project files for @-mention autocomplete. Skips VCS/build/dependency noise and
/// hidden files. ponytail: one-shot scan cached in the model; a giant monorepo caps at `limit` —
/// raise it or add a watcher if that ever bites.
enum ProjectFileScan {
    static func list(_ root: URL, limit: Int = 5000) -> [String] {
        let skip: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", ".swiftpm", "Pods", ".venv"]
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in en {
            if skip.contains(url.lastPathComponent) { en.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let rel = Mention.relativePath(of: url, under: root) else { continue }
            out.append(rel)
            if out.count >= limit { break }
        }
        return out.sorted()
    }
}

/// Builds the grounding preamble for an engine-run topic's chat (PRD 02 R8): the CLI can't `--resume`
/// the engine's synthetic session, so a fresh session is seeded with the topic's writeup (the note on
/// disk) instead. Bounded so a long note can't blow the first prompt.
enum ChatSeed {
    static func make(notePath: String?, question: String) -> String {
        var s = "You are continuing a prior research topic. The original question was:\n\n\(question)\n"
        if let p = notePath,
           let writeup = try? String(contentsOf: URL(fileURLWithPath: p), encoding: .utf8),
           !writeup.isEmpty {
            let bounded = writeup.count > 12000 ? String(writeup.prefix(12000)) + "\n…(truncated)" : writeup
            s += "\nHere is the research writeup already produced — treat it as your context; the user " +
                 "will now ask follow-ups:\n\n\(bounded)\n"
        }
        s += "\nAnswer follow-ups using this context; search or read further as needed."
        return s
    }
}

enum ChatRunner {
    /// Streams one turn; `onUpdate` receives the cumulative assistant text so far.
    static func stream(message: String, sessionID: String, resume: Bool, projectURL: URL,
                       extraDirs: [String] = [], model: ModelChoice = .default,
                       useProjectContext: Bool = true,
                       onUpdate: @escaping @Sendable (String) -> Void) async {
        guard let claudePath = ClaudeCLI.resolvePath() else {
            onUpdate("⚠️ Claude Code CLI not found on PATH."); return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        var args = ["-p", message,
                    "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--permission-mode", "dontAsk"]
        // The `--tools` allow-list is the real gate: without Read/Grep/Glob the model can't touch the
        // filesystem even though cwd is the project, so context-off just drops those + the extra dirs.
        if useProjectContext {
            args += ["--tools", "WebSearch,WebFetch,Read,Grep,Glob", "--add-dir", projectURL.path]
            for dir in extraDirs { args += ["--add-dir", dir] }   // attachments picked outside the project
        } else {
            args += ["--tools", "WebSearch,WebFetch"]
        }
        args += model.args
        args += resume ? ["--resume", sessionID] : ["--session-id", sessionID]
        process.arguments = args
        process.currentDirectoryURL = projectURL
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        do { try process.run() } catch { onUpdate("⚠️ Failed to launch Claude Code."); return }

        var acc = ""
        await withTaskCancellationHandler {
            do {
                for try await line in out.fileHandleForReading.bytes.lines {
                    if Task.isCancelled { break }
                    guard let ev = ResearchOutputParser.parseStreamLine(line) else { continue }
                    if let t = ev.assistantText { acc += t; onUpdate(acc) }
                    else if ev.type == "result", let r = ev.result, acc.isEmpty { acc = r; onUpdate(acc) }
                }
            } catch {}
            process.waitUntilExit()
        } onCancel: {
            process.terminate()
        }
    }
}

// MARK: - Session history recovery (read Claude Code's on-disk transcript)

/// Claude Code persists every session to `~/.claude/projects/<escaped-project-path>/<session-id>.jsonl`.
/// We read that so a resumed chat shows its prior turns. Lenient parse (string-or-array content, unknown
/// lines skipped) — never throws; an unreadable/absent transcript just yields an empty history.
enum SessionHistory {
    static func load(sessionID: String, projectURL: URL) -> [ChatModel.Message] {
        guard let file = transcriptURL(sessionID: sessionID, projectURL: projectURL),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var msgs: [ChatModel.Message] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            let content = extractText(message["content"])
            guard !content.isEmpty else { continue }   // skips tool_use / tool_result-only turns
            let role: ChatModel.Message.Role = (message["role"] as? String) == "user" ? .user : .assistant
            if role == .assistant, let last = msgs.last, last.role == .assistant {
                msgs[msgs.count - 1].text += "\n\n" + content   // merge streamed assistant chunks
            } else {
                msgs.append(ChatModel.Message(role: role, text: content))
            }
        }
        return msgs
    }

    /// Text from a transcript `content` field — either a plain string or an array of typed blocks.
    private static func extractText(_ content: Any?) -> String {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func transcriptURL(sessionID: String, projectURL: URL) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        // Claude Code escapes the project path by replacing "/" and "." with "-".
        let escaped = projectURL.path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let direct = root.appendingPathComponent(escaped, isDirectory: true).appendingPathComponent("\(sessionID).jsonl")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // Fallback: session ids are unique, so find it under any project dir (robust to escaping quirks).
        for dir in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let candidate = dir.appendingPathComponent("\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

// MARK: - View

struct ChatView: View {
    @Bindable var chat: ChatModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chat.messages.isEmpty {
                            ContentUnavailableView("Chat about this project",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("Ask follow-ups, dig into findings, or explore the codebase — read-only, grounded in \(chat.projectURL.lastPathComponent)."))
                                .padding(.top, 40)
                        }
                        ForEach(chat.messages) { ChatBubble(message: $0) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.messages.last?.text) { _, _ in
                    withAnimation(.easeOut) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            if !chat.mentionMatches.isEmpty { mentionSuggestions }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                Button { chat.useProjectContext.toggle() } label: {
                    Image(systemName: chat.useProjectContext ? "folder.fill" : "folder").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(chat.useProjectContext ? Color.accentColor : .secondary)
                .help(chat.useProjectContext
                      ? "Project context on — chat can read \(chat.projectURL.lastPathComponent) (read-only). Tap to turn off."
                      : "Project context off — web search only, no file access. Tap to turn on.")
                Button { chat.attach() } label: { Image(systemName: "paperclip").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Attach files — added as read-only context for this chat")
                    .disabled(!chat.useProjectContext)
                TextField("Ask about this project…  (@ to mention a file)", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit(submit)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                if chat.isStreaming {
                    Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.plain).foregroundStyle(.red)
                } else {
                    Button { chat.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                        .disabled(chat.input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(10)
        }
        .navigationTitle("Chat")
        .task { chat.loadFileIndex(); chat.loadHistory() }
    }

    /// Return accepts the top file suggestion when a non-empty `@query` is open; otherwise it sends.
    private func submit() {
        if chat.mentionQuery?.isEmpty == false, let top = chat.mentionMatches.first { chat.complete(with: top) }
        else { chat.send() }
    }

    private var mentionSuggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(chat.mentionMatches, id: \.self) { path in
                Button { chat.complete(with: path) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial)
    }
}

struct ChatBubble: View {
    let message: ChatModel.Message

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 48) }
            Group {
                if message.role == .assistant && message.text.isEmpty {
                    ProgressView().controlSize(.small)
                } else if message.role == .assistant {
                    MarkdownView(markdown: message.text)
                } else {
                    Text(message.text).textSelection(.enabled)
                }
            }
            .padding(12)
            .background(bubbleColor, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer(minLength: 48) }
        }
        .transition(.opacity.combined(with: .move(edge: message.role == .user ? .trailing : .leading)))
    }

    private var bubbleColor: Color {
        message.role == .user ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.1)
    }
}

// MARK: - Hand off to the real Claude Code CLI in a terminal

/// A terminal Quorum can hand a session off to. Any app that opens `.command` scripts works — Terminal,
/// iTerm, Ghostty, and the rest all declare themselves handlers — so one launch path covers them all.
struct TerminalApp: Identifiable, Hashable {
    let name: String
    let bundleID: String
    var id: String { bundleID }

    static let known = [
        TerminalApp(name: "Terminal", bundleID: "com.apple.Terminal"),
        TerminalApp(name: "iTerm", bundleID: "com.googlecode.iterm2"),
        TerminalApp(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
        TerminalApp(name: "Warp", bundleID: "dev.warp.Warp-Stable"),
        TerminalApp(name: "WezTerm", bundleID: "com.github.wez.wezterm"),
        TerminalApp(name: "Alacritty", bundleID: "org.alacritty"),
        TerminalApp(name: "kitty", bundleID: "net.kovidgoyal.kitty"),
    ]
    static let `default` = known[0]

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// The known terminals actually installed — what the Settings picker offers.
    static var installed: [TerminalApp] { known.filter { isInstalled($0.bundleID) } }

    /// The chosen terminal, falling back to Terminal if unset or since-uninstalled.
    static var chosen: TerminalApp {
        let id = UserDefaults.standard.string(forKey: "terminalBundleID") ?? ""
        return known.first { $0.bundleID == id && isInstalled(id) } ?? `default`
    }
}

enum ClaudeCodeLauncher {
    /// Opens Terminal in the project and resumes the topic's session — the user takes over
    /// interactively in real Claude Code (where `/usage`, tools, etc. all work). `fork: true` branches
    /// off the same history into a fresh, explicitly-named session (`--fork-session --session-id <new>`),
    /// so every launch is a distinct, resumable id — open as many as you like and they diverge
    /// independently instead of clobbering one session file. (Bare `--fork-session` mints the new id
    /// lazily and invisibly, so both forks read as the parent id until you message — hence the explicit id.)
    static func openTerminal(projectPath: String, resumeSessionID: String?, fork: Bool = false) {
        var resume = ""
        if let sid = resumeSessionID {
            resume = "--resume \(sid)"
            if fork { resume += " --fork-session --session-id \(UUID().uuidString.lowercased())" }
        }
        runInTerminal("cd '\(projectPath)' && claude \(resume)")
    }

    /// Fork one planned angle straight into a fresh interactive Claude Code session (full tools),
    /// seeded with the angle's prompt — hand it off to the real CLI instead of Quorum's read-only
    /// research engine. Newlines are collapsed and single quotes escaped so the prompt survives as one
    /// shell argument (the user typed it and it runs as themselves — this is robustness, not a trust boundary).
    static func forkAngle(projectPath: String, prompt: String) {
        let oneLine = prompt.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let arg = "'" + oneLine.replacingOccurrences(of: "'", with: "'\\''") + "'"
        runInTerminal("cd '\(projectPath)' && claude \(arg)")
    }

    /// Open a fresh Claude Code session in Terminal rooted at the note's git repo — so the whole repo is
    /// in scope — with the note `@`-mentioned so the session opens already pointed at it, plus every
    /// sibling note it `[[wikilinks]]` that exists on disk, so the relevant research is in context from the
    /// first message. Falls back to the note's own folder when it isn't inside a git repo; a folder opens
    /// Claude Code at its root, unmentioned.
    static func openNote(_ url: URL) {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let dir = isDir ? url : url.deletingLastPathComponent()
        let root = gitRoot(for: dir) ?? dir
        let mentions = isDir ? [] : [url] + referencedNotes(of: url, in: dir)
        let args = mentions.map { "'@\(relativePath(of: $0, under: root))'" }.joined(separator: " ")
        runInTerminal(args.isEmpty ? "cd '\(root.path)' && claude" : "cd '\(root.path)' && claude \(args)")
    }

    /// Sibling notes a note `[[wikilinks]]` — resolved directly as `<slug>.md` in the note's own folder
    /// (notes all live together in `Quorum/notes/`), keeping only those that exist. ponytail: notes only,
    /// not run artifacts — those live under nested `runs/` dirs and would need a search; add if asked.
    private static func referencedNotes(of note: URL, in dir: URL) -> [URL] {
        guard let body = try? String(contentsOf: note, encoding: .utf8) else { return [] }
        let selfSlug = note.deletingPathExtension().lastPathComponent
        return DiskFindingsStore.wikilinkSlugs(in: body)
            .filter { $0 != selfSlug }
            .map { dir.appendingPathComponent("\($0).md") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.lastPathComponent
    }

    /// The git repo root containing `dir` (`git rev-parse --show-toplevel`), or nil when it isn't a repo.
    private static func gitRoot(for dir: URL) -> URL? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "rev-parse", "--show-toplevel"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return URL(fileURLWithPath: s, isDirectory: true)
    }

    /// Run a shell line in the user's chosen terminal by writing a one-shot `.command` and opening it
    /// with that app — the login-shell shebang gives the same PATH `ClaudeCLI.resolvePath` relies on.
    private static func runInTerminal(_ shell: String) {
        let script = "#!/bin/zsh -l\n\(shell)\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quorum-\(UUID().uuidString).command")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)) != nil
        else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", TerminalApp.chosen.bundleID, url.path]
        try? p.run()
    }
}

// MARK: - Auto-titled History (cheapest model, folder renamed to `<title> <timestamp>`)

/// Give a past run a short human title (from the run's question) and rename its folder to
/// `<title> <timestamp>`, so both History and the run dir on disk read as a topic instead of a bare
/// timestamp. Generated ONCE per run — the folder name is the title's only home, so a titled run is
/// never re-titled. Ultra-cheap by construction: the cheapest model (Haiku), one line in, ≤6 words
/// out, no session, and a hard $0.02 budget wall as the guardrail (the app's "walls, not warnings").
/// A reply that clarifies or refuses instead of titling is not a title (`RunTitle`) — the question
/// itself names the run then, so a run folder always reads as its topic.
/// ponytail: no `--tools` restriction — the wall caps a stray tool call at $0.02.
enum RunTitler {
    /// A 3-to-6-word Title Case label for a research question from the cheapest model, falling back to
    /// the question itself whenever the model can't be reached or answers with anything but a title.
    /// Called at run creation to name the folder up front.
    static func title(forQuestion question: String, avoiding existingTitle: String? = nil) async -> String? {
        let fallback = RunTitle.fromQuestion(question)
        guard let claudePath = ClaudeCLI.resolvePath() else { return fallback.isEmpty ? nil : fallback }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        var prompt = "Reply with ONLY a 3-to-6-word Title Case title for this research question. " +
            "No quotes, no punctuation, no preamble, and do not use any tools."
        if let existingTitle = existingTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existingTitle.isEmpty {
            prompt = "Reply with ONLY a different 3-to-6-word Title Case title for this research question. " +
                "Avoid reusing this title: \"\(existingTitle)\". No quotes, no punctuation, no preamble, " +
                "and do not use any tools."
        }
        process.arguments = [
            "-p", question,
            "--model", "claude-haiku-4-5",       // cheapest model, per the ask
            "--permission-mode", "dontAsk",
            "--max-budget-usd", "0.02",          // hard cost wall for a throwaway title call
            "--append-system-prompt",
            prompt,
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return fallback.isEmpty ? nil : fallback }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let raw = process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
        let title = RunTitle.from(reply: raw, question: question)
        return title.isEmpty ? nil : title
    }

    /// Backfill for legacy bare-stamp runs (and any whose at-creation title call failed): title from the
    /// run's report.json and rename the folder. Returns the new URL, or nil if nothing changed.
    static func titleAndRename(runDir: URL, avoiding existingTitle: String? = nil) async -> URL? {
        guard let question = mainQuestion(runDir),
              let label = await title(forQuestion: question, avoiding: existingTitle) else { return nil }
        let newName = RunFolder.name(title: label, stamp: RunFolder.stamp(runDir.lastPathComponent))
        let newURL = runDir.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
        guard newURL != runDir, !FileManager.default.fileExists(atPath: newURL.path),
              (try? FileManager.default.moveItem(at: runDir, to: newURL)) != nil else { return nil }
        rebasePaths(in: newURL, from: runDir.path, to: newURL.path)
        return newURL
    }

    /// The run's headline question — the synthesis topic for a fan-out, else the first topic.
    private static func mainQuestion(_ runDir: URL) -> String? {
        guard let data = try? Data(contentsOf: runDir.appendingPathComponent("report.json")),
              let report = try? JSONDecoder().decode(RunReport.self, from: data) else { return nil }
        let q = (report.entries.first(where: { $0.isSynthesis == true }) ?? report.entries.first)?.question
        let trimmed = q?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Fan-out records its synthesis + angle writeups by absolute path inside the run dir, and the UI
    /// opens them — so after moving the folder, rewrite those paths in report.json. Plain text replace
    /// of the dir prefix: brain note paths live outside the run dir and are left untouched.
    private static func rebasePaths(in runDir: URL, from oldPath: String, to newPath: String) {
        let report = runDir.appendingPathComponent("report.json")
        guard oldPath != newPath, let json = try? String(contentsOf: report, encoding: .utf8) else { return }
        try? json.replacingOccurrences(of: oldPath, with: newPath)
            .write(to: report, atomically: true, encoding: .utf8)
    }
}

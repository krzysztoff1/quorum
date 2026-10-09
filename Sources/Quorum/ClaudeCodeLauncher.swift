import Foundation
import AppKit
import QuorumCore

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
        return NotesFolder.wikilinkSlugs(in: body)
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

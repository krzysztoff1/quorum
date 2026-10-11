import Foundation
import AppKit
import QuorumCore

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

    static var installed: [TerminalApp] { known.filter { isInstalled($0.bundleID) } }

    static var chosen: TerminalApp {
        let id = UserDefaults.standard.string(forKey: "terminalBundleID") ?? ""
        return known.first { $0.bundleID == id && isInstalled(id) } ?? `default`
    }
}

enum ClaudeCodeLauncher {
    static func openTerminal(projectPath: String, resumeSessionID: String?, fork: Bool = false) {
        var resume = ""
        if let sid = resumeSessionID {
            resume = "--resume \(sid)"
            if fork { resume += " --fork-session --session-id \(UUID().uuidString.lowercased())" }
        }
        runInTerminal("cd \(ShellQuote.quoted(projectPath)) && claude \(resume)")
    }

    static func openNote(_ url: URL) {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let dir = isDir ? url : url.deletingLastPathComponent()
        let root = gitRoot(for: dir) ?? dir
        let mentions = isDir ? [] : [url] + referencedNotes(of: url, in: dir)
        let args = mentions.map { ShellQuote.quoted("@" + relativePath(of: $0, under: root)) }.joined(separator: " ")
        let enter = "cd \(ShellQuote.quoted(root.path)) && claude"
        runInTerminal(args.isEmpty ? enter : "\(enter) \(args)")
    }

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

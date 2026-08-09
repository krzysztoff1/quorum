import Foundation
import IOKit.pwr_mgt
import UserNotifications
import QuorumCore

// MARK: - Power (IOKit): keep the Mac awake for the run, let it sleep after (stories 17–18)

final class IOKitPowerManager: PowerManager, @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    func preventSleep(reason: String) {
        lock.withLock {
            guard !held else { return }
            var id: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString, &id)
            if ok == kIOReturnSuccess { assertionID = id; held = true }
        }
    }

    func allowSleep() {
        lock.withLock {
            guard held else { return }
            IOPMAssertionRelease(assertionID)
            held = false
        }
    }
}

// MARK: - Notifier (UserNotifications): "the digest is ready" (story 48)

final class UNNotifier: Notifier, @unchecked Sendable {
    func notifyRunFinished(_ report: RunReport) {
        // UNUserNotificationCenter crashes without a bundle identifier (e.g. `swift run`), so guard.
        guard Bundle.main.bundleIdentifier != nil else {
            print("Quorum: run finished — \(report.entries.count) topic(s), \(report.totalCostUSD) spent (no bundle: notification skipped)")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Quorum — run digest ready"
        let done = report.entries.filter { $0.status == .complete }.count
        content.body = "\(done)/\(report.entries.count) topics complete · \(money(report.totalCostUSD)) spent"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req)
    }

    /// A question the run raised while nobody was looking at it. The wave carries on regardless, so this is
    /// an offer rather than an alarm — it is said once, and it expires on its own if nobody comes back.
    func notifyPendingApproval(_ alert: PendingApprovalAlert) {
        guard Bundle.main.bundleIdentifier != nil else {
            print("Quorum: \(alert.title) — \(alert.body) (no bundle: notification skipped)")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req)
    }

    private func money(_ d: Decimal) -> String { String(format: "$%.2f", (d as NSDecimalNumber).doubleValue) }
}

// MARK: - Claude Code CLI: locate, version, best-effort auth (stories 40–41)

enum ClaudeCLI {
    /// Resolve the absolute `claude` path via a login shell (a GUI app's PATH is minimal, so
    /// `which` in-process misses mise/homebrew/npm installs).
    static func resolvePath() -> String? {
        if let p = runCapturing("/bin/zsh", ["-lc", "command -v claude"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty,
           FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let common = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                      "\(home)/.local/bin/claude", "\(home)/.claude/local/claude"]
        return common.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func version(at path: String) -> String? {
        runCapturing(path, ["--version"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init)
    }

    /// Best-effort: honest `nil` when we can't tell (e.g. keychain-stored creds we can't read).
    static func isAuthenticated() -> Bool? {
        if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json")),
           !data.isEmpty { return true }
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
           let s = String(data: data, encoding: .utf8),
           s.contains("oauthAccount") || s.contains("access_token") { return true }
        return nil
    }

    private static func runCapturing(_ launch: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

struct ClaudeCLIProbe: ClaudeProbe {
    func probe() -> ProbeResult {
        guard let path = ClaudeCLI.resolvePath() else {
            return ProbeResult(installed: false, authenticated: nil, version: nil, detail: "not found on PATH")
        }
        return ProbeResult(installed: true, authenticated: ClaudeCLI.isAuthenticated(),
                           version: ClaudeCLI.version(at: path), detail: path)
    }
}

// MARK: - OpenAI Codex CLI: the second subscription runner

enum CodexCLI {
    static func resolvePath() -> String? {
        if let p = runCapturing("/bin/zsh", ["-lc", "command -v codex"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty,
           FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let common = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                      "\(home)/.local/bin/codex", "\(home)/.codex/bin/codex"]
        return common.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func version(at path: String) -> String? {
        runCapturing(path, ["--version"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").last.map(String.init)
    }

    /// Best-effort, same contract as the Claude probe: honest `nil` when sign-in can't be confirmed.
    static func isAuthenticated() -> Bool? {
        if ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty == false { return true }
        let auth = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        if let data = try? Data(contentsOf: auth), !data.isEmpty { return true }
        return nil
    }

    private static func runCapturing(_ launch: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

struct CodexCLIProbe: ClaudeProbe {
    func probe() -> ProbeResult {
        guard let path = CodexCLI.resolvePath() else {
            return ProbeResult(installed: false, authenticated: nil, version: nil, detail: "not found on PATH")
        }
        return ProbeResult(installed: true, authenticated: CodexCLI.isAuthenticated(),
                           version: CodexCLI.version(at: path), detail: path)
    }
}

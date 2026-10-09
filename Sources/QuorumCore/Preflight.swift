import Foundation

public struct PreflightResult: Sendable, Equatable {
    public let ok: Bool          // is a run safe to start?
    public let message: String   // clear, actionable
    public init(ok: Bool, message: String) { self.ok = ok; self.message = message }
}

/// Fails loud at setup, never silent at 2am (story 41): checks the Claude Code CLI is present and
/// (best-effort) signed in before a run starts.
public enum Preflight {
    public static func check(_ probe: ClaudeProbe) -> PreflightResult {
        let r = probe.probe()
        let ver = r.version.map { " (v\($0))" } ?? ""

        guard r.installed else {
            return PreflightResult(ok: false, message:
                "Claude Code CLI not found. Install it and sign in (claude.com/claude-code), then reopen Quorum.")
        }
        switch r.authenticated {
        case .some(false):
            return PreflightResult(ok: false, message:
                "Claude Code is installed\(ver) but not signed in. Run `claude` once and sign in, then try again.")
        case .none:
            return PreflightResult(ok: true, message:
                "Claude Code found\(ver). Sign-in couldn't be confirmed — a run will fail fast if you're not logged in.")
        case .some(true):
            return PreflightResult(ok: true, message: "Claude Code ready\(ver).")
        }
    }

    public static func refusalFinding(_ refusal: RunStreamParser.Refusal) -> PreflightResult {
        PreflightResult(ok: false, message: "The last run was refused: \(refusal.reason)")
    }

    public static func engineRefusal(_ resolution: EngineResolution) -> String? {
        guard let why = resolution.refusalReason else { return nil }
        return "Quorum can't run: no compatible \(RunPipeline.engineName) was found, and it never runs "
             + "without one. \(why). Set QUORUM_ENGINE_BIN, or reinstall the app to get the bundled engine back."
    }
}

public enum ClaudeAuthStatus {
    public static func isLoggedIn(from output: String?) -> Bool? {
        guard let data = output?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else { return nil }
        return loggedIn
    }
}

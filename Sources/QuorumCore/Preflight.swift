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

    /// The flagship pipeline lives in the engine binary. Without it a run still happens — it drops to the
    /// in-process orchestration — but with no validator loop and no captured evidence, and the only way a
    /// reader would ever know is by noticing what is missing. So it is said out loud before the run, not
    /// discovered afterwards in what the artifacts don't contain. Not a blocker: the run is still worth having.
    public static func engineNotice(_ resolution: EngineResolution) -> String? {
        guard let why = resolution.fallbackReason else { return nil }
        return "No usable \(RunPipeline.engineName) — this run falls back to the "
             + "\(RunPipeline.inProcessName) pipeline (\(RunPipeline.legacyBadge), no evidence captured). "
             + "\(why). Set QUORUM_ENGINE_BIN, or reinstall the app to get the bundled engine back."
    }
}

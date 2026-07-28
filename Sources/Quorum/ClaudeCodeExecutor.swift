import Foundation
import QuorumCore

/// A live snapshot of one topic's research as it streams — what the UI shows in real time.
struct LiveSource: Identifiable, Hashable, Sendable {
    var id: String { "\(kind)·\(value)·\(at.timeIntervalSince1970)" }
    let kind: String    // WebSearch / WebFetch / Read / Grep / Glob / web_search / web_fetch
    let value: String    // the query / url / path
    var at = Date()      // when it landed — the x-position of its tick on the time-lane trace
    var isURL: Bool { value.hasPrefix("http") }
}

struct LiveSnapshot: Sendable {
    var topicID = ""
    var question = ""
    var thinking = ""
    var output = ""
    var sources: [LiveSource] = []
    var costUSD: Decimal = 0    // live cumulative spend for this agent (shown on its fan-out node)
    var writingStartedAt: Date? // first output token — where gathering turns into writing on the trace
}

/// The subscription production seam: runs a topic by spawning the Claude Code CLI headless as a
/// supervised subprocess. Read-only tools only, no permission prompts, a hard per-topic dollar wall,
/// process kill on cancellation. Args live in `QuorumCore.CLIInvocation`, the shared stream reduction
/// in `ResearchStream`, pure parsing in `QuorumCore.ResearchOutputParser`. Subscription OAuth is used
/// here and nowhere else — the engine never touches it.
struct ClaudeCodeExecutor: ResearchExecutor, AnglePlanner {

    /// Own-search on the CLI path (PRD 02 R7): point `claude` at the bundled engine's MCP server for
    /// web search. `binaryPath` rides the `--mcp-config` argv; `keys` (the search key) is injected into
    /// the subprocess environment ONLY — inherited by the MCP child, never in argv or logs.
    struct OwnSearch { let binaryPath: String; let keys: [String: String] }

    let onActivity: (@Sendable (LiveSnapshot) -> Void)?
    let model: ModelChoice
    let synthesisModel: ModelChoice   // the fan-in step can run on a stronger model than the angles
    let ownSearch: OwnSearch?         // nil → built-in WebSearch, exactly as today (the zero-setup promise)

    init(onActivity: (@Sendable (LiveSnapshot) -> Void)? = nil,
         model: ModelChoice = .default, synthesisModel: ModelChoice? = nil,
         ownSearch: OwnSearch? = nil) {
        self.onActivity = onActivity
        self.model = model
        self.synthesisModel = synthesisModel ?? model
        self.ownSearch = ownSearch
    }

    func run(_ topic: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        guard let claudePath = ClaudeCLI.resolvePath() else {
            throw ExecutorError(message: "Claude Code CLI not found on PATH.")
        }
        let env = ownSearch.map { ProcessInfo.processInfo.environment.merging($0.keys) { _, k in k } }
        return try await ResearchStream.run(
            executable: URL(fileURLWithPath: claudePath),
            arguments: CLIInvocation.claudeArguments(for: topic, modelArgs: model.args,
                                                     synthesisModelArgs: synthesisModel.args,
                                                     ownSearchBinary: ownSearch?.binaryPath),
            environment: env, topic: topic, ctx, onActivity: onActivity)
    }

    func plan(question: String, count: Int, priorNotes: [URL], projectURL: URL,
              _ ctx: RunContext) async throws -> [ResearchAngle] {
        guard let claudePath = ClaudeCLI.resolvePath() else {
            throw ExecutorError(message: "Claude Code CLI not found on PATH.")
        }
        return try await ResearchStream.plan(
            executable: URL(fileURLWithPath: claudePath),
            arguments: CLIInvocation.planArguments(question: question, count: count,
                                                   priorNotes: priorNotes, modelArgs: model.args),
            environment: nil, projectURL: projectURL, ctx, onActivity: onActivity)
    }
}

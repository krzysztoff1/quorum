import Foundation
import QuorumCore

/// Locates the bundled `quorum-engine` binary (PRD 01 R8): shipped in the app bundle's Resources, with
/// an env override for dev/CI. ponytail: no PATH search — the engine is ours, it's in the bundle or the
/// override; anything else is a misconfiguration we want to surface, not paper over.
enum QuorumEngine {
    static func resolvePath() -> String? {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["QUORUM_ENGINE_BIN"], fm.isExecutableFile(atPath: p) {
            return p
        }
        if let url = Bundle.main.url(forResource: "quorum-engine", withExtension: nil),
           fm.isExecutableFile(atPath: url.path) {
            return url.path
        }
        return nil
    }
}

/// The BYOK production seam: runs a topic on the bundled `quorum-engine` (cheap models via the AI SDK +
/// our own search) instead of the Claude Code CLI. Same stream contract, so the same `ResearchStream`
/// reduction applies. Provider/search keys are injected into the subprocess environment (never argv,
/// never logged — PRD 01 R6 / PRD 02 R4). Subscription OAuth is never used here.
struct EngineExecutor: ResearchExecutor, AnglePlanner {

    let onActivity: (@Sendable (LiveSnapshot) -> Void)?
    let model: String            // provider/model-id for planner + angles (e.g. "deepseek/deepseek-chat")
    let synthesisModel: String   // provider/model-id for synthesis + verify
    let keys: [String: String]   // QUORUM_*_KEY → value, injected into the engine's environment
    let binaryPath: String?      // override for dev/tests; nil → resolve from the bundle

    init(onActivity: (@Sendable (LiveSnapshot) -> Void)? = nil,
         model: String, synthesisModel: String? = nil,
         keys: [String: String] = [:], binaryPath: String? = nil) {
        self.onActivity = onActivity
        self.model = model
        self.synthesisModel = synthesisModel ?? model
        self.keys = keys
        self.binaryPath = binaryPath
    }

    private func environment() -> [String: String] {
        ProcessInfo.processInfo.environment.merging(keys) { _, injected in injected }
    }

    func run(_ topic: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        guard let bin = binaryPath ?? QuorumEngine.resolvePath() else {
            throw ExecutorError(message: "Quorum engine binary not found in the app bundle.")
        }
        let roleModel = topic.role == .research ? model : synthesisModel
        return try await ResearchStream.run(
            executable: URL(fileURLWithPath: bin),
            arguments: EngineInvocation.arguments(for: topic, model: model, synthesisModel: synthesisModel),
            environment: environment(), topic: topic, ctx, onActivity: onActivity,
            fallbackProvider: ModelID.provider(roleModel), fallbackModel: roleModel)
    }

    func plan(question: String, count: Int, priorNotes: [URL], projectURL: URL,
              _ ctx: RunContext) async throws -> [ResearchAngle] {
        guard let bin = binaryPath ?? QuorumEngine.resolvePath() else {
            throw ExecutorError(message: "Quorum engine binary not found in the app bundle.")
        }
        return try await ResearchStream.plan(
            executable: URL(fileURLWithPath: bin),
            arguments: EngineInvocation.planArguments(question: question, count: count,
                                                      priorNotes: priorNotes, model: model),
            environment: environment(), projectURL: projectURL, ctx, onActivity: onActivity)
    }
}

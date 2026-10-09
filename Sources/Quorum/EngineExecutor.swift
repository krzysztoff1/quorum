import Foundation
import QuorumCore

enum QuorumEngine {
    private static let lock = NSLock()
    private static var cached: (key: String, resolution: EngineResolution)?

    static func resolvePath() -> String? { resolve().path }

    static func resolve() -> EngineResolution {
        let fm = FileManager.default
        let candidates = EngineCandidate.ordered(
            override: ProcessInfo.processInfo.environment["QUORUM_ENGINE_BIN"],
            bundleResource: Bundle.main.url(forResource: "quorum-engine", withExtension: nil)?.path,
            executable: Bundle.main.executableURL?.resolvingSymlinksInPath(),
            fileExists: fm.fileExists(atPath:))
        let key = candidates.map { "\($0.path)@\(modificationStamp($0.path))" }.joined(separator: "|")
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.key == key { return cached.resolution }
        let resolution = EngineResolution.resolve(candidates, isExecutable: fm.isExecutableFile(atPath:),
                                                  probe: handshakeOutput)
        cached = (key, resolution)
        return resolution
    }

    private static func modificationStamp(_ path: String) -> String {
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return date.map { String($0.timeIntervalSince1970) } ?? "absent"
    }

    private static func handshakeOutput(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["version"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8)
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

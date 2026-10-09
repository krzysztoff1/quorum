import Foundation
import QuorumCore

enum EngineRunClient {

    struct Config: Encodable {
        let question: String
        let angleCount: Int
        let angleModel: String
        let synthesisModel: String
        let validatorModel: String
        let effort: String
        let perTopicBudgetUSD: Double
        let runBudgetUSD: Double
        let perTopicTimeoutSec: Int
        let maxTurns: Int
        let template: String
        let rounds: Int
        let useProjectContext: Bool
        let projectDir: String
        let brainDir: String
        var runDeadlineSec: Int = 0
    }

    struct Callbacks {
        var onPhase: (FanOutPhase) -> Void = { _ in }
        var onAngle: (String, TopicStatus) -> Void = { _, _ in }
        var onRound: (Int, [ResearchAngle]) -> Void = { _, _ in }
        var onActivity: (LiveSnapshot) -> Void = { _ in }
        var onProgress: (RunProgress) -> Void = { _ in }
        var onRecord: (RunStreamParser.RecordLocation) -> Void = { _ in }
        var onGraph: (ResearchGraph) -> Void = { _ in }
        var onEvidence: (RunEvidence) -> Void = { _ in }
        var onRefusal: (RunStreamParser.Refusal) -> Void = { _ in }
    }

    private static let pollInterval: Duration = .milliseconds(300)
    private static let silenceBeforeLivenessCheck: TimeInterval = 20
    private static let recordSettleAttempts = 20

    static func start(launch: EngineLaunch, keys: [String: String], config: Config, deadline: Date?,
                      store: URL, replaying fixture: String? = nil) async -> Result<RunCreated, EngineFailure> {
        var stdinConfig = config
        if let deadline { stdinConfig.runDeadlineSec = max(0, Int(deadline.timeIntervalSinceNow)) }
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        guard let body = try? JSONEncoder().encode(stdinConfig) else {
            return .failure(EngineFailure(reason: "the run's settings could not be encoded"))
        }
        let result = await EngineProcess.run(launch: launch, command: EngineCommand.detachedRun(store: store, replay: fixture),
                                             stdin: body, environment: keys)
        guard let result else {
            return .failure(EngineFailure(reason: "Failed to launch quorum-engine at \(launch.executable)"))
        }
        return EngineReply.runCreated(result.stdout)
    }

    static func cancel(launch: EngineLaunch, runID: String, store: URL) async -> EngineFailure? {
        guard let result = await EngineProcess.run(launch: launch, command: EngineCommand.cancel(runID: runID, store: store)) else {
            return EngineFailure(reason: "Failed to launch quorum-engine at \(launch.executable)")
        }
        return EngineReply.cancelled(result.stdout)
    }

    static func list(launch: EngineLaunch, store: URL) async -> [RunIndexEntry] {
        guard let result = await EngineProcess.run(launch: launch, command: EngineCommand.list(store: store)) else { return [] }
        return EngineReply.runIndex(result.stdout)
    }

    static func doctor(launch: EngineLaunch, store: URL) async -> [EngineDoctorCheck] {
        guard let result = await EngineProcess.run(launch: launch, command: EngineCommand.doctor(store: store)) else { return [] }
        return EngineReply.doctor(result.stdout)
    }

    static func watch(runDir: URL, launch: EngineLaunch, store: URL, clock: RunClock, notifier: Notifier,
                      callbacks: Callbacks, seedGraph: ResearchGraph) async -> StoredRun? {
        let tail = EventLogTail(url: runDir.appendingPathComponent("events.ndjson"))
        var perAngle: [String: AngleAccumulator] = [:]
        var dirtyAngles: Set<String> = []
        var graph = seedGraph
        var evidence = RunEvidence()
        var graphChanged = false
        var evidenceChanged = false
        var finished = false
        var mismatchedProtocol: Int?
        var sawProtocol = false

        func handle(_ line: String) {
            guard let ev = RunStreamParser.parse(line) else { return }
            switch ev {
            case .phase(let p):
                callbacks.onPhase(FanOutPhase(wire: p))
            case .plan(let angles):
                callbacks.onRound(1, angles.map(researchAngle))
            case .round(let r, let angles):
                callbacks.onRound(r, angles.map(researchAngle))
            case .angleStatus(let id, let s):
                callbacks.onAngle(id, mapStatus(s))
            case .activity(let id, let sl):
                var acc = perAngle[id] ?? AngleAccumulator()
                acc.ingest(sl, at: clock.now())
                perAngle[id] = acc
                dirtyAngles.insert(id)
            case .progress(let progress):
                callbacks.onProgress(progress)
            case .runResult(let rr):
                finished = true
                if let refusal = rr.refusal { callbacks.onRefusal(refusal) }
            case .runStart(_, let protocolVersion, _, let record):
                sawProtocol = true
                if !RunStreamParser.accepts(protocolVersion: protocolVersion) { mismatchedProtocol = protocolVersion }
                if let record { callbacks.onRecord(record) }
            case .document, .topicResult, .graphNode, .graphEdge, .graphNodeUpdate, .heartbeat, .other:
                break
            }
            graph.apply(ev)
            graphChanged = true
            if evidence.apply(ev) { evidenceChanged = true }
            if case .topicResult = ev, let stored = StoredRun.load(runDir) {
                evidence.absorb(stored)
                evidenceChanged = true
            }
        }

        func flush() {
            for id in dirtyAngles { if let acc = perAngle[id] { callbacks.onActivity(acc.snapshot(topicID: id)) } }
            dirtyAngles.removeAll()
            if graphChanged { callbacks.onGraph(graph); graphChanged = false }
            if evidenceChanged { callbacks.onEvidence(evidence); evidenceChanged = false }
        }

        var lastLine = Date()
        while !Task.isCancelled && !finished && mismatchedProtocol == nil {
            let lines = tail.newLines()
            for line in lines { handle(line) }
            flush()
            if !lines.isEmpty { lastLine = Date() }
            if finished || mismatchedProtocol != nil { break }
            if Date().timeIntervalSince(lastLine) > silenceBeforeLivenessCheck {
                lastLine = Date()
                if !(await stillRunning(runDir: runDir, launch: launch, store: store)) { break }
            }
            try? await Task.sleep(for: pollInterval)
        }
        if Task.isCancelled { return nil }
        if let spoken = mismatchedProtocol {
            callbacks.onRefusal(engineFailure("quorum-engine's run stream names protocol v\(spoken); this app reads exactly "
                                              + "v\(RunStreamParser.supportedProtocolVersion). Rebuild the engine."))
            return nil
        }
        _ = sawProtocol
        guard let stored = await settledRecord(runDir) else {
            callbacks.onRefusal(engineFailure("quorum-engine wrote no run record."))
            return nil
        }
        if stored.isRunning {
            callbacks.onRefusal(engineFailure("quorum-engine stopped before it finished the run."))
        } else if stored.record.status == .crashed {
            callbacks.onRefusal(engineFailure(stored.record.statusNote ?? "quorum-engine stopped before it finished the run."))
        }
        evidence.absorb(stored)
        callbacks.onEvidence(evidence)
        callbacks.onPhase(.done)
        notifier.notifyRunFinished(stored)
        return stored
    }

    private static func stillRunning(runDir: URL, launch: EngineLaunch, store: URL) async -> Bool {
        _ = await list(launch: launch, store: store)
        return StoredRun.load(runDir)?.isRunning ?? false
    }

    private static func settledRecord(_ runDir: URL) async -> StoredRun? {
        for _ in 0..<recordSettleAttempts {
            if let stored = StoredRun.load(runDir), !stored.isRunning { return stored }
            try? await Task.sleep(for: pollInterval)
        }
        return StoredRun.load(runDir)
    }

    private static func researchAngle(_ a: RunStreamParser.PlannedAngle) -> ResearchAngle {
        ResearchAngle(id: a.angleID, title: a.title, prompt: a.prompt)
    }

    private static func mapStatus(_ s: String) -> TopicStatus {
        switch s {
        case "running": return .running
        case "complete": return .complete
        case "halted": return .haltedSpend
        case "error": return .error
        default: return .running
        }
    }

    private static func engineFailure(_ reason: String) -> RunStreamParser.Refusal {
        RunStreamParser.Refusal(kind: "engine_failed", reason: reason)
    }
}

enum EngineProcess {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(launch: EngineLaunch, command: [String], stdin: Data? = nil,
                    environment: [String: String] = [:]) async -> Result? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launch.executable)
                process.arguments = launch.arguments(for: command)
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, injected in injected }
                let input = Pipe(), output = Pipe(), errors = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = errors
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                if let stdin { input.fileHandleForWriting.write(stdin) }
                try? input.fileHandleForWriting.close()
                let errorTail = StderrTail()
                errorTail.drain(errors)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let diagnostics = errorTail.finish(errors)
                continuation.resume(returning: Result(status: process.terminationStatus,
                                                      stdout: String(data: data, encoding: .utf8) ?? "",
                                                      stderr: diagnostics))
            }
        }
    }
}

private struct AngleAccumulator {
    private var text = "", thinking = "", cost = Decimal(0)
    private var sources: [LiveSource] = []
    private var sawDeltas = false
    private var writingStartedAt: Date?

    mutating func ingest(_ ev: CLIStream.Line, at now: Date) {
        if let d = ev.deltaText { text += d; sawDeltas = true }
        if let dt = ev.deltaThinking { thinking += dt; sawDeltas = true }
        if !sawDeltas {
            if let t = ev.assistantText { text += t }
            if let th = ev.thinking { thinking += th }
        }
        for tu in ev.toolUses where !tu.detail.isEmpty {
            sources.append(LiveSource(kind: tu.name, value: tu.detail, at: now))
        }
        if let c = ev.totalCostUSD, c > cost { cost = c }
        if writingStartedAt == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            writingStartedAt = now
        }
    }

    func snapshot(topicID: String) -> LiveSnapshot {
        LiveSnapshot(topicID: topicID, question: "", thinking: thinking, output: text,
                     sources: sources, costUSD: cost, writingStartedAt: writingStartedAt)
    }
}

import Foundation
import QuorumCore

enum EngineRunFanOut {

    struct Launch: Equatable {
        let executable: String
        let arguments: [String]

        init(executable: String, arguments: [String] = []) {
            self.executable = executable
            self.arguments = arguments
        }

        init?(_ resolution: EngineResolution) {
            guard let path = resolution.path else { return nil }
            self.init(executable: path, arguments: resolution.arguments)
        }

        func running(replaying fixture: String?) -> [String] {
            arguments + ["run"] + (fixture.map { ["--replay", $0] } ?? [])
        }
    }

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

    static func run(launch: Launch, keys: [String: String], engineConfig: Config,
                    run config: RunSettings, clock: RunClock, notifier: Notifier,
                    onPhase: @escaping (FanOutPhase) -> Void,
                    onAngle: @escaping (String, TopicStatus) -> Void,
                    onRound: @escaping (Int, [ResearchAngle]) -> Void,
                    onActivity: @escaping (LiveSnapshot) -> Void,
                    onRecord: @escaping (RunStreamParser.RecordLocation) -> Void = { _ in },
                    onGraph: @escaping (ResearchGraph) -> Void = { _ in },
                    onEvidence: @escaping (RunEvidence) -> Void = { _ in },
                    onRefusal: @escaping (RunStreamParser.Refusal) -> Void = { _ in },
                    seedGraph: ResearchGraph = ResearchGraph(),
                    replaying fixture: String? = nil) async -> StoredRun? {
        let startedAt = clock.now()
        var stdinConfig = engineConfig
        if let deadline = config.runDeadline {
            stdinConfig.runDeadlineSec = max(0, Int(deadline.timeIntervalSince(startedAt)))
        }

        var perAngle: [String: AngleAccumulator] = [:]
        var mismatchedProtocol = false
        var spokenProtocol: Int?
        var location: RunStreamParser.RecordLocation?
        var graph = seedGraph
        var evidence = RunEvidence()

        func handle(_ line: String) {
            guard let ev = RunStreamParser.parse(line) else { return }
            switch ev {
            case .phase(let p):
                onPhase(FanOutPhase(wire: p))
            case .plan(let angles):
                onRound(1, angles.map(researchAngle))
            case .round(let r, let angles):
                onRound(r, angles.map(researchAngle))
            case .angleStatus(let id, let s):
                onAngle(id, mapStatus(s))
            case .activity(let id, let sl):
                var acc = perAngle[id] ?? AngleAccumulator()
                acc.ingest(sl, at: clock.now())
                perAngle[id] = acc
                onActivity(acc.snapshot(topicID: id))
            case .runResult(let rr):
                if let refusal = rr.refusal { onRefusal(refusal) }
            case .runStart(_, let protocolVersion, _, let record):
                spokenProtocol = protocolVersion
                mismatchedProtocol = !RunStreamParser.accepts(protocolVersion: protocolVersion)
                if let record {
                    location = record
                    onRecord(record)
                }
            case .document, .topicResult, .graphNode, .graphEdge, .graphNodeUpdate, .other:
                break
            }
            graph.apply(ev)
            onGraph(graph)
            var changed = evidence.apply(ev)
            if case .topicResult = ev, let location, let stored = StoredRun.load(location.runDir) {
                evidence.absorb(stored)
                changed = true
            }
            if changed { onEvidence(evidence) }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.running(replaying: fixture)
        process.currentDirectoryURL = config.brainURL
        try? FileManager.default.createDirectory(at: config.brainURL, withIntermediateDirectories: true)
        process.environment = ProcessInfo.processInfo.environment.merging(keys) { _, injected in injected }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() } catch {
            onRefusal(engineFailure("Failed to launch quorum-engine: \(error.localizedDescription)"))
            return nil
        }
        let stderrTail = StderrTail()
        stderrTail.drain(stderr)
        if let data = try? JSONEncoder().encode(stdinConfig) {
            stdin.fileHandleForWriting.write(data)
            stdin.fileHandleForWriting.write(Data("\n".utf8))
        }
        try? stdin.fileHandleForWriting.close()

        do {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                if Task.isCancelled { process.terminate() }
                handle(line)
                if mismatchedProtocol { process.terminate(); break }
            }
        } catch {}
        process.waitUntilExit()
        let diagnostics = stderrTail.finish(stderr)
        if mismatchedProtocol {
            let spoken = spokenProtocol.map { "protocol v\($0)" } ?? "no protocol version"
            onRefusal(engineFailure("quorum-engine's run stream names \(spoken); this app reads exactly "
                                    + "v\(RunStreamParser.supportedProtocolVersion). Rebuild the engine."))
            return nil
        }
        guard let location, let stored = StoredRun.load(location.runDir) else {
            let detail = diagnostics.isEmpty ? "" : " stderr: \(diagnostics.suffix(600))"
            onRefusal(engineFailure("quorum-engine wrote no run record.\(detail)"))
            return nil
        }
        if stored.isRunning {
            let detail = diagnostics.isEmpty ? "" : " stderr: \(diagnostics.suffix(600))"
            onRefusal(engineFailure("quorum-engine stopped before it finished the run.\(detail)"))
        }
        evidence.absorb(stored)
        onEvidence(evidence)
        onPhase(.done)
        notifier.notifyRunFinished(stored)
        return stored
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

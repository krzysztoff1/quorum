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
        /// Who judges the answer (PRD 06 R7): cheap, tool-less, and — where keys allow — from a different
        /// family than the model that drafted what it reads.
        let validatorModel: String
        let effort: String
        let perTopicBudgetUSD: Double
        let runBudgetUSD: Double
        let perTopicTimeoutSec: Int
        let maxTurns: Int
        let priorNotesExcerpt: String
        let template: String
        /// The validator loop's round cap: the engine only spends a round past the first on objections its
        /// own validators filed and could not dedup away.
        let rounds: Int
        let useProjectContext: Bool
        let projectDir: String
        /// `<runDir>/evidence` — where the engine and its `mcp-serve` child append captured documents
        /// (PRD 03). Filled in by `run` from the run directory, so the two can never drift apart.
        var evidenceDir: String = ""
        /// PRD 04. `ask` by default: an angle may raise a question mid-run, but nothing is spent on it
        /// until the user approves it on the canvas. The directory doubles as the queue a Claude Code
        /// angle files into, since its `mcp-serve` child cannot reach this process any other way.
        var spawnMode: String = "ask"
        var spawnDir: String = ""
        /// The wall the spawn freeze is measured against. Past 70% of it, no new question is taken up and
        /// anything still pending expires, so a run nobody is watching still reaches its synthesis.
        var runDeadlineSec: Int = 0
        /// How long a question the run raised stays approvable. The run never waits on it — the wave carries
        /// on and an approval joins the wave that is still running — so this only decides when an offer
        /// nobody took stops being live on the canvas.
        var approvalWindowSec: Int = 300
    }

    static func run(launch: Launch, keys: [String: String], engineConfig: Config,
                    run config: RunSettings, priorNotes: [URL], store: FindingsStore,
                    runDir: URL?, clock: RunClock, notifier: Notifier,
                    onPhase: @escaping (FanOutPhase) -> Void,
                    onAngle: @escaping (String, TopicStatus) -> Void,
                    onRound: @escaping (Int, [ResearchAngle]) -> Void,
                    onActivity: @escaping (LiveSnapshot) -> Void,
                    onGraph: @escaping (ResearchGraph) -> Void = { _ in },
                    onEvidence: @escaping (RunEvidence) -> Void = { _ in },
                    onApprovals: @escaping (RunControlChannel) -> Void = { _ in },
                    seedGraph: ResearchGraph = ResearchGraph(),
                    engine handshake: EngineHandshake? = nil,
                    replaying fixture: String? = nil) async -> RunReport {
        let startedAt = clock.now()
        // Evidence lands beside the run's other artifacts; `SourceDocument` paths stay relative to it, so
        // the app never rewrites what the engine wrote (PRD 03).
        let evidenceDir = runDir?.appendingPathComponent("evidence", isDirectory: true)
        if let evidenceDir {
            try? FileManager.default.createDirectory(at: evidenceDir, withIntermediateDirectories: true)
        }
        var stdinConfig = engineConfig
        stdinConfig.evidenceDir = evidenceDir?.path ?? ""
        stdinConfig.spawnDir = evidenceDir?.path ?? ""
        if let deadline = config.runDeadline {
            stdinConfig.runDeadlineSec = max(0, Int(deadline.timeIntervalSince(startedAt)))
        }

        var perAngle: [String: AngleAccumulator] = [:]
        var total = Decimal(0)
        var mismatchedProtocol = false
        var spokenProtocol: Int?
        var windDownNote: String?
        var graph = seedGraph
        var evidence = RunEvidence()
        let persistence = EngineRunPersistence(question: engineConfig.question, config: config,
                                               store: store, runDir: runDir, priorNotes: priorNotes)

        func handle(_ line: String) {
            guard let ev = RunStreamParser.parse(line) else { return }
            persistence.apply(ev, raw: line, at: clock.now())
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
                total = rr.totalCostUSD
                windDownNote = rr.note
            case .runStart(_, let protocolVersion, _):
                spokenProtocol = protocolVersion
                mismatchedProtocol = !RunStreamParser.accepts(protocolVersion: protocolVersion)
            case .document, .topicResult, .graphNode, .graphEdge, .graphNodeUpdate, .other:
                break
            }
            // Every event the graph knows how to read feeds it, including the ones handled above — the
            // shape on screen is a fold of the same stream, not a second account of it. The rail beside it
            // reads the same stream for the prose and the quotes behind it.
            graph.apply(ev)
            onGraph(graph)
            if evidence.apply(ev) { onEvidence(evidence) }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.running(replaying: fixture)
        process.currentDirectoryURL = config.projectURL
        var environment = ProcessInfo.processInfo.environment.merging(keys) { _, injected in injected }
        // Also on the environment: the `mcp-serve` process that serves the claude-code backend's fetches
        // is a grandchild of this one, and captures documents into the same directory.
        if let evidenceDir { environment["QUORUM_EVIDENCE_DIR"] = evidenceDir.path }
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() } catch {
            return errorReport(startedAt: startedAt, clock: clock, config: config,
                               note: "Failed to launch quorum-engine: \(error.localizedDescription)")
        }
        let stderrTail = StderrTail()
        stderrTail.drain(stderr)
        // Config on stdin (no secrets — keys ride the environment). stdin then stays OPEN for the run:
        // `ask` mode answers a pending question on the same pipe, so closing it here would make every
        // spawn expire unanswered.
        if let data = try? JSONEncoder().encode(stdinConfig) {
            stdin.fileHandleForWriting.write(data)
            stdin.fileHandleForWriting.write(Data("\n".utf8))
        }
        let approvals = controlChannel(over: stdin.fileHandleForWriting)
        onApprovals(approvals)
        defer { approvals.close() }

        do {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                if Task.isCancelled { process.terminate() }   // engine traps SIGTERM → graceful wind-down
                handle(line)
                if mismatchedProtocol { process.terminate(); break }
            }
        } catch { /* pipe read error — file whatever completed */ }
        process.waitUntilExit()
        let diagnostics = stderrTail.finish(stderr)
        if mismatchedProtocol {
            let spoken = spokenProtocol.map { "protocol v\($0)" } ?? "no protocol version"
            return errorReport(startedAt: startedAt, clock: clock, config: config,
                               note: "quorum-engine's run stream names \(spoken); this app reads exactly v\(RunStreamParser.supportedProtocolVersion). Rebuild the engine.")
        }
        if persistence.entries.isEmpty, total == 0, !diagnostics.isEmpty {
            return errorReport(startedAt: startedAt, clock: clock, config: config,
                               note: "quorum-engine produced no results. stderr: \(diagnostics.suffix(600))")
        }

        persistence.flush(at: clock.now())
        let report = RunReport(startedAt: startedAt, finishedAt: clock.now(), entries: persistence.entries,
                               totalCostUSD: total, runSpendCapUSD: config.runSpendCapUSD, profile: config.profile,
                               validation: persistence.validation,
                               pipeline: .engine(protocolVersion: spokenProtocol, handshake: handshake),
                               windDownNote: windDownNote)
        if let runDir { _ = try? store.writeDigest(report, inRunDirectory: runDir) }
        onPhase(.done)
        notifier.notifyRunFinished(report)
        return report
    }

    /// The way back into a running engine. `ask` mode makes the run's stdin a two-way channel for its whole
    /// life, so a verdict the user gives on the canvas reaches the orchestrator that is waiting for it.
    static func controlChannel(over handle: FileHandle?) -> RunControlChannel {
        RunControlChannel(onClose: { try? handle?.close() }) { line in
            guard let handle else { return }
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
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

    private static func errorReport(startedAt: Date, clock: RunClock, config: RunSettings, note: String) -> RunReport {
        RunReport(startedAt: startedAt, finishedAt: clock.now(),
                  entries: [RunReport.TopicEntry(
                    id: UUID().uuidString, question: note, status: .error, preset: config.defaultPreset,
                    headline: "Engine run failed", confidenceSummary: "—", sourcesConsulted: 0,
                    costUSD: 0, durationSeconds: 0, note: note, notePath: nil, transcriptPath: nil)],
                  totalCostUSD: 0, runSpendCapUSD: config.runSpendCapUSD, profile: config.profile)
    }
}

/// Accumulates one angle's streamed deltas/tool-uses/cost into the cumulative snapshot the viz shows —
/// keyed by angle in the run.
private struct AngleAccumulator {
    private var text = "", thinking = "", cost = Decimal(0)
    private var sources: [LiveSource] = []
    private var sawDeltas = false
    private var writingStartedAt: Date?

    mutating func ingest(_ ev: ResearchOutputParser.StreamLine, at now: Date) {
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

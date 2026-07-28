import Foundation
import QuorumCore

/// The Swift thin client over the engine's `run` command (fan-out in TS). Spawns `quorum-engine run`
/// (config on stdin, keys in env), consumes the run-level stream to drive the live radial viz, and files
/// each round's results into the brain via the SAME `persistFanOutRound` the Swift orchestrator uses —
/// so the app above this seam is unchanged whether the fan-out ran in Swift or TS. Storage stays here;
/// only orchestration moved. Cancelling the Task pulls the cord: the engine gets SIGTERM and winds down.
enum EngineRunFanOut {

    struct ConfigAngle: Encodable { let title: String; let prompt: String }

    struct Config: Encodable {
        let question: String
        let angleCount: Int
        let angles: [ConfigAngle]   // user-approved round-1 angles; when non-empty the engine skips round-1 planning
        let angleModel: String
        let synthesisModel: String
        let effort: String
        let perTopicBudgetUSD: Double
        let runBudgetUSD: Double
        let perTopicTimeoutSec: Int
        let maxTurns: Int
        let priorNotesExcerpt: String
        let template: String
        let rounds: Int
        let autoresearch: Bool
        let useProjectContext: Bool
        let projectDir: String
        /// `<runDir>/evidence` — where the engine and its `mcp-serve` child append captured documents
        /// (PRD 03). Filled in by `run` from the run directory, so the two can never drift apart.
        var evidenceDir: String = ""
    }

    static func run(binaryPath: String, keys: [String: String], engineConfig: Config,
                    run config: RunSettings, priorNotes: [URL], store: FindingsStore,
                    runDir: URL?, clock: RunClock, notifier: Notifier,
                    onPhase: @escaping (FanOutPhase) -> Void,
                    onAngle: @escaping (String, TopicStatus) -> Void,
                    onRound: @escaping (Int, [ResearchAngle]) -> Void,
                    onActivity: @escaping (LiveSnapshot) -> Void,
                    mockLines: [String]? = nil) async -> RunReport {
        let startedAt = clock.now()
        // Evidence lands beside the run's other artifacts; `SourceDocument` paths stay relative to it, so
        // the app never rewrites what the engine wrote (PRD 03).
        let evidenceDir = runDir?.appendingPathComponent("evidence", isDirectory: true)
        if let evidenceDir {
            try? FileManager.default.createDirectory(at: evidenceDir, withIntermediateDirectories: true)
            if mockLines != nil { MockEngineRun.materializeEvidence(into: evidenceDir) }
        }
        var stdinConfig = engineConfig
        stdinConfig.evidenceDir = evidenceDir?.path ?? ""

        var titles: [String: String] = [:]
        var perAngle: [String: AngleAccumulator] = [:]
        var roundAngles: [RunStreamParser.TopicResultEvent] = []
        var roundSynthesis: RunStreamParser.TopicResultEvent?
        var allEntries: [RunReport.TopicEntry] = []
        var currentRound = 1
        var total = Decimal(0)
        var unsupportedProtocol: Int?
        // The run-wide captured-source registry. Documents dedupe by source id across angles, so every
        // writeup resolves its markers against the same sources; the quotes themselves stay on the topic
        // that reported them, where their `c1`-per-topic ids can't cross wires.
        var registry = EvidenceIndex()

        func persistRound() {
            guard let synth = roundSynthesis else { return }
            let angleFindings = roundAngles.map { $0.toFindings() }
            let angleTitles = roundAngles.map { titles[$0.angleID] ?? $0.model }
            let entries = persistFanOutRound(
                synthesis: synth.toFindings(), angleFindings: angleFindings, angleTitles: angleTitles,
                question: engineConfig.question, config: config, store: store, runDir: runDir,
                priorNotes: priorNotes, round: currentRound, at: clock.now(), evidence: registry)
            allEntries += entries
            roundAngles = []; roundSynthesis = nil
        }

        func handle(_ line: String) {
            guard let ev = RunStreamParser.parse(line) else { return }
            switch ev {
            case .phase(let p):
                onPhase(mapPhase(p))
            case .plan(let angles):
                currentRound = 1
                for a in angles { titles[a.angleID] = a.title }
                onRound(1, angles.map(researchAngle))
            case .round(let r, let angles):
                currentRound = r
                for a in angles { titles[a.angleID] = a.title }
                onRound(r, angles.map(researchAngle))
            case .angleStatus(let id, let s):
                onAngle(id, mapStatus(s))
            case .document(_, let doc):
                registry = registry.merging(EvidenceIndex(documents: [doc]))
            case .activity(let id, let sl):
                var acc = perAngle[id] ?? AngleAccumulator()
                acc.ingest(sl, at: clock.now())
                perAngle[id] = acc
                onActivity(acc.snapshot(topicID: id))
            case .topicResult(let tr):
                if tr.role == "synthesis" { roundSynthesis = tr } else { roundAngles.append(tr) }
                if roundSynthesis != nil { persistRound() }   // synthesis closes the round → file it now
            case .runResult(let rr):
                total = rr.totalCostUSD
                registry = registry.merging(rr.evidence)   // before persisting: the round files the full registry
                if roundSynthesis != nil { persistRound() }
            case .runStart(_, let protocolVersion):
                // Refuse a stream NEWER than we were built against; an older (or absent) version still runs,
                // since every event we read is additive.
                if let protocolVersion, protocolVersion > RunStreamParser.supportedProtocolVersion {
                    unsupportedProtocol = protocolVersion
                }
            case .other:
                break
            }
        }

        if let mockLines {
            for line in mockLines {
                if Task.isCancelled || unsupportedProtocol != nil { break }
                handle(line)
                try? await Task.sleep(for: .milliseconds(140))
            }
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = ["run"]
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
            // Config on stdin (no secrets — keys ride the environment); close so the engine starts.
            if let data = try? JSONEncoder().encode(stdinConfig) {
                stdin.fileHandleForWriting.write(data)
            }
            try? stdin.fileHandleForWriting.close()

            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    if Task.isCancelled { process.terminate() }   // engine traps SIGTERM → graceful wind-down
                    handle(line)
                    if unsupportedProtocol != nil { process.terminate(); break }
                }
            } catch { /* pipe read error — file whatever completed */ }
            process.waitUntilExit()
            let diagnostics = stderrTail.finish(stderr)
            if let version = unsupportedProtocol {
                return errorReport(startedAt: startedAt, clock: clock, config: config,
                                   note: "quorum-engine speaks protocol v\(version); this app supports v\(RunStreamParser.supportedProtocolVersion). Update the app or rebuild the bundled engine.")
            }
            if allEntries.isEmpty, total == 0, !diagnostics.isEmpty {
                return errorReport(startedAt: startedAt, clock: clock, config: config,
                                   note: "quorum-engine produced no results. stderr: \(diagnostics.suffix(600))")
            }
        }

        let report = RunReport(startedAt: startedAt, finishedAt: clock.now(), entries: allEntries,
                               totalCostUSD: total, runSpendCapUSD: config.runSpendCapUSD, profile: config.profile)
        if let runDir { _ = try? store.writeDigest(report, inRunDirectory: runDir) }
        onPhase(.done)
        notifier.notifyRunFinished(report)
        return report
    }

    private static func researchAngle(_ a: RunStreamParser.PlannedAngle) -> ResearchAngle {
        ResearchAngle(id: a.angleID, title: a.title, prompt: a.prompt)
    }

    private static func mapPhase(_ p: String) -> FanOutPhase {
        switch p {
        case "planning": return .planning
        case "researching": return .researching
        case "synthesizing", "reconciling": return .synthesizing
        case "grounding": return .verifying
        case "done": return .done
        default: return .researching
        }
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
/// the per-angle analogue of `ResearchStream`'s single-topic accumulation, keyed by angle in the run.
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

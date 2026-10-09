import Foundation

public final class EngineRunPersistence {
    private let question: String
    private let config: RunSettings
    private let store: FindingsStore
    private let runDir: URL?
    private let priorNotes: [URL]
    private let preDiveBody: String?

    private var titles: [String: String] = [:]
    private var round = 1
    private var angles: [RunStreamParser.TopicResultEvent] = []
    private var synthesis: RunStreamParser.TopicResultEvent?
    private var registry = EvidenceIndex()
    private var verdicts: [RunValidation.Verdict] = []
    private var streams: [String: String] = [:]

    public private(set) var entries: [RunReport.TopicEntry] = []
    /// What the loop made of the answer, kept so a finished run's canvas can draw the judgements a live one
    /// drew off the stream (PRD 09 R1).
    public private(set) var validation: RunValidation?

    public init(question: String, config: RunSettings, store: FindingsStore,
                runDir: URL?, priorNotes: [URL]) {
        self.question = question
        self.config = config
        self.store = store
        self.runDir = runDir
        self.priorNotes = priorNotes
        self.preDiveBody = store.noteBody(matching: question, in: config.projectURL)
    }

    public func apply(_ event: RunStreamParser.Event, raw: String? = nil, at now: Date) {
        switch event {
        case .activity(let angleID, _):
            if let raw { streams[angleID, default: ""] += raw + "\n" }
        case .plan(let planned):
            round = 1
            remember(planned)
        case .round(let number, let planned):
            round = number
            remember(planned)
        case .runStart(_, _, let grounding):
            registry = registry.withGrounding(grounding)
        case .document(_, let document):
            registry = registry.merging(EvidenceIndex(documents: [document]))
        case .graphNode(let node):
            if node.kind == GraphNodeKind.verdict.rawValue { verdicts.append(RunValidation.Verdict(node)) }
        case .topicResult(let result):
            if result.role == "synthesis" { synthesis = result } else { angles.append(result) }
            if answerAwaitsItsJudgement { return }
            fileClosedRound(at: now)
        case .runResult(let result):
            registry = registry.merging(result.evidence)
            validation = result.validation.map { RunValidation($0, verdicts: verdicts) }
            fileClosedRound(at: now)
        default:
            break
        }
    }

    /// The end of the stream, however it ended. An engine that died before reporting its run still leaves
    /// whatever answer it had reached filed, unjudged rather than lost.
    public func flush(at now: Date) {
        fileClosedRound(at: now)
    }

    /// The terminal answer is exported with what the validators made of it, and that summary lands one
    /// event after the answer does — so the fused answer waits for the run to report rather than shipping
    /// a verdict it does not have yet (PRD 09 R4).
    private var answerAwaitsItsJudgement: Bool {
        synthesis?.reconciled == true && validation == nil
    }

    private func remember(_ planned: [RunStreamParser.PlannedAngle]) {
        for angle in planned { titles[angle.angleID] = angle.title }
    }

    private func fileClosedRound(at now: Date) {
        guard let closing = synthesis else { return }
        synthesis = nil
        let material = angles
        angles = []
        entries += closing.reconciled
            ? fileReconciliation(closing, at: now)
            : persistFanOutRound(synthesis: findings(closing),
                                 angleFindings: material.map(findings),
                                 angleTitles: material.map { titles[$0.angleID] ?? $0.model },
                                 question: question, config: config, store: store, runDir: runDir,
                                 priorNotes: priorNotes, round: round, at: now, evidence: registry)
    }

    private func findings(_ result: RunStreamParser.TopicResultEvent) -> TopicFindings {
        let transcript = streams.removeValue(forKey: result.angleID) ?? ""
        return result.toFindings(preset: config.defaultPreset, transcript: transcript)
    }

    private func fileReconciliation(_ fused: RunStreamParser.TopicResultEvent,
                                    at now: Date) -> [RunReport.TopicEntry] {
        let summary = withValidation(withRegistry(findings(fused), registry),
                                     validation)
        // The fused answer stands on the whole dive's reading, not on its own reference list.
        let sources = Reporter.distinctSources(entries.flatMap { $0.findings ?? [] } + summary.findings)
        var notePath: String?, transcriptPath: String?, action: NoteAction?
        if let runDir,
           let written = try? store.writeReconciliation(summary, question: question,
                                                        relatedLinks: relatedLinks(), brain: config.projectURL,
                                                        runDir: runDir, preDiveBody: preDiveBody, at: now,
                                                        sourcesConsulted: sources) {
            notePath = written.note.path
            transcriptPath = written.transcript.path
            action = written.action
        }
        return [entry(from: summary, question: question, notePath: notePath, noteAction: action,
                      transcriptPath: transcriptPath, isSynthesis: true, round: nil,
                      sourcesConsulted: sources)]
    }

    private func relatedLinks() -> [URL] {
        let artifacts = entries.filter { $0.isSynthesis != true }
            .compactMap { $0.notePath.map { URL(fileURLWithPath: $0) } }
        return store.relatedNotes(to: question, in: config.projectURL) + artifacts
    }
}

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

    public private(set) var entries: [RunReport.TopicEntry] = []

    public init(question: String, config: RunSettings, store: FindingsStore,
                runDir: URL?, priorNotes: [URL]) {
        self.question = question
        self.config = config
        self.store = store
        self.runDir = runDir
        self.priorNotes = priorNotes
        self.preDiveBody = store.noteBody(matching: question, in: config.projectURL)
    }

    public func apply(_ event: RunStreamParser.Event, at now: Date) {
        switch event {
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
        case .topicResult(let result):
            if result.role == "synthesis" { synthesis = result } else { angles.append(result) }
            fileClosedRound(at: now)
        case .runResult(let result):
            registry = registry.merging(result.evidence)
            fileClosedRound(at: now)
        default:
            break
        }
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
            : persistFanOutRound(synthesis: closing.toFindings(preset: config.defaultPreset),
                                 angleFindings: material.map { $0.toFindings(preset: config.defaultPreset) },
                                 angleTitles: material.map { titles[$0.angleID] ?? $0.model },
                                 question: question, config: config, store: store, runDir: runDir,
                                 priorNotes: priorNotes, round: round, at: now, evidence: registry)
    }

    private func fileReconciliation(_ fused: RunStreamParser.TopicResultEvent,
                                    at now: Date) -> [RunReport.TopicEntry] {
        let summary = withRegistry(fused.toFindings(preset: config.defaultPreset), registry)
        var notePath: String?, transcriptPath: String?, action: NoteAction?
        if let runDir,
           let written = try? store.writeReconciliation(summary, question: question,
                                                        relatedLinks: relatedLinks(), brain: config.projectURL,
                                                        runDir: runDir, preDiveBody: preDiveBody, at: now) {
            notePath = written.note.path
            transcriptPath = written.transcript.path
            action = written.action
        }
        return [entry(from: summary, question: question, notePath: notePath, noteAction: action,
                      transcriptPath: transcriptPath, isSynthesis: true, round: nil)]
    }

    private func relatedLinks() -> [URL] {
        let artifacts = entries.filter { $0.isSynthesis != true }
            .compactMap { $0.notePath.map { URL(fileURLWithPath: $0) } }
        return store.relatedNotes(to: question, in: config.projectURL) + artifacts
    }
}

import Foundation

public enum FanOutPhase: String, Sendable, Equatable, CaseIterable {
    case planning, researching, synthesizing, verifying, validating, done
}

public func persistFanOutRound(synthesis: TopicFindings, angleFindings: [TopicFindings],
                               angleTitles: [String], question: String, config: RunSettings,
                               store: FindingsStore, runDir: URL?, priorNotes: [URL], round: Int?,
                               at now: Date, evidence registry: EvidenceIndex = EvidenceIndex()) -> [RunReport.TopicEntry] {
    let summary = withRegistry(synthesis, registry)
    let angles = angleFindings.map { withRegistry($0, registry) }
    var entries: [RunReport.TopicEntry] = []
    var notePath: String?, noteAction: NoteAction?, transcriptPath: String?
    var artifacts: [String] = []
    var transcripts: [String?] = []
    if let runDir, let res = try? store.writeSynthesis(summary, question: question, angles: angles,
                                                       angleTitles: angleTitles, brain: config.projectURL,
                                                       priorNotes: priorNotes, runDir: runDir, at: now) {
        notePath = res.note.path; noteAction = res.action; transcriptPath = res.transcript.path
        artifacts = res.angleArtifacts.map(\.path)
        transcripts = res.angleTranscripts.map { $0?.path }
    }
    entries.append(entry(from: summary, question: question, notePath: notePath,
                         noteAction: noteAction, transcriptPath: transcriptPath, isSynthesis: true,
                         round: round, id: roundScopedSynthesisID(summary.id, round: round),
                         sourcesConsulted: Reporter.distinctSources(([summary] + angles).flatMap(\.findings))))
    for (i, f) in angles.enumerated() {
        let label = i < angleTitles.count ? angleTitles[i] : f.headline
        let art = i < artifacts.count ? artifacts[i] : nil
        let log = i < transcripts.count ? transcripts[i] : nil
        entries.append(entry(from: f, question: label, notePath: art, noteAction: nil, transcriptPath: log, round: round))
    }
    return entries
}

func roundScopedSynthesisID(_ id: String, round: Int?) -> String {
    guard let round, round > 1 else { return id }
    return "\(id)·round·\(round)"
}

func withRegistry(_ f: TopicFindings, _ registry: EvidenceIndex) -> TopicFindings {
    registry.hasNothingToSay ? f : rebuild(f, evidence: f.evidence.merging(registry))
}

func withValidation(_ f: TopicFindings, _ validation: RunValidation?) -> TopicFindings {
    validation.map { rebuild(f, validation: $0) } ?? f
}

private func rebuild(_ f: TopicFindings, withFindings findings: [Finding]? = nil,
                     evidence: EvidenceIndex? = nil, validation: RunValidation? = nil) -> TopicFindings {
    TopicFindings(id: f.id, status: f.status, preset: f.preset, headline: f.headline,
                  findings: findings ?? f.findings, conflicts: f.conflicts, gaps: f.gaps,
                  sourcesConsulted: f.sourcesConsulted,
                  costUSD: f.costUSD, duration: f.duration, writeupMarkdown: f.writeupMarkdown,
                  transcript: f.transcript, note: f.note, sessionID: f.sessionID, rateLimit: f.rateLimit,
                  usage: f.usage, evidence: evidence ?? f.evidence, validation: validation ?? f.validation)
}

func entry(from f: TopicFindings, question: String,
           notePath: String?, noteAction: NoteAction?, transcriptPath: String?,
           isSynthesis: Bool = false, round: Int? = nil, id: String? = nil,
           sourcesConsulted: Int? = nil) -> RunReport.TopicEntry {
    let sources = Reporter.distinctSourceURLs(f.findings)
    return RunReport.TopicEntry(
        id: id ?? f.id, question: question, status: f.status, preset: f.preset, headline: f.headline,
        confidenceSummary: Reporter.confidenceSummary(f.findings),
        sourcesConsulted: sourcesConsulted ?? sources.count,
        costUSD: f.costUSD, durationSeconds: f.duration.seconds, note: f.note,
        notePath: notePath, noteAction: noteAction, transcriptPath: transcriptPath, sessionID: f.sessionID,
        rateLimit: f.rateLimit, isSynthesis: isSynthesis, conflicts: f.conflicts, gaps: f.gaps, round: round,
        sources: sources, findings: f.findings, usage: f.usage,
        evidence: f.evidence.hasNothingToSay ? nil : f.evidence)
}

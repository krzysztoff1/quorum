import SwiftUI
import QuorumCore

struct TopicTarget: Hashable {
    let question: String
    let writeup: String?
    let sessionID: String?
    let brainPath: String
    var runDir: URL? = nil
    var taskID: String? = nil
    var isSynthesis = false
    var status: TopicStatus = .complete
    var headline = ""
    var claimsSummary = ""
    var sourcesLabel = ""
    var conflicts: [Conflict] = []
    var gaps: [String] = []
    var sources: [String] = []
    var caveat: String? = nil
    var angleCount = 0
    var rounds = 1
    var wasEngineRun = false
    var evidence: EvidenceContext? = nil
}

extension TopicTarget {
    static func from(_ task: RecordTask, in run: StoredRun) -> TopicTarget {
        let record = run.record
        let isAnswer = task.id == run.answerTask?.id
        let cited = Set(record.sources.filter(\.cited).map(\.url))
        return TopicTarget(
            question: isAnswer ? run.title : task.title,
            writeup: run.writeup(forNode: task.nodeID),
            sessionID: task.sessionID,
            brainPath: run.runDir.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().path,
            runDir: run.runDir,
            taskID: task.id,
            isSynthesis: task.kind == .synthesis || task.kind == .reconciliation,
            status: TopicStatus(record: task.status),
            headline: (isAnswer ? record.answer?.headline : nil) ?? task.headline ?? task.title,
            claimsSummary: isAnswer ? run.claimsSummary : "",
            sourcesLabel: isAnswer ? run.sourcesSummary : "\(task.sourceIDs.count) read",
            conflicts: isAnswer ? record.conflicts.map { Conflict(claim: $0.statement, positions: $0.positions) } : [],
            gaps: isAnswer ? record.gaps.map(\.text) : [],
            sources: isAnswer ? record.sources.filter(\.cited).map(\.url) : Array(cited),
            caveat: task.note ?? (isAnswer ? record.statusNote : nil),
            angleCount: record.stats.tasks,
            rounds: max(1, record.stats.rounds),
            wasEngineRun: task.backend != "cli",
            evidence: run.evidence(forNode: task.nodeID))
    }
}


import Foundation

public struct RunHeader: Sendable, Equatable {
    public let question: String
    public let headline: String
    public let claimsSummary: String
    public let status: TopicStatus
    public let trustLevel: RecordStatsTrustLevel
    public let sourcesCited: Int
    public let sourcesRead: Int
    public let conflicts: Int
    public let gaps: Int
    public let angleCount: Int
    public let rounds: Int
    public let costUSD: Decimal
    public let capUSD: Decimal?
    public let durationSeconds: Double
    public let isReconciled: Bool
    public let grounding: RunGrounding
    public let strippedMarkers: Int
    public let failedChecks: [RecordCheck]
    public let validation: RunValidation?

    public init(run: StoredRun) {
        let record = run.record
        let stats = record.stats
        question = run.title
        headline = record.answer?.headline ?? ""
        claimsSummary = run.claimsSummary
        status = TopicStatus(record: record.status)
        trustLevel = stats.trustLevel
        sourcesCited = stats.sourcesCited
        sourcesRead = stats.sourcesRead
        conflicts = stats.conflictsOpen
        gaps = stats.gaps
        angleCount = stats.tasks
        rounds = max(1, stats.rounds)
        costUSD = Decimal(stats.costUSD)
        capUSD = record.limits.capUSD.map { Decimal($0) }
        durationSeconds = stats.durationS
        isReconciled = run.answerTask?.kind == .reconciliation
        grounding = run.grounding
        strippedMarkers = stats.strippedMarkers
        failedChecks = record.checks.filter { $0.status == .fail }
        validation = run.validation
    }

    public var isValidated: Bool { grounding != .none }

    public var stayedUnderCap: Bool { capUSD.map { costUSD <= $0 } ?? true }

    public var unvalidatedNotice: String? {
        EvidenceIndex(grounding: grounding).unvalidatedNotice
    }

    public var outstandingObjections: Int { validation?.objectionsOutstanding.count ?? 0 }

    public var sourcesLabel: String { "\(sourcesCited) cited · \(sourcesRead) read" }

    public var roundsLabel: String {
        "\(angleCount) angle\(angleCount == 1 ? "" : "s")\(rounds > 1 ? " · \(rounds) rounds" : "")"
    }
}

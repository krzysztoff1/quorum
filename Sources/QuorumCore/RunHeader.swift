import Foundation

/// The run, read off its report in one place: what it answered, how solid that is, what it cost and what it
/// still has open. It was the digest list's job to assemble these in a view; the finished run now opens as
/// its graph, so the numbers are derived here and the strip over the canvas only draws them.
public struct RunHeader: Sendable, Equatable {
    public let question: String
    public let headline: String
    public let confidenceSummary: String
    public let status: TopicStatus?
    public let sourcesConsulted: Int
    public let conflicts: Int
    public let gaps: Int
    public let angleCount: Int
    public let rounds: Int
    public let costUSD: Decimal
    public let capUSD: Decimal
    public let stayedUnderCap: Bool
    public let durationSeconds: Double
    public let profile: RunProfile?
    /// A multi-round dive fused into one current answer, rather than the last round's synthesis standing in
    /// for the lot.
    public let isReconciled: Bool
    public let grounding: RunGrounding
    /// Nil where the run had no validator loop — an unjudged answer is not a failed one.
    public let validation: RunValidation?

    public init(report: RunReport) {
        // Last synthesis wins: the reconciliation is appended after the rounds, so it is what the dive
        // currently holds. Absent one, the final round's synthesis; absent that, the only topic there is.
        let answer = report.entries.last { $0.isSynthesis == true } ?? report.entries.first
        question = answer?.question ?? ""
        headline = answer?.headline ?? ""
        confidenceSummary = answer?.confidenceSummary ?? ""
        status = answer?.status
        sourcesConsulted = answer?.sourcesConsulted ?? 0
        conflicts = answer?.conflicts?.count ?? 0
        gaps = answer?.gaps?.count ?? 0
        angleCount = report.entries.filter { $0.isSynthesis != true && $0.status != .skipped }.count
        rounds = report.entries.compactMap(\.round).max() ?? 1
        costUSD = report.totalCostUSD
        capUSD = report.runSpendCapUSD
        stayedUnderCap = report.stayedUnderCap
        durationSeconds = report.totalDurationSeconds
        profile = report.profile
        isReconciled = answer?.noteAction == .reconciled
        grounding = report.grounding
        validation = report.validation
    }

    public var isValidated: Bool { grounding != .none }

    public var unvalidatedNotice: String? {
        EvidenceIndex(grounding: grounding).unvalidatedNotice
    }

    /// What the loop could not settle before the walls hit. A run with no loop has none — an unjudged answer
    /// is not a failed one.
    public var outstandingObjections: Int { validation?.objectionsOutstanding.count ?? 0 }

    public var roundsLabel: String {
        "\(angleCount) angle\(angleCount == 1 ? "" : "s")\(rounds > 1 ? " · \(rounds) rounds" : "")"
    }
}

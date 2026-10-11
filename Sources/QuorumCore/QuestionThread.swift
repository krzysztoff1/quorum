import Foundation

public extension StoredRun {
    var finishedAt: Date? { record.finishedAt.flatMap(Self.date) }
    var kind: RunRecordKind { record.kind }
    var hasAnswer: Bool { record.answer != nil && !isRunning }
    var tier: Tier? {
        switch record.brief.tier {
        case .quick: return .quick
        case .deep: return .deep
        case .unknown, nil: return nil
        }
    }
    var activity: Date { finishedAt ?? createdAt }
}

public struct QuestionThread: Identifiable, Sendable, Equatable {
    public let id: String
    public let runs: [StoredRun]
    public let latestActivity: Date

    public init(id: String, runs: [StoredRun]) {
        self.id = id
        let ordered = runs.sorted { $0.createdAt < $1.createdAt }
        self.runs = ordered
        latestActivity = ordered.map(\.activity).max() ?? .distantPast
    }

    public var title: String { runs.map(\.title).last { !$0.isEmpty } ?? "" }

    public var askedText: String {
        let first = runs.first
        return [first?.record.brief.asked, first?.question?.originalText, first?.record.brief.question]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    public var resolvedText: String { runs.first?.record.brief.question ?? "" }

    public var language: String { runs.first?.record.brief.language ?? "und" }

    private var answerRuns: [StoredRun] { runs.filter { $0.kind != .followup } }

    public var current: StoredRun? { answerRuns.last }

    public var shownAnswer: StoredRun? { answerRuns.last { $0.hasAnswer } }

    public var earlierAnswers: [StoredRun] {
        answerRuns.filter { $0.hasAnswer && $0.id != shownAnswer?.id }.reversed()
    }

    public var followUps: [StoredRun] { runs.filter { $0.kind == .followup } }

    public var runningRun: StoredRun? { runs.last { $0.isRunning } }

    public var isRunning: Bool { runningRun != nil }

    public var latest: StoredRun? { runs.last }

    public var latestFinish: Date? { runs.filter { !$0.isRunning }.compactMap(\.finishedAt).max() }
}

public enum ThreadIndex {
    public static func build(runs: [StoredRun]) -> [QuestionThread] {
        Dictionary(grouping: runs, by: { $0.record.questionID })
            .map { QuestionThread(id: $0.key, runs: $0.value) }
            .sorted { $0.latestActivity > $1.latestActivity }
    }
}

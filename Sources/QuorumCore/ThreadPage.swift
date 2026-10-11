import Foundation

public struct ThreadPage: Equatable, Sendable {
    public struct Earlier: Equatable, Identifiable, Sendable {
        public var id: String { runID }
        public let runID: String
        public let label: String
    }

    public enum FollowUpState: Equatable, Sendable { case running, answered, failed }

    public struct FollowUp: Equatable, Identifiable, Sendable {
        public var id: String { runID }
        public let runID: String
        public let question: String
        public let state: FollowUpState
    }

    public let thread: QuestionThread
    public let capabilities: EngineCapabilities
    private let calendar: Calendar

    public init(thread: QuestionThread, capabilities: EngineCapabilities, calendar: Calendar = .current) {
        self.thread = thread
        self.capabilities = capabilities
        self.calendar = calendar
    }

    public var answer: StoredRun? { thread.shownAnswer }

    public var running: StoredRun? { thread.runningRun }

    public func viewingOverride(_ runID: String?) -> String? {
        guard let runID, thread.runs.contains(where: { $0.id == runID && $0.hasAnswer }) else { return nil }
        return runID
    }

    public func viewed(override runID: String?) -> StoredRun? {
        viewingOverride(runID).flatMap { id in thread.runs.first { $0.id == id } } ?? answer
    }

    public var isWorking: Bool { thread.isRunning }

    public var scopeLine: String? {
        let choices = thread.runs.first?.record.brief.clarifications?.count ?? 0
        return choices == 0 ? nil : "scoped · \(choices) choice\(choices == 1 ? "" : "s")"
    }

    public var earlier: [Earlier] {
        thread.earlierAnswers.map { run in
            Earlier(runID: run.id, label: "earlier answer, \(run.tier?.displayName ?? "Quick"), \(Self.day(run.activity, calendar: calendar))")
        }
    }

    public var followUps: [FollowUp] {
        thread.followUps.map { run in
            FollowUp(runID: run.id, question: run.record.brief.title ?? run.record.brief.question, state: state(of: run))
        }
    }

    public var canGoDeeper: Bool {
        guard capabilities.threads, !isWorking, let answer else { return false }
        return answer.tier == .quick
    }

    public var canFollowUp: Bool { capabilities.threads && answer != nil && !isWorking }

    public func goDeeperStart() -> RunStart? {
        guard canGoDeeper, let answer else { return nil }
        var brief = Self.brief(of: answer, tier: .deep)
        brief.tier = .deep
        return RunStart(question: answer.record.brief.question, brief: brief, tier: .deep, kind: .rerun,
                        parentRunID: answer.id, questionID: thread.id)
    }

    public func followUpStart(_ text: String) -> RunStart? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canFollowUp, !trimmed.isEmpty, let answer else { return nil }
        return RunStart(question: trimmed, brief: nil, tier: .quick, kind: .followup, parentRunID: answer.id, questionID: thread.id)
    }

    public func conflictFollowUp(statement: String) -> String { "Resolve this conflict: \(statement)" }

    private func state(of run: StoredRun) -> FollowUpState {
        switch run.record.status {
        case .running: return .running
        case .complete, .partial, .inconclusive, .unknown: return .answered
        case .halted, .cancelled, .failed, .crashed: return .failed
        }
    }

    private static func brief(of run: StoredRun, tier: Tier) -> Brief {
        let source = run.record.brief
        return Brief(asked: source.asked ?? source.question, question: source.question, title: source.title ?? run.title,
                     language: source.language, tier: tier, suggestedTier: tier, tierReason: source.tierReason ?? "",
                     clarifications: (source.clarifications ?? []).map { Clarification(question: $0.question, answer: $0.answer) })
    }

    private static func day(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }
}

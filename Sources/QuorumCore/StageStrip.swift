import Foundation

public struct StageStrip: Equatable, Sendable {
    public enum State: Equatable, Sendable { case done, current, pending }

    public struct Stage: Equatable, Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let detail: String
        public let state: State
        public let fraction: Double
    }

    public let stages: [Stage]
    public let headline: String
    public let clock: String

    private static let names = ["Scope", "Research", "Draft", "Check", "Answer"]

    public init(progress: RunProgress?, tier: Tier?, choices: Int, startedAt: Date, now: Date, calendar: Calendar) {
        let current = progress?.stageIndex ?? 2
        stages = Self.names.enumerated().map { offset, name in
            let index = offset + 1
            let state: State = index < current ? .done : index == current ? .current : .pending
            let fraction: Double = state == .done ? 1 : state == .pending ? 0 : Self.fraction(progress)
            return Stage(name: name, detail: Self.detail(index, progress: progress, tier: tier, choices: choices,
                                                         state: state, now: now, calendar: calendar),
                         state: state, fraction: fraction)
        }
        headline = progress?.stageWord ?? "Starting"
        clock = Self.clock(progress: progress, startedAt: startedAt, now: now)
    }

    private static func fraction(_ progress: RunProgress?) -> Double {
        guard let progress, progress.tasksTotal > 0 else { return 0 }
        return min(1, Double(progress.tasksDone) / Double(progress.tasksTotal))
    }

    private static func detail(_ index: Int, progress: RunProgress?, tier: Tier?, choices: Int, state: State,
                               now: Date, calendar: Calendar) -> String {
        switch index {
        case 1: return choices == 0 ? "your question" : "\(choices) choice\(choices == 1 ? "" : "s")"
        case 2: return researchDetail(progress, state: state)
        case 3: return "one short answer"
        case 4: return tier == .quick ? "quotes" : "critics + quotes"
        default:
            guard let eta = progress?.etaSeconds else { return "" }
            return "~" + time(now.addingTimeInterval(TimeInterval(eta)), calendar: calendar)
        }
    }

    private static func researchDetail(_ progress: RunProgress?, state: State) -> String {
        guard let progress, progress.tasksTotal > 0, state != .pending else { return "angles in parallel" }
        let sources = progress.sourcesRead > 0 ? " · \(progress.sourcesRead) \(progress.sourcesRead == 1 ? "source" : "sources")" : ""
        let angles = state == .done ? "\(progress.tasksTotal) angles" : "\(progress.tasksDone) of \(progress.tasksTotal) angles"
        return angles + sources
    }

    private static func clock(progress: RunProgress?, startedAt: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(startedAt) / 60)
        guard minutes >= 1 else { return "just started" }
        var parts = ["\(minutes) min in"]
        if let eta = progress?.etaSeconds { parts.append(eta < 60 ? "under a minute left" : "about \((eta + 30) / 60) min left") }
        return parts.joined(separator: " · ")
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

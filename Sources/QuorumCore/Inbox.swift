import Foundation

public enum InboxState: Equatable, Sendable {
    case running
    case answered(RecordStatsTrustLevel)
    case partial
    case stopped
    case failed
}

public struct InboxRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let tier: Tier?
    public let state: InboxState
    public let parts: [String]
    public let when: String
    public let unread: Bool
}

public struct InboxSection: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public let title: String
    public let rows: [InboxRow]
}

public enum Inbox {
    public static func sections(threads: [QuestionThread], progress: [String: RunProgress], ui: UIState,
                                now: Date, calendar: Calendar) -> [InboxSection] {
        let rows = threads.sorted { $0.latestActivity > $1.latestActivity }
            .map { (thread: $0, row: row(for: $0, progress: progress, ui: ui, now: now, calendar: calendar)) }
        var sections: [InboxSection] = []
        let running = rows.filter { $0.thread.isRunning }.map(\.row)
        if !running.isEmpty { sections.append(InboxSection(title: "Running", rows: running)) }
        var titles: [String] = []
        var grouped: [String: [InboxRow]] = [:]
        for (thread, row) in rows where !thread.isRunning {
            let title = groupTitle(for: thread.latestActivity, now: now, calendar: calendar)
            if grouped[title] == nil { titles.append(title) }
            grouped[title, default: []].append(row)
        }
        return sections + titles.map { InboxSection(title: $0, rows: grouped[$0] ?? []) }
    }

    public static func order(_ sections: [InboxSection]) -> [String] { sections.flatMap(\.rows).map(\.id) }

    public static func step(from current: String?, by delta: Int, in order: [String]) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else { return delta >= 0 ? order.first : order.last }
        return order[min(max(index + delta, 0), order.count - 1)]
    }

    public static func nth(_ position: Int, in order: [String]) -> String? {
        order.indices.contains(position - 1) ? order[position - 1] : nil
    }

    private static func row(for thread: QuestionThread, progress: [String: RunProgress], ui: UIState,
                            now: Date, calendar: Calendar) -> InboxRow {
        let running = thread.runningRun
        let subject = thread.shownAnswer ?? thread.latest
        let state = state(of: running ?? subject)
        let parts = running.map { runningParts(progress[$0.id]) } ?? subject.map { finishedParts($0, state: state, thread: thread) } ?? []
        let unread = running == nil && ui.isUnread(question: thread.id, latestFinish: thread.latestFinish)
        return InboxRow(id: thread.id, title: thread.title, tier: (running ?? subject)?.tier, state: state, parts: parts,
                        when: whenLabel(thread.latestActivity, now: now, calendar: calendar), unread: unread)
    }

    private static func state(of run: StoredRun?) -> InboxState {
        guard let run else { return .failed }
        switch run.record.status {
        case .running: return .running
        case .complete, .inconclusive: return .answered(run.record.stats.trustLevel)
        case .failed, .crashed: return .failed
        case .halted, .cancelled: return .stopped
        case .unknown: return .partial
        }
    }

    private static func runningParts(_ progress: RunProgress?) -> [String] {
        guard let progress else { return ["Starting"] }
        guard let eta = progress.etaSeconds else { return [progress.stageWord] }
        return [eta < 60 ? "<1 min left" : "~\((eta + 30) / 60) min left"]
    }

    private static func finishedParts(_ run: StoredRun, state: InboxState, thread: QuestionThread) -> [String] {
        var parts: [String]
        switch state {
        case .failed: return ["Couldn't finish"]
        case .stopped: parts = ["Stopped"]
        case .partial: parts = ["Partial"]
        case .answered(let trust): parts = [trust.rawValue.capitalized]
        case .running: parts = []
        }
        let conflicts = run.record.stats.conflictsOpen
        if conflicts > 0 { parts.append("\(conflicts) open conflict\(conflicts == 1 ? "" : "s")") }
        let followUps = thread.followUps.count
        if followUps > 0 { parts.append("\(followUps) follow-up\(followUps == 1 ? "" : "s")") }
        return parts
    }

    private static func groupTitle(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now), week.contains(date) { return "This week" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return format(date, sameYear ? "LLLL" : "LLLL yyyy", calendar: calendar)
    }

    private static func whenLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return format(date, "HH:mm", calendar: calendar) }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now), week.contains(date) { return format(date, "EEE", calendar: calendar) }
        return format(date, "d MMM", calendar: calendar)
    }

    private static func format(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

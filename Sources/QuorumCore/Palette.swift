import Foundation

public enum PaletteSection: String, Sendable, Equatable {
    case questions = "Questions"
    case insideAnswers = "Inside answers"
    case sources = "Sources"
    case ask = "Ask"
    case commands = "Commands"
}

public enum PaletteCommand: Sendable, Equatable {
    case newQuestion, chooseBrain, revealInFinder, openInClaudeCode, copyMarkdown, goDeeper, showWork, stopAll, settings, toggleSidebar
}

public enum PaletteAction: Sendable, Equatable {
    case openQuestion(String)
    case openSource(question: String, cite: String)
    case askNew(String)
    case followUp(question: String, text: String)
    case command(PaletteCommand)
}

public struct PaletteSnippet: Sendable, Equatable {
    public let text: String
    public let match: Range<Int>
}

public struct PaletteItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let detail: String?
    public let snippet: PaletteSnippet?
    public let action: PaletteAction
    public let tier: Tier?
    public let shortcut: String?
}

public struct PaletteGroup: Identifiable, Sendable, Equatable {
    public var id: String { section.rawValue }
    public let section: PaletteSection
    public let items: [PaletteItem]
}

public struct PaletteContext: Sendable, Equatable {
    public let selected: QuestionThread?
    public let canGoDeeper: Bool
    public let anyRunning: Bool

    public init(selected: QuestionThread?, canGoDeeper: Bool, anyRunning: Bool) {
        self.selected = selected
        self.canGoDeeper = canGoDeeper
        self.anyRunning = anyRunning
    }
}

public enum PaletteFilter: Sendable, Equatable, CaseIterable {
    case all, running, deep, thisWeek

    public var next: PaletteFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    public var label: String {
        switch self {
        case .all: return "All"
        case .running: return "Running"
        case .deep: return "Deep"
        case .thisWeek: return "This week"
        }
    }
}

public struct PalettePreview: Sendable, Equatable {
    public let title: String
    public let tier: Tier?
    public let lead: String
    public let trustLine: String
    public let followUps: [String]
}

public enum Palette {
    private static let questionLimit = 8
    private static let insideLimit = 5
    private static let sourceLimit = 5

    public static func search(query: String, filter: PaletteFilter, threads: [QuestionThread], context: PaletteContext,
                              now: Date, calendar: Calendar) -> [PaletteGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = threads.filter { passes($0, filter: filter, now: now, calendar: calendar) }
        let titled = titleMatches(trimmed, in: visible)
        let titledIDs = Set(titled.map(\.id))
        var groups: [(PaletteSection, [PaletteItem])] = [(.questions, titled.map(questionItem))]
        if !trimmed.isEmpty {
            let rest = visible.filter { !titledIDs.contains($0.id) }
            groups.append((.insideAnswers, Array(rest.compactMap { insideItem($0, query: trimmed) }.prefix(insideLimit))))
            groups.append((.sources, Array(visible.flatMap { sourceItems($0, query: trimmed) }.prefix(sourceLimit))))
            groups.append((.ask, askItems(trimmed, context: context)))
        }
        groups.append((.commands, commandItems(trimmed, context: context)))
        return groups.filter { !$0.1.isEmpty }.map { PaletteGroup(section: $0.0, items: $0.1) }
    }

    public static func preview(for action: PaletteAction, threads: [QuestionThread]) -> PalettePreview? {
        let id: String
        switch action {
        case .openQuestion(let question): id = question
        case .openSource(let question, _): id = question
        default: return nil
        }
        guard let thread = threads.first(where: { $0.id == id }), let run = thread.shownAnswer ?? thread.latest else { return nil }
        let stats = run.record.stats
        let conflicts = stats.conflictsOpen
        let trust = [stats.trustLevel.rawValue.capitalized, "\(stats.claimsSolid) of \(stats.claims) claims solid",
                     "\(conflicts) conflict\(conflicts == 1 ? "" : "s")", "\(stats.sourcesCited) cited"].joined(separator: " · ")
        return PalettePreview(title: thread.title, tier: run.tier, lead: lead(of: run), trustLine: trust,
                              followUps: thread.followUps.map { $0.record.brief.question })
    }

    static func lead(of run: StoredRun) -> String {
        guard let answer = run.record.answer,
              case .answer(let root, _)? = answer.spec.elements[answer.spec.root] else { return run.record.answer?.headline ?? "" }
        return CitationMarkers.stripping(root.lead)
    }

    private static func passes(_ thread: QuestionThread, filter: PaletteFilter, now: Date, calendar: Calendar) -> Bool {
        switch filter {
        case .all: return true
        case .running: return thread.isRunning
        case .deep: return (thread.runningRun ?? thread.shownAnswer ?? thread.latest)?.tier == .deep
        case .thisWeek: return calendar.dateInterval(of: .weekOfYear, for: now)?.contains(thread.latestActivity) ?? false
        }
    }

    private static func titleMatches(_ query: String, in threads: [QuestionThread]) -> [QuestionThread] {
        let scores = threads.map { score(query, $0.title) }
        let ranked = threads.indices.compactMap { index in scores[index].map { (index, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
        return Array(ranked.prefix(questionLimit).map { threads[$0.0] })
    }

    private static func score(_ query: String, _ title: String) -> Int? {
        QuickSwitch.score(fold(query), fold(title))
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func questionItem(_ thread: QuestionThread) -> PaletteItem {
        PaletteItem(id: "question.\(thread.id)", title: thread.title, detail: nil, snippet: nil,
                    action: .openQuestion(thread.id), tier: (thread.shownAnswer ?? thread.latest)?.tier, shortcut: nil)
    }

    private static func insideItem(_ thread: QuestionThread, query: String) -> PaletteItem? {
        guard let run = thread.shownAnswer else { return nil }
        let texts = [run.record.answer?.headline].compactMap { $0 }
            + run.record.claims.map { CitationMarkers.stripping($0.text) }
        for text in texts {
            if let snippet = snippet(in: text, matching: query) {
                return PaletteItem(id: "inside.\(thread.id)", title: thread.title, detail: nil, snippet: snippet,
                                   action: .openQuestion(thread.id), tier: run.tier, shortcut: nil)
            }
        }
        return nil
    }

    private static func sourceItems(_ thread: QuestionThread, query: String) -> [PaletteItem] {
        guard let run = thread.shownAnswer else { return [] }
        let sources = Dictionary(uniqueKeysWithValues: run.record.sources.map { ($0.id, $0) })
        return run.record.citations.compactMap { citation in
            guard let snippet = snippet(in: citation.quote, matching: query) else { return nil }
            let source = sources[citation.sourceID]
            return PaletteItem(id: "source.\(thread.id).\(citation.id)", title: source?.title ?? source?.host ?? citation.sourceID,
                               detail: thread.title, snippet: snippet, action: .openSource(question: thread.id, cite: citation.id),
                               tier: nil, shortcut: nil)
        }
    }

    static func snippet(in text: String, matching query: String) -> PaletteSnippet? {
        guard let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.distance(from: text.startIndex, to: found.lowerBound)
        let length = text.distance(from: found.lowerBound, to: found.upperBound)
        let from = max(0, start - 36)
        let to = min(text.count, start + length + 54)
        let body = String(text.dropFirst(from).prefix(to - from))
        let leading = from > 0 ? "…" : ""
        let trailing = to < text.count ? "…" : ""
        let offset = leading.count + (start - from)
        return PaletteSnippet(text: leading + body + trailing, match: offset..<(offset + length))
    }

    private static func askItems(_ query: String, context: PaletteContext) -> [PaletteItem] {
        var items = [PaletteItem(id: "ask.new", title: "Ask “\(query)” as a new question", detail: nil, snippet: nil,
                                 action: .askNew(query), tier: nil, shortcut: "⌘↩")]
        if let thread = context.selected {
            items.append(PaletteItem(id: "ask.followup", title: "Follow up on \(thread.title)", detail: nil, snippet: nil,
                                     action: .followUp(question: thread.id, text: query), tier: nil, shortcut: "⌥↩"))
        }
        return items
    }

    private static func commandItems(_ query: String, context: PaletteContext) -> [PaletteItem] {
        var available: [(String, PaletteCommand, String?)] = [
            ("New question", .newQuestion, "N"),
            ("Choose brain folder…", .chooseBrain, nil),
            ("Toggle the sidebar", .toggleSidebar, "⌘\\"),
            ("Settings", .settings, "⌘,"),
        ]
        if context.selected != nil {
            available += [("Copy answer as markdown", .copyMarkdown, "⌘⇧C"), ("Reveal in Finder", .revealInFinder, nil),
                          ("Open in Claude Code", .openInClaudeCode, nil), ("Show the work", .showWork, "G")]
            if context.canGoDeeper { available.append(("Run this question again as Deep", .goDeeper, nil)) }
        }
        if context.anyRunning { available.append(("Stop all runs", .stopAll, nil)) }
        return available.filter { score(query, $0.0) != nil }
            .map { PaletteItem(id: "command.\($0.0)", title: $0.0, detail: nil, snippet: nil, action: .command($0.1), tier: nil, shortcut: $0.2) }
    }
}

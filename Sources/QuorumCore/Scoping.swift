import Foundation

public enum Tier: String, Codable, Sendable, CaseIterable {
    case quick, deep

    public var displayName: String { self == .quick ? "Quick" : "Deep" }
    public var other: Tier { self == .quick ? .deep : .quick }
}

public struct Clarification: Codable, Equatable, Sendable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

public struct Brief: Codable, Equatable, Sendable {
    public var asked: String
    public var question: String
    public var title: String
    public var language: String
    public var tier: Tier
    public var suggestedTier: Tier
    public var tierReason: String
    public var clarifications: [Clarification]

    public init(asked: String, question: String, title: String, language: String, tier: Tier, suggestedTier: Tier,
                tierReason: String, clarifications: [Clarification]) {
        self.asked = asked
        self.question = question
        self.title = title
        self.language = language
        self.tier = tier
        self.suggestedTier = suggestedTier
        self.tierReason = tierReason
        self.clarifications = clarifications
    }

    enum CodingKeys: String, CodingKey {
        case asked, question, title, language, tier, clarifications
        case suggestedTier = "suggested_tier"
        case tierReason = "tier_reason"
    }
}

public struct ScopeOption: Equatable, Sendable, Decodable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct ScopeQuestion: Equatable, Sendable, Decodable, Identifiable {
    public let id: String
    public let text: String
    public let multi: Bool
    public let options: [ScopeOption]

    public init(id: String, text: String, multi: Bool, options: [ScopeOption]) {
        self.id = id
        self.text = text
        self.multi = multi
        self.options = options
    }
}

public struct ScopeReply: Equatable, Sendable {
    public let needsScoping: Bool
    public let brief: Brief
    public let questions: [ScopeQuestion]
    public let fallbackReason: String?

    public init(needsScoping: Bool, brief: Brief, questions: [ScopeQuestion], fallbackReason: String?) {
        self.needsScoping = needsScoping
        self.brief = brief
        self.questions = questions
        self.fallbackReason = fallbackReason
    }
}

public struct ScopeRequest: Codable, Equatable, Sendable {
    public let question: String
    public let clarifications: [Clarification]
    public let ticket: UUID

    public init(question: String, clarifications: [Clarification], ticket: UUID = UUID()) {
        self.question = question
        self.clarifications = clarifications
        self.ticket = ticket
    }

    enum CodingKeys: String, CodingKey { case question, clarifications }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        question = try values.decode(String.self, forKey: .question)
        clarifications = try values.decode([Clarification].self, forKey: .clarifications)
        ticket = UUID()
    }

    public static func == (lhs: ScopeRequest, rhs: ScopeRequest) -> Bool {
        lhs.question == rhs.question && lhs.clarifications == rhs.clarifications
    }
}

public struct RunStart: Equatable, Sendable {
    public let question: String
    public let brief: Brief?
    public let tier: Tier
    public let clarifications: [Clarification]

    public init(question: String, brief: Brief?, tier: Tier, clarifications: [Clarification] = []) {
        self.question = question
        self.brief = brief
        self.tier = tier
        self.clarifications = clarifications
    }
}

public enum ScopeKeys {
    public struct Target: Equatable, Sendable {
        public let question: Int
        public let option: Int
    }

    private static let rows = ["1234", "qwer", "asdf"]

    public static func target(for key: Character, questions: Int) -> Target? {
        let lowered = Character(key.lowercased())
        for (question, row) in rows.enumerated() where question < questions {
            if let option = row.firstIndex(of: lowered) { return Target(question: question, option: row.distance(from: row.startIndex, to: option)) }
        }
        return nil
    }

    public static func label(question: Int, option: Int) -> String {
        let row = rows[min(question, rows.count - 1)]
        return String(row[row.index(row.startIndex, offsetBy: option)]).uppercased()
    }
}

public struct ScopingFlow: Equatable, Sendable {
    public enum Step: Equatable, Sendable { case drafting, scoping, clarifying, confirming }

    public static let ownWordsLabel = "In your own words"

    public private(set) var step: Step = .drafting
    public var draft = ""
    public var ownWords = ""
    public private(set) var asked = ""
    public private(set) var brief: Brief?
    public private(set) var questions: [ScopeQuestion] = []
    public private(set) var tier: Tier = .quick
    public private(set) var fallbackReason: String?
    public private(set) var pendingTicket: UUID?
    public private(set) var editingResolved = false
    public var resolvedDraft = ""
    private var picks: [String: [String]] = [:]
    private var tierChosen = false
    private var clarified = false
    private var answers: [Clarification] = []
    private var editedFallback: String?

    public init() {}

    public var resolvedQuestion: String { brief?.question ?? editedFallback ?? asked }
    public var tierReason: String { brief?.tierReason ?? "" }

    public mutating func submit() -> ScopeRequest? {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard step == .drafting, !question.isEmpty else { return nil }
        asked = question
        brief = nil
        questions = []
        picks = [:]
        ownWords = ""
        clarified = false
        answers = []
        editedFallback = nil
        editingResolved = false
        fallbackReason = nil
        step = .scoping
        return issue(ScopeRequest(question: question, clarifications: []))
    }

    private mutating func issue(_ request: ScopeRequest) -> ScopeRequest {
        pendingTicket = request.ticket
        return request
    }

    private mutating func accept(_ ticket: UUID?) -> Bool {
        guard step == .scoping, let ticket, ticket == pendingTicket else { return false }
        pendingTicket = nil
        return true
    }

    public mutating func receive(_ reply: ScopeReply, for ticket: UUID?) {
        guard accept(ticket) else { return }
        brief = reply.brief
        fallbackReason = reply.fallbackReason
        if !tierChosen { tier = reply.brief.suggestedTier }
        if reply.needsScoping, !clarified, !reply.questions.isEmpty {
            questions = reply.questions
            step = .clarifying
        } else {
            questions = []
            step = .confirming
        }
    }

    public mutating func fail(_ failure: EngineFailure, for ticket: UUID?) {
        guard accept(ticket) else { return }
        brief = nil
        fallbackReason = failure.reason
        step = .confirming
    }

    public mutating func pick(question: Int, option: Int) {
        guard step == .clarifying, questions.indices.contains(question), questions[question].options.indices.contains(option) else { return }
        let asking = questions[question]
        let chosen = asking.options[option].id
        var current = picks[asking.id] ?? []
        if asking.multi {
            if let at = current.firstIndex(of: chosen) { current.remove(at: at) } else { current.append(chosen) }
        } else {
            current = current == [chosen] ? [] : [chosen]
        }
        picks[asking.id] = current
    }

    public func picked(question: Int) -> [String] {
        questions.indices.contains(question) ? (picks[questions[question].id] ?? []) : []
    }

    public mutating func continueClarifying() -> ScopeRequest? {
        guard step == .clarifying else { return nil }
        var given: [Clarification] = []
        for asking in questions {
            let labels = (picks[asking.id] ?? []).compactMap { id in asking.options.first { $0.id == id }?.label }
            if !labels.isEmpty { given.append(Clarification(question: asking.text, answer: labels.joined(separator: ", "))) }
        }
        let own = ownWords.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { given.append(Clarification(question: Self.ownWordsLabel, answer: own)) }
        guard !given.isEmpty else {
            step = .confirming
            return nil
        }
        clarified = true
        answers = given
        step = .scoping
        return issue(ScopeRequest(question: asked, clarifications: given))
    }

    public mutating func toggleTier() {
        tier = tier.other
        tierChosen = true
    }

    public mutating func editResolved(_ text: String) {
        if brief != nil { brief?.question = text } else { editedFallback = text }
    }

    public mutating func beginEditingResolved() {
        guard step == .confirming else { return }
        resolvedDraft = resolvedQuestion
        editingResolved = true
    }

    public mutating func commitResolvedEdit() {
        let text = resolvedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if editingResolved, !text.isEmpty { editResolved(text) }
        editingResolved = false
    }

    public mutating func cancelResolvedEdit() {
        editingResolved = false
    }

    public mutating func edit() {
        draft = asked
        step = .drafting
        brief = nil
        questions = []
        fallbackReason = nil
        pendingTicket = nil
        editingResolved = false
        editedFallback = nil
    }

    public mutating func confirm() -> RunStart? {
        guard step == .confirming else { return nil }
        commitResolvedEdit()
        guard var chosen = brief else {
            return RunStart(question: resolvedQuestion, brief: nil, tier: tier, clarifications: answers)
        }
        chosen.tier = tier
        return RunStart(question: chosen.question, brief: chosen, tier: tier)
    }

    public func runAsWritten() -> RunStart? {
        guard step == .clarifying || step == .confirming else { return nil }
        return RunStart(question: asked, brief: nil, tier: tier)
    }

    public mutating func reset() { self = ScopingFlow() }
}

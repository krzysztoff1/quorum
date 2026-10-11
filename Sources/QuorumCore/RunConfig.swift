import Foundation

public struct EngineRunConfig: Encodable, Sendable {
    let question: String
    let tier: String
    let brainDir: String
    let brief: Brief?
    let clarifications: [Clarification]?
    let kind: String
    let parentRunID: String?
    let questionID: String?

    enum CodingKeys: String, CodingKey {
        case question, tier, brainDir, brief, clarifications, kind
        case parentRunID = "parent_run_id"
        case questionID = "question_id"
    }

    public init(start: RunStart, brainDir: URL) {
        question = start.question
        tier = start.tier.rawValue
        self.brainDir = brainDir.path
        brief = start.brief
        clarifications = start.clarifications.isEmpty ? nil : start.clarifications
        kind = start.kind.rawValue
        parentRunID = start.parentRunID
        questionID = start.questionID
    }
}

public struct EngineCapabilities: Equatable, Sendable {
    public let threads: Bool

    public init(checks: [EngineDoctorCheck]) {
        threads = checks.contains { $0.id == "threads" && $0.ok }
    }

    public static let none = EngineCapabilities(checks: [])
}

import Foundation

public struct TierPlan: Equatable, Sendable {
    public let angleCount: Int
    public let rounds: Int
    public let effort: String
    public let maxTurns: Int
    public let perTopicBudgetUSD: Double
    public let runBudgetUSD: Double
    public let perTopicTimeoutSec: Int
    public let agentModel: String
    public let synthesisModel: String
    public let validatorModel: String

    public static func plan(for tier: Tier) -> TierPlan {
        TierPlan(angleCount: tier == .quick ? 3 : 5, rounds: tier == .quick ? 1 : 3, effort: "medium", maxTurns: 60,
                 perTopicBudgetUSD: 10, runBudgetUSD: 40, perTopicTimeoutSec: tier == .quick ? 600 : 1200,
                 agentModel: "claude-code/claude-sonnet-5", synthesisModel: "claude-code/claude-opus-4-8",
                 validatorModel: RunProfile.subscriptionValidatorModel)
    }

    public var deadlineSeconds: Int { perTopicTimeoutSec * max(1, rounds) }
}

public struct EngineRunConfig: Encodable, Sendable {
    let question: String
    let angleCount: Int
    let angleModel: String
    let synthesisModel: String
    let validatorModel: String
    let effort: String
    let perTopicBudgetUSD: Double
    let runBudgetUSD: Double
    let perTopicTimeoutSec: Int
    let maxTurns: Int
    let rounds: Int
    let brainDir: String
    let runDeadlineSec: Int
    let brief: Brief?
    let tier: String
    let clarifications: [Clarification]?
    let kind: String
    let parentRunID: String?
    let questionID: String?

    enum CodingKeys: String, CodingKey {
        case question, angleCount, angleModel, synthesisModel, validatorModel, effort, perTopicBudgetUSD, runBudgetUSD
        case perTopicTimeoutSec, maxTurns, rounds, brainDir, runDeadlineSec, brief, tier, clarifications, kind
        case parentRunID = "parent_run_id"
        case questionID = "question_id"
    }

    public init(start: RunStart, brainDir: URL, deadlineSeconds: Int) {
        let plan = TierPlan.plan(for: start.tier)
        question = start.question
        angleCount = plan.angleCount
        angleModel = plan.agentModel
        synthesisModel = plan.synthesisModel
        validatorModel = plan.validatorModel
        effort = plan.effort
        perTopicBudgetUSD = plan.perTopicBudgetUSD
        runBudgetUSD = plan.runBudgetUSD
        perTopicTimeoutSec = plan.perTopicTimeoutSec
        maxTurns = plan.maxTurns
        rounds = plan.rounds
        self.brainDir = brainDir.path
        runDeadlineSec = deadlineSeconds
        brief = start.brief
        tier = start.tier.rawValue
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

import Foundation
import QuorumCore

/// Routes each topic role to the CLI or the BYOK engine per the run profile (PRD 02 R2). A thin
/// `ResearchExecutor & AnglePlanner` over the two concrete executors — the routing decision itself is
/// the pure, tested `RunProfile`. One run can thus mix engines per role (Budget = cheap engine angles +
/// $0-marginal subscription synthesis) while the app above this seam stays unchanged.
struct RoutingExecutor: ResearchExecutor, AnglePlanner {
    let profile: RunProfile
    let cli: ClaudeCodeExecutor
    let engine: EngineExecutor

    func run(_ topic: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        switch profile.executor(for: topic.role, useProjectContext: topic.useProjectContext) {
        case .cli:    return try await cli.run(topic, ctx)
        case .engine: return try await engine.run(topic, ctx)
        }
    }

    func plan(question: String, count: Int, priorNotes: [URL], projectURL: URL,
              _ ctx: RunContext) async throws -> [ResearchAngle] {
        switch profile.plannerKind {
        case .cli:    return try await cli.plan(question: question, count: count, priorNotes: priorNotes,
                                                projectURL: projectURL, ctx)
        case .engine: return try await engine.plan(question: question, count: count, priorNotes: priorNotes,
                                                   projectURL: projectURL, ctx)
        }
    }
}

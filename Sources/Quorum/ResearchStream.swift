import Foundation
import QuorumCore

/// The stream→findings reduction shared by every research executor (PRD 02 R1): feed a launched
/// subprocess's parsed lines, accumulate output/thinking/sources/usage, emit live snapshots +
/// halt-partials, and fold the final result into a `TopicFindings`. Only the argv, env, and binary
/// differ between the Claude Code CLI and the BYOK engine — so this lives once and both call it.
enum ResearchStream {

    static func run(executable: URL, arguments: [String], environment: [String: String]?,
                    topic: PreparedTopic, _ ctx: RunContext,
                    onActivity: (@Sendable (LiveSnapshot) -> Void)?,
                    fallbackProvider: String? = nil, fallbackModel: String? = nil) async throws -> TopicFindings {
        let started = ctx.clock.now()
        var assistantText = "", thinkingText = ""
        var sources: [LiveSource] = []
        var finalResult: String?
        var sessionID: String?
        var rateLimit: String?
        var usageSteps: [ResearchOutputParser.StepUsage] = []
        var mcpSearchCalls = 0, mcpFetchCalls = 0   // own-search MCP calls, priced from tool-use events (R7)
        var sawDeltas = false   // prefer token-by-token deltas; ignore the duplicate full-message text
        var writingStartedAt: Date?

        let subprocess = StreamingSubprocess(executableURL: executable, arguments: arguments,
                                             currentDirectory: topic.projectURL, environment: environment)
        let outcome = try await subprocess.run(ctx) { ev, cost in
            if let sid = ev.sessionID { sessionID = sid }
            if let type = ev.rateLimitType {
                rateLimit = formatRateLimit(type: type, status: ev.rateLimitStatus, resetsAt: ev.rateLimitResetsAt)
            }
            if let u = ev.usage { usageSteps.append(u) }

            var changed = false
            if let d = ev.deltaText { assistantText += d; sawDeltas = true; changed = true }
            if let dt = ev.deltaThinking { thinkingText += dt; sawDeltas = true; changed = true }
            if !sawDeltas {   // fallback when partial messages aren't streaming
                if let th = ev.thinking { thinkingText += th; changed = true }
                if let tx = ev.assistantText { assistantText += tx; changed = true }
            }
            for tu in ev.toolUses {
                if tu.name == "mcp__quorum__web_search" { mcpSearchCalls += 1 }
                else if tu.name == "mcp__quorum__web_fetch" { mcpFetchCalls += 1 }
                if !tu.detail.isEmpty {
                    sources.append(LiveSource(kind: tu.name, value: tu.detail, at: ctx.clock.now()))
                    changed = true
                }
            }
            if ev.type == "result", let r = ev.result { finalResult = r }
            if writingStartedAt == nil, !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                writingStartedAt = ctx.clock.now()
            }

            if changed {
                onActivity?(LiveSnapshot(topicID: topic.id, question: topic.question,
                                         thinking: thinkingText, output: assistantText,
                                         sources: sources, costUSD: cost,
                                         writingStartedAt: writingStartedAt))
                let headline = assistantText.split(separator: "\n").first.map { String($0.prefix(120)) } ?? "Research in progress"
                ctx.onPartial(PartialFindings(headline: headline, findings: [],
                                              sourcesConsulted: sources.count, writeupMarkdown: assistantText))
            }
        }

        let duration = Duration.seconds(max(0, ctx.clock.now().timeIntervalSince(started)))
        let out = ResearchOutputParser.parseFinal(finalResult ?? assistantText)
        var usage = TopicUsage.from(steps: usageSteps)
        if usage == nil, let provider = fallbackProvider {
            // Engine run that failed before its first usage event still records its provider, so the
            // topic reads as engine-run (chat seeds a fresh session instead of an impossible --resume).
            usage = TopicUsage(provider: provider, model: fallbackModel ?? "", inputTokens: 0, outputTokens: 0,
                               cacheReadTokens: 0, cacheWriteTokens: 0, searchCalls: 0, fetchCalls: 0,
                               costUSD: outcome.finalCostUSD)
        }
        if let u = usage, mcpSearchCalls > 0 || mcpFetchCalls > 0 {
            usage = u.addingCalls(search: mcpSearchCalls, fetch: mcpFetchCalls)
        }
        return TopicFindings(
            id: topic.id, status: out.status, preset: topic.preset,
            headline: out.headline, findings: out.findings, conflicts: out.conflicts, gaps: out.gaps,
            sourcesConsulted: out.sourcesConsulted, costUSD: outcome.finalCostUSD, duration: duration,
            writeupMarkdown: out.writeup, transcript: outcome.transcript, note: out.note,
            sessionID: sessionID, rateLimit: rateLimit, usage: usage, evidence: out.evidence)
    }

    static func plan(executable: URL, arguments: [String], environment: [String: String]?,
                     projectURL: URL, _ ctx: RunContext,
                     onActivity: (@Sendable (LiveSnapshot) -> Void)?) async throws -> [ResearchAngle] {
        var assistantText = "", thinkingText = ""
        var finalResult: String?
        var sawDeltas = false

        let subprocess = StreamingSubprocess(executableURL: executable, arguments: arguments,
                                             currentDirectory: projectURL, environment: environment)
        _ = try await subprocess.run(ctx) { ev, cost in
            var changed = false
            if let d = ev.deltaText { assistantText += d; sawDeltas = true; changed = true }
            if let dt = ev.deltaThinking { thinkingText += dt; sawDeltas = true; changed = true }
            if !sawDeltas {
                if let th = ev.thinking { thinkingText += th; changed = true }
                if let tx = ev.assistantText { assistantText += tx; changed = true }
            }
            if ev.type == "result", let r = ev.result { finalResult = r }
            if changed {
                onActivity?(LiveSnapshot(topicID: "planning", question: "Planning research angles",
                                         thinking: thinkingText, output: assistantText, sources: [], costUSD: cost))
            }
        }
        return ResearchOutputParser.parseAngles(finalResult ?? assistantText)
    }

    static func formatRateLimit(type: String, status: String?, resetsAt: Double?) -> String {
        let window: String
        switch type {
        case "five_hour": window = "5-hour limit"
        case "seven_day", "weekly": window = "weekly limit"
        default: window = type.replacingOccurrences(of: "_", with: " ")
        }
        var s = "\(window): \((status ?? "allowed").replacingOccurrences(of: "_", with: " "))"
        if let r = resetsAt {
            let f = DateFormatter(); f.dateFormat = "EEE h:mm a"; f.locale = Locale(identifier: "en_US_POSIX")
            s += " · resets \(f.string(from: Date(timeIntervalSince1970: r)))"
        }
        return s
    }
}

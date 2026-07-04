import Foundation

/// How the app gets structured findings out of a CLI run (a PRD decision worth locking with tests):
/// the research run emits a cited markdown writeup followed by a final fenced ```json summary, and
/// streams newline-delimited JSON — cost, thinking, output, tool-use (sources), token-by-token
/// deltas (with `--include-partial-messages`), the session id, and rate-limit status. This is the
/// pure parsing of all of it; the executor is just the subprocess plumbing around it. Deliberately
/// forgiving — a malformed or missing block degrades to prose, never a crash or a fabricated finding.
public struct ResearchOutput {
    public let headline: String
    public let status: TopicStatus
    public let sourcesConsulted: Int
    public let findings: [Finding]
    public let conflicts: [Conflict]
    public let gaps: [String]
    public let note: String?
    public let writeup: String

    public init(headline: String, status: TopicStatus, sourcesConsulted: Int, findings: [Finding],
                conflicts: [Conflict] = [], gaps: [String] = [], note: String?, writeup: String) {
        self.headline = headline
        self.status = status
        self.sourcesConsulted = sourcesConsulted
        self.findings = findings
        self.conflicts = conflicts
        self.gaps = gaps
        self.note = note
        self.writeup = writeup
    }
}

public enum ResearchOutputParser {

    public struct ToolUse: Equatable {
        public let name: String     // "WebSearch", "WebFetch", "Read", …
        public let detail: String   // the query / url / path — for display
    }

    /// One streamed JSON line → the fields the executor/UI care about (nil if the line isn't JSON).
    public struct StreamLine: Equatable {
        public let type: String?
        public let totalCostUSD: Decimal?     // cumulative
        public let assistantText: String?     // full-message output text (a complete assistant event)
        public let thinking: String?          // full-message thinking
        public let deltaText: String?         // incremental output text (partial-message stream)
        public let deltaThinking: String?     // incremental thinking
        public let toolUses: [ToolUse]         // tool calls (sources being consulted)
        public let result: String?
        public let sessionID: String?          // the CLI session — lets us resume this topic later
        public let rateLimitStatus: String?    // "allowed" / "allowed_warning" / "rejected"
        public let rateLimitType: String?      // "five_hour" / "seven_day" (the binding window)
        public let rateLimitResetsAt: Double?  // unix seconds
    }

    public static func parseStreamLine(_ line: String) -> StreamLine? {
        guard let data = line.data(using: .utf8),
              let ev = try? JSONDecoder().decode(RawEvent.self, from: data) else { return nil }
        let content = ev.message?.content ?? []
        let text = content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        let thinking = content.compactMap { $0.type == "thinking" ? $0.thinking : nil }.joined()
        let tools: [ToolUse] = content.compactMap { c in
            guard c.type == "tool_use", let name = c.name else { return nil }
            return ToolUse(name: name, detail: c.input?.display ?? "")
        }
        let delta = ev.delta ?? ev.event?.delta       // token-by-token, from --include-partial-messages
        let rl = ev.rate_limit_info
        return StreamLine(
            type: ev.type,
            totalCostUSD: ev.total_cost_usd.map { Decimal($0) },
            assistantText: text.isEmpty ? nil : text,
            thinking: thinking.isEmpty ? nil : thinking,
            deltaText: delta?.type == "text_delta" ? delta?.text : nil,
            deltaThinking: delta?.type == "thinking_delta" ? delta?.thinking : nil,
            toolUses: tools,
            result: ev.result,
            sessionID: ev.session_id,
            rateLimitStatus: rl?.status,
            rateLimitType: rl?.rateLimitType,
            rateLimitResetsAt: rl?.resetsAt)
    }

    /// Final assistant text → structured findings + the writeup body (text before the json block).
    public static func parseFinal(_ text: String) -> ResearchOutput {
        guard let (json, before) = lastJSONBlock(in: text),
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawSummary.self, from: data) else {
            let headline = text.split(separator: "\n").first.map { String($0.prefix(120)) } ?? "Research complete"
            return ResearchOutput(headline: headline, status: text.isEmpty ? .inconclusive : .complete,
                                  sourcesConsulted: 0, findings: [], note: nil, writeup: text)
        }
        let findings = (raw.findings ?? []).map {
            Finding(claim: $0.claim, sources: $0.sources ?? [],
                    confidence: Confidence(rawValue: $0.confidence ?? "unverified") ?? .unverified)
        }
        let conflicts = (raw.conflicts ?? []).compactMap { c -> Conflict? in
            let positions = (c.positions ?? []).filter { !$0.isEmpty }
            guard !c.claim.isEmpty, !positions.isEmpty else { return nil }
            return Conflict(claim: c.claim, positions: positions)
        }
        let gaps = (raw.gaps ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let body = before.trimmingCharacters(in: .whitespacesAndNewlines)
        return ResearchOutput(
            headline: raw.headline ?? "Research complete",
            status: raw.status == "inconclusive" ? .inconclusive : .complete,
            sourcesConsulted: raw.sourcesConsulted ?? findings.reduce(0) { $0 + $1.sources.count },
            findings: findings,
            conflicts: conflicts,
            gaps: gaps,
            note: raw.note,
            writeup: body.isEmpty ? text : body)
    }

    /// Planner final text → proposed angles, from the last ```json block: an array of {title, prompt}
    /// (or an object {"angles":[…]}). Forgiving about field names; returns [] on anything unparseable —
    /// the caller treats "no angles" as "planning didn't produce a usable plan, retry", never a crash.
    public static func parseAngles(_ text: String) -> [ResearchAngle] {
        guard let (json, _) = lastJSONBlock(in: text), let data = json.data(using: .utf8) else { return [] }
        let raws: [RawAngle]
        if let arr = try? JSONDecoder().decode([RawAngle].self, from: data) {
            raws = arr
        } else if let wrap = try? JSONDecoder().decode(RawAngleWrap.self, from: data), let arr = wrap.angles {
            raws = arr
        } else {
            return []
        }
        return raws.compactMap { r in
            let prompt = (r.prompt ?? r.question ?? r.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return nil }
            let title = (r.title ?? r.name ?? r.angle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ResearchAngle(title: title.isEmpty ? String(prompt.prefix(60)) : title, prompt: prompt)
        }
    }

    /// Clean a cheap model's reply down to one short History title: first line, drop a "Title:" label,
    /// strip surrounding quotes/markdown/trailing period, cap the length. Empty if there's nothing usable.
    public static func titleFrom(_ text: String) -> String {
        var line = String(text.split(whereSeparator: \.isNewline).first ?? "")
        if let r = line.range(of: "^\\s*title\\s*:\\s*", options: [.regularExpression, .caseInsensitive]) {
            line.removeSubrange(r)
        }
        let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: " \"'`*.#"))
        return String(stripped.prefix(60))
    }

    public static func lastJSONBlock(in text: String) -> (json: String, before: String)? {
        guard let open = text.range(of: "```json", options: .backwards) else { return nil }
        let afterOpen = text[open.upperBound...]
        guard let close = afterOpen.range(of: "```") else { return nil }
        return (String(afterOpen[..<close.lowerBound]), String(text[..<open.lowerBound]))
    }

    // Defensive decodables — unknown fields ignored.
    private struct RawEvent: Decodable {
        let type: String?
        let result: String?
        let total_cost_usd: Double?
        let session_id: String?
        let message: Message?
        let delta: Delta?
        let event: Inner?
        let rate_limit_info: RateLimit?
        struct Message: Decodable { let content: [Content]? }
        struct Content: Decodable {
            let type: String?
            let text: String?
            let thinking: String?
            let name: String?
            let input: ToolInput?
        }
        struct ToolInput: Decodable {
            let query: String?; let url: String?; let prompt: String?; let file_path: String?; let pattern: String?
            var display: String { query ?? url ?? prompt ?? file_path ?? pattern ?? "" }
        }
        struct Delta: Decodable { let type: String?; let text: String?; let thinking: String? }
        struct Inner: Decodable { let delta: Delta? }
        struct RateLimit: Decodable { let status: String?; let rateLimitType: String?; let resetsAt: Double? }
    }
    private struct RawSummary: Decodable {
        let headline: String?
        let status: String?
        let sourcesConsulted: Int?
        let note: String?
        let findings: [RawFinding]?
        let conflicts: [RawConflict]?
        let gaps: [String]?
        struct RawFinding: Decodable { let claim: String; let sources: [String]?; let confidence: String? }
        struct RawConflict: Decodable { let claim: String; let positions: [String]? }
    }
    private struct RawAngleWrap: Decodable { let angles: [RawAngle]? }
    private struct RawAngle: Decodable {
        let title: String?; let name: String?; let angle: String?
        let prompt: String?; let question: String?; let description: String?
    }
}

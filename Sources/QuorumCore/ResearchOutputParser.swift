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
    /// The quotes the writeup's `[^c1]` markers point at (PRD 03). Empty on a legacy writeup; the run
    /// stream's resolved offsets are merged over this, since only the run can verify a quote.
    public let evidence: EvidenceIndex

    public init(headline: String, status: TopicStatus, sourcesConsulted: Int, findings: [Finding],
                conflicts: [Conflict] = [], gaps: [String] = [], note: String?, writeup: String,
                evidence: EvidenceIndex = EvidenceIndex()) {
        self.headline = headline
        self.status = status
        self.sourcesConsulted = sourcesConsulted
        self.findings = findings
        self.conflicts = conflicts
        self.gaps = gaps
        self.note = note
        self.writeup = writeup
        self.evidence = evidence
    }
}

public enum ResearchOutputParser {

    public struct ToolUse: Equatable, Sendable {
        public let name: String     // "WebSearch", "WebFetch", "Read", …
        public let detail: String   // the query / url / path — for display
    }

    /// One model call's token/cost/tooling usage, normalized from either the engine's per-step `usage`
    /// event or the CLI `result` event's `modelUsage` block. Transient (parser output); the executor
    /// sums these into a stored `TopicUsage`.
    public struct StepUsage: Equatable, Sendable {
        public let provider: String?
        public let model: String?
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheWriteTokens: Int
        public let searchCalls: Int
        public let fetchCalls: Int
        public let costUSD: Decimal?

        public init(provider: String?, model: String?, inputTokens: Int, outputTokens: Int,
                    cacheReadTokens: Int, cacheWriteTokens: Int, searchCalls: Int, fetchCalls: Int,
                    costUSD: Decimal?) {
            self.provider = provider
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.searchCalls = searchCalls
            self.fetchCalls = fetchCalls
            self.costUSD = costUSD
        }
    }

    /// One streamed JSON line → the fields the executor/UI care about (nil if the line isn't JSON).
    public struct StreamLine: Equatable, Sendable {
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
        public let usage: StepUsage?           // engine per-step usage, or the CLI result's modelUsage totals
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
            rateLimitResetsAt: rl?.resetsAt,
            usage: normalizedUsage(ev))
    }

    /// Engine per-step usage comes on a `type:"usage"` event; CLI usage comes only on the `result`
    /// event's `modelUsage` (the per-message `usage` blocks the CLI also emits are deliberately ignored
    /// so the run isn't counted many times over). Everything else → no usage line.
    private static func normalizedUsage(_ ev: RawEvent) -> StepUsage? {
        if ev.type == "usage", let u = ev.usage {
            return StepUsage(
                provider: u.provider, model: u.model,
                inputTokens: u.input_tokens ?? 0, outputTokens: u.output_tokens ?? 0,
                cacheReadTokens: u.cache_read_tokens ?? u.cache_read_input_tokens ?? 0,
                cacheWriteTokens: u.cache_write_tokens ?? u.cache_creation_input_tokens ?? 0,
                searchCalls: u.search_calls ?? u.server_tool_use?.web_search_requests ?? 0,
                fetchCalls: u.fetch_calls ?? u.server_tool_use?.web_fetch_requests ?? 0,
                costUSD: u.cost_usd.map { Decimal($0) })
        }
        guard let mu = ev.modelUsage, !mu.isEmpty else { return nil }
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, search = 0, fetch = 0
        var cost = 0.0, topModel = "", topCost = -1.0
        for (name, m) in mu {
            input += m.inputTokens ?? 0; output += m.outputTokens ?? 0
            cacheRead += m.cacheReadInputTokens ?? 0; cacheWrite += m.cacheCreationInputTokens ?? 0
            search += m.webSearchRequests ?? 0; fetch += m.webFetchRequests ?? 0
            let c = m.costUSD ?? 0; cost += c
            if c > topCost { topCost = c; topModel = name }   // multi-model run → name the priciest
        }
        return StepUsage(
            provider: "anthropic", model: topModel,
            inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite, searchCalls: search, fetchCalls: fetch, costUSD: Decimal(cost))
    }

    /// Final assistant text → structured findings + the writeup body (text before the json block).
    public static func parseFinal(_ text: String) -> ResearchOutput {
        guard let (json, before) = lastJSONBlock(in: text),
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawSummary.self, from: data) else {
            let headline = text.split(separator: "\n").first.map { String($0.prefix(120)) } ?? "Research complete"
            return ResearchOutput(headline: headline, status: text.isEmpty ? .inconclusive : .complete,
                                  sourcesConsulted: 0, findings: [], note: nil, writeup: reportBody(text))
        }
        let findings = (raw.findings ?? []).map {
            Finding(claim: $0.claim, sources: $0.sources ?? [],
                    confidence: Confidence(rawValue: $0.confidence ?? "unverified") ?? .unverified,
                    citationIDs: ($0.citations ?? []).filter { !$0.isEmpty })
        }
        let conflicts = (raw.conflicts ?? []).compactMap { c -> Conflict? in
            let positions = (c.positions ?? []).filter { !$0.isEmpty }
            guard !c.claim.isEmpty, !positions.isEmpty else { return nil }
            return Conflict(claim: c.claim, positions: positions)
        }
        let gaps = (raw.gaps ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let body = reportBody(before)
        return ResearchOutput(
            headline: raw.headline ?? "Research complete",
            status: raw.status == "inconclusive" ? .inconclusive : .complete,
            sourcesConsulted: raw.sourcesConsulted ?? findings.reduce(0) { $0 + $1.sources.count },
            findings: findings,
            conflicts: conflicts,
            gaps: gaps,
            note: raw.note,
            writeup: body.isEmpty ? text : body,
            evidence: EvidenceIndex(citations: citations(raw.citations)))
    }

    /// The report as the reader should get it. A model that has just finished searching tends to say so
    /// first ("I have enough depth now. Let me write the final report.") and to title what it is about to
    /// write — but the note and the angle artifact already carry a title, so that H1 lands as a second one
    /// under it. Both are the model talking about writing the report rather than the report; the prose that
    /// answers the question in its first line is the contract, and stays.
    static func reportBody(_ text: String) -> String {
        demotingTitles(droppingNarration(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Leading paragraphs that narrate the process, stripped one at a time until the report starts. Never
    /// strips the lot: a body that is nothing but narration is all the run has to show.
    private static func droppingNarration(_ text: String) -> String {
        var rest = Substring(text)
        while let paragraph = leadingParagraph(of: rest), isNarration(paragraph.text) {
            let remainder = rest[paragraph.end...].drop { $0 == "\n" }
            if remainder.isEmpty { break }
            rest = remainder
        }
        return String(rest)
    }

    private static func leadingParagraph(of text: Substring) -> (text: String, end: Substring.Index)? {
        guard !text.isEmpty, !text.hasPrefix("#"), !text.hasPrefix("```") else { return nil }
        let end = text.range(of: "\n\n")?.lowerBound ?? text.endIndex
        return (String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines), end)
    }

    private static let narrationOpeners = [
        #"^(ok(ay)?|alright|perfect|great|got it)\b"#,
        #"^i(’|')?(ve| have| ll| will| am| now| can)\b"#,
        #"^(now )?let(’|')?(s| me| us)\b"#,
        #"^based on (my|the|these) \w+"#,
        #"^here(’|')?s (the|my|a) (final |full )?(report|answer|writeup|summary)\b"#,
    ]

    private static func isNarration(_ paragraph: String) -> Bool {
        guard paragraph.count <= 240, !CitationMarkers.hasMarkers(in: paragraph) else { return false }
        let lowered = paragraph.lowercased()
        return narrationOpeners.contains {
            lowered.range(of: $0, options: [.regularExpression]) != nil
        }
    }

    /// Every `# heading` down one level, so the container's title is the document's only H1. Fenced code is
    /// left alone — a `# comment` there is part of the sample.
    private static func demotingTitles(_ text: String) -> String {
        var inFence = false
        return text.components(separatedBy: "\n").map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); return line }
            guard !inFence, line.hasPrefix("# ") else { return line }
            return "#" + line
        }.joined(separator: "\n")
    }

    /// The writeup's own citation list → `[Citation]`. An entry with no id can't be referenced by a marker,
    /// so it's dropped rather than kept as an unreachable quote; a repeated id keeps its first spelling.
    private static func citations(_ raws: [RawSummary.RawCitation]?) -> [Citation] {
        var seen = Set<String>()
        return (raws ?? []).compactMap { r in
            let id = (r.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return Citation(id: id, sourceID: r.source_id ?? r.source ?? "", quote: r.quote ?? "",
                            start: r.start, end: r.end,
                            match: QuoteMatch(rawValue: (r.match ?? "").lowercased()) ?? .unresolved,
                            page: r.page)
        }
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
            let preset: EffortPreset? = r.depth?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "shallow" ? .draft : nil
            return ResearchAngle(title: title.isEmpty ? String(prompt.prefix(60)) : title, prompt: prompt, preset: preset)
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
        let usage: RawUsage?                      // engine per-step usage, or the CLI's per-message usage (ignored)
        let modelUsage: [String: RawModelUsage]?  // CLI result only — the per-model run aggregate
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
        struct RawUsage: Decodable {
            let provider: String?; let model: String?
            let input_tokens: Int?; let output_tokens: Int?
            let cache_read_tokens: Int?; let cache_write_tokens: Int?           // engine
            let cache_read_input_tokens: Int?; let cache_creation_input_tokens: Int?  // CLI
            let cost_usd: Double?; let search_calls: Int?; let fetch_calls: Int?  // engine
            let server_tool_use: ServerToolUse?                                   // CLI
            struct ServerToolUse: Decodable { let web_search_requests: Int?; let web_fetch_requests: Int? }
        }
        struct RawModelUsage: Decodable {
            let inputTokens: Int?; let outputTokens: Int?
            let cacheReadInputTokens: Int?; let cacheCreationInputTokens: Int?
            let webSearchRequests: Int?; let webFetchRequests: Int?; let costUSD: Double?
        }
    }
    private struct RawSummary: Decodable {
        let headline: String?
        let status: String?
        let sourcesConsulted: Int?
        let note: String?
        let findings: [RawFinding]?
        let conflicts: [RawConflict]?
        let gaps: [String]?
        let citations: [RawCitation]?
        struct RawFinding: Decodable {
            let claim: String; let sources: [String]?; let confidence: String?
            let citations: [String]?   // marker ids tying the claim to quotes (PRD 03)
        }
        struct RawConflict: Decodable { let claim: String; let positions: [String]? }
        /// `source` is the per-topic contract's spelling, `source_id` the resolved one — accept both, and
        /// treat every field as optional so one odd entry costs its own citation, not the whole summary.
        struct RawCitation: Decodable {
            let id: String?; let source: String?; let source_id: String?
            let quote: String?; let start: Int?; let end: Int?; let match: String?; let page: Int?
        }
    }
    private struct RawAngleWrap: Decodable { let angles: [RawAngle]? }
    private struct RawAngle: Decodable {
        let title: String?; let name: String?; let angle: String?
        let prompt: String?; let question: String?; let description: String?
        let depth: String?   // planner's budget hint: "shallow" → run the angle at the draft preset
    }
}

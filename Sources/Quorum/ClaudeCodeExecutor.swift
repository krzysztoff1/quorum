import Foundation
import QuorumCore

/// A live snapshot of one topic's research as it streams — what the UI shows in real time.
struct LiveSource: Identifiable, Hashable, Sendable {
    var id: String { kind + "·" + value }
    let kind: String    // WebSearch / WebFetch / Read / Grep / Glob
    let value: String    // the query / url / path
    var isURL: Bool { value.hasPrefix("http") }
}

struct LiveSnapshot: Sendable {
    var topicID = ""
    var question = ""
    var thinking = ""
    var output = ""
    var sources: [LiveSource] = []
    var costUSD: Decimal = 0    // live cumulative spend for this agent (shown on its fan-out node)
}

/// The one production seam: runs a topic by spawning the Claude Code CLI headless as a supervised
/// subprocess. Read-only tools only, no permission prompts (unattended), a hard per-topic dollar
/// wall (`--max-budget-usd`), streamed JSON parsed for cost + thinking + output + sources, and
/// process kill on cancellation. The only place Quorum talks to the research engine. Pure parsing
/// lives (and is tested) in QuorumCore.ResearchOutputParser.
struct ClaudeCodeExecutor: ResearchExecutor, AnglePlanner {

    /// Live feed for the UI (thinking / output / sources). Separate from `RunContext.onPartial`,
    /// which is the supervisor's halt-capture. Snapshots are cumulative per topic, so applying the
    /// latest (FIFO on the main queue) is always correct — no delta ordering to get wrong.
    let onActivity: (@Sendable (LiveSnapshot) -> Void)?
    let model: ModelChoice

    init(onActivity: (@Sendable (LiveSnapshot) -> Void)? = nil, model: ModelChoice = .default) {
        self.onActivity = onActivity
        self.model = model
    }

    struct ExecutorError: LocalizedError { let message: String; var errorDescription: String? { message } }

    func run(_ topic: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
        guard let claudePath = ClaudeCLI.resolvePath() else {
            throw ExecutorError(message: "Claude Code CLI not found on PATH.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = buildArguments(for: topic)
        process.currentDirectoryURL = topic.projectURL
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let started = ctx.clock.now()
        if ctx.cancel.isCancelled { throw CancellationError() }   // cancelled mid-startup → don't launch an orphan
        do { try process.run() } catch {
            throw ExecutorError(message: "Failed to launch Claude Code: \(error.localizedDescription)")
        }
        // Register the kill AFTER launch — terminate() on an unlaunched NSTask raises "task not launched"
        // (the crash). If cancel already fired, onCancel runs this now with isRunning == true; if the
        // process exits first, isRunning is false → no-op.
        ctx.cancel.onCancel { if process.isRunning { process.terminate() } }   // pull the cord → kill the subprocess

        var transcript = ""
        var assistantText = ""
        var thinkingText = ""
        var sources: [LiveSource] = []
        var finalResult: String?
        var reportedCost = Decimal(0)
        var sessionID: String?
        var rateLimit: String?
        var sawDeltas = false   // prefer token-by-token deltas; ignore the duplicate full-message text

        do {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                if Task.isCancelled { break }
                transcript += line + "\n"
                guard let ev = ResearchOutputParser.parseStreamLine(line) else { continue }
                if let sid = ev.sessionID { sessionID = sid }
                if let type = ev.rateLimitType {
                    rateLimit = formatRateLimit(type: type, status: ev.rateLimitStatus, resetsAt: ev.rateLimitResetsAt)
                }

                if let total = ev.totalCostUSD, total > reportedCost {
                    ctx.onCost(total - reportedCost)   // supervisor accumulates increments
                    reportedCost = total
                }

                var changed = false
                if let d = ev.deltaText { assistantText += d; sawDeltas = true; changed = true }
                if let dt = ev.deltaThinking { thinkingText += dt; sawDeltas = true; changed = true }
                if !sawDeltas {   // fallback when partial messages aren't streaming
                    if let th = ev.thinking { thinkingText += th; changed = true }
                    if let tx = ev.assistantText { assistantText += tx; changed = true }
                }
                for tu in ev.toolUses where !tu.detail.isEmpty {
                    sources.append(LiveSource(kind: tu.name, value: tu.detail)); changed = true
                }
                if ev.type == "result", let r = ev.result { finalResult = r }

                if changed {
                    onActivity?(LiveSnapshot(topicID: topic.id, question: topic.question,
                                             thinking: thinkingText, output: assistantText,
                                             sources: sources, costUSD: reportedCost))
                    let headline = assistantText.split(separator: "\n").first.map { String($0.prefix(120)) } ?? "Research in progress"
                    ctx.onPartial(PartialFindings(headline: headline, findings: [],
                                                  sourcesConsulted: sources.count, writeupMarkdown: assistantText))
                }
            }
        } catch { /* pipe read error — fall through with whatever we captured */ }
        process.waitUntilExit()

        try Task.checkCancellation()   // if the supervisor killed us, let it classify the outcome

        let duration = Duration.seconds(max(0, ctx.clock.now().timeIntervalSince(started)))
        let out = ResearchOutputParser.parseFinal(finalResult ?? assistantText)
        return TopicFindings(
            id: topic.id, status: out.status, preset: topic.preset,
            headline: out.headline, findings: out.findings, conflicts: out.conflicts, gaps: out.gaps,
            sourcesConsulted: out.sourcesConsulted,
            costUSD: reportedCost, duration: duration,
            writeupMarkdown: out.writeup, transcript: transcript, note: out.note,
            sessionID: sessionID, rateLimit: rateLimit)
    }

    private func formatRateLimit(type: String, status: String?, resetsAt: Double?) -> String {
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

    // MARK: - CLI argument construction (isolated + inspectable)

    func buildArguments(for topic: PreparedTopic) -> [String] {
        let cfg = topic.runConfig
        if topic.role == .verify {
            // Cheap, no-tools re-check of the synthesis citations against the angle sources (in context).
            // Forced low effort + the caller's tiny cap — this must never cost more than a rounding error.
            return [
                "-p", verifyPrompt(for: topic),
                "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--permission-mode", "dontAsk",
                "--effort", "low",
                "--max-budget-usd", NSDecimalNumber(decimal: cfg.perTopicSpendCapUSD).stringValue,
                "--append-system-prompt", verifySystemPrompt(),
            ] + model.args
        }
        if topic.role == .synthesis {
            // Pure reconcile of the provided writeups — read-only tools (safety), steered off searching.
            let tools = GuardrailMapper.readOnlyTools
            return [
                "-p", synthesisPrompt(for: topic),
                "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--permission-mode", "dontAsk",
                "--tools", tools.joined(separator: ","),
                "--allowedTools", tools.joined(separator: " "),
                "--effort", cfg.effort.rawValue,
                "--max-budget-usd", NSDecimalNumber(decimal: cfg.perTopicSpendCapUSD).stringValue,
                "--append-system-prompt", synthesisSystemPrompt(),
            ] + model.args
        }
        let tools = topic.useProjectContext
            ? cfg.allowedTools
            : cfg.allowedTools.filter { $0 == "WebSearch" || $0 == "WebFetch" }

        var args: [String] = [
            "-p", researchPrompt(for: topic),
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",   // token-by-token streaming for the live feed
            "--permission-mode", "dontAsk",
            "--tools", tools.joined(separator: ","),
            "--allowedTools", tools.joined(separator: " "),
            "--effort", cfg.effort.rawValue,
            "--max-budget-usd", NSDecimalNumber(decimal: cfg.perTopicSpendCapUSD).stringValue,
            "--append-system-prompt", systemPrompt(for: topic),
        ]
        args += model.args
        if topic.useProjectContext { args += ["--add-dir", topic.projectURL.path] }
        return args
    }

    private func researchPrompt(for t: PreparedTopic) -> String {
        var p = "Research this thoroughly (\(t.runConfig.depth == .scan ? "quick scan" : "thorough dig")):\n\n\(t.question)\n"
        if let c = t.context, !c.isEmpty { p += "\nFocus / constraints: \(c)\n" }
        let brain = priorNotesExcerpt(t.priorNotes)
        if !brain.isEmpty {
            p += """

            Your brain already holds related notes (below). Build ON them: confirm or update what's \
            there and add what's new — don't just restate what's already known.

            \(brain)
            """
        }
        if t.useProjectContext {
            p += "\nYou may read the current project (working directory) as read-only grounding context for anything about \"this\" codebase/app.\n"
        }
        return p
    }

    /// Read a bounded excerpt of related prior notes to seed the run (story 30 — reads your brain
    /// first). Bounded so a large brain can't blow the prompt. ponytail: first 3 notes, ~1200 chars each.
    private func priorNotesExcerpt(_ notes: [URL]) -> String {
        notes.prefix(3).compactMap { url -> String? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let excerpt = text.count > 1200 ? String(text.prefix(1200)) + "\n…(truncated)" : text
            return "--- \(url.lastPathComponent) ---\n\(excerpt)"
        }.joined(separator: "\n\n")
    }

    private func systemPrompt(for t: PreparedTopic) -> String {
        """
        You are Quorum's unattended research engine. Your tools are READ-ONLY (web search, web fetch, read). \
        You cannot and must not write files or run commands.

        Do real research: fan out across multiple web searches, fetch and read primary sources, and \
        CROSS-CHECK every claim you intend to report against those sources before stating it. Aim to \
        consult about \(t.runConfig.sourceBudget) sources and follow obvious sub-questions within budget.

        Source quality matters more than search rank: prefer primary and authoritative sources — \
        official docs, standards, papers, first-party announcements, original data — over SEO content \
        farms, undated listicles, and rank-optimized aggregators that merely restate others. When \
        sources disagree, favor the more authoritative and more recent, and say so.

        Trust is the product. A claim you cannot corroborate must be marked "unverified" or dropped — \
        never presented as fact. If nothing solid can be verified, report status "inconclusive" honestly.

        If prior notes from the brain are included, treat them as existing knowledge to extend — \
        corroborate, update, or add to them rather than duplicate.

        Write a clear, well-structured, cited markdown writeup with a "## Sources" section listing each \
        source as a markdown link ([title](url)) — articles, docs, and videos. Then, as the very LAST \
        thing in your final message, append a fenced ```json block matching exactly:
        {"headline":"one-line takeaway","status":"complete|inconclusive","sourcesConsulted":<int>,\
        "findings":[{"claim":"...","sources":["url"],"confidence":"high|medium|low|unverified"}],\
        "note":"optional one-line caveat"}
        """
    }

    // MARK: - Synthesis (the fan-in summariser prompts)

    private func synthesisPrompt(for t: PreparedTopic) -> String {
        """
        \(t.context ?? "")

        Using ONLY the independent angle writeups above, write one unified, cited answer to the \
        original question. State where they agree, surface any conflicts, and fill the gaps between them.
        """
    }

    private func synthesisSystemPrompt() -> String {
        """
        You are Quorum's synthesis engine. You are given several INDEPENDENT research writeups on \
        the same question, produced by agents that did not see each other. Reconcile them into ONE \
        coherent, cited answer: where they agree, state it with confidence; where they conflict, \
        surface the conflict honestly; note gaps. Preserve citations from the source writeups and do \
        not fabricate. Do not start fresh research — reconcile what you were given.

        Do NOT dissolve disagreement into confident prose. Where the angles diverge on a factual \
        claim, keep it visible: include a "## Open conflicts" section (write "None found." explicitly \
        if there are none) AND list each conflict in the JSON `conflicts` array below. A claim only \
        one angle makes, or one cited by only one angle, is weaker — say so rather than presenting it \
        as settled.

        Also surface what is still UNKNOWN: add a "## Gaps & open questions" section (write "None." if \
        the answer is complete) AND list each open question in the JSON `gaps` array below. A gap is a \
        specific question the angles did not answer, or answered only weakly — the kind of thing worth \
        another round of research. Be concrete: each gap should read as a researchable question, not "more study needed".

        Write a clear markdown writeup with "## Open conflicts", "## Gaps & open questions", and \
        "## Sources" sections, then, as the very LAST thing in your message, append a fenced ```json \
        block matching exactly:
        {"headline":"one-line takeaway","status":"complete|inconclusive","sourcesConsulted":<int>,\
        "findings":[{"claim":"...","sources":["url"],"confidence":"high|medium|low|unverified"}],\
        "conflicts":[{"claim":"the disputed point","positions":["angle 1: says X","angle 3: says Y"]}],\
        "gaps":["specific unresolved question worth another round","..."],\
        "note":"optional one-line caveat"}
        """
    }

    // MARK: - Citation verify (the gated, cheap re-check)

    private func verifyPrompt(for t: PreparedTopic) -> String {
        t.context ?? ""
    }

    private func verifySystemPrompt() -> String {
        """
        You are Quorum's citation checker. You are given a synthesis writeup's findings and the FULL \
        list of sources the underlying research actually cited. Some findings cite a URL that appears in \
        NONE of those sources — a likely fabrication. Do NOT do new research and do NOT invent sources.

        For every finding: keep its claim, but each cited URL must appear in the provided source list. \
        If a citation is not in the list, drop it. If a finding is left with no supportable citation, \
        set its confidence to "unverified". Return the corrected findings — same set of claims, no new ones.

        Reply with ONLY a fenced ```json block matching exactly:
        {"findings":[{"claim":"...","sources":["url"],"confidence":"high|medium|low|unverified"}]}
        """
    }

    // MARK: - AnglePlanner: decompose one question into N independent angles

    func plan(question: String, count: Int, priorNotes: [URL], projectURL: URL,
              _ ctx: RunContext) async throws -> [ResearchAngle] {
        guard let claudePath = ClaudeCLI.resolvePath() else {
            throw ExecutorError(message: "Claude Code CLI not found on PATH.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = planArguments(question: question, count: count, priorNotes: priorNotes)
        process.currentDirectoryURL = projectURL
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        if ctx.cancel.isCancelled { throw CancellationError() }
        do { try process.run() } catch {
            throw ExecutorError(message: "Failed to launch Claude Code: \(error.localizedDescription)")
        }
        ctx.cancel.onCancel { if process.isRunning { process.terminate() } }   // see run() — register after launch

        var assistantText = ""
        var thinkingText = ""
        var finalResult: String?
        var reportedCost = Decimal(0)
        var sawDeltas = false
        do {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                if Task.isCancelled { process.terminate(); break }
                guard let ev = ResearchOutputParser.parseStreamLine(line) else { continue }
                if let total = ev.totalCostUSD, total > reportedCost {
                    ctx.onCost(total - reportedCost); reportedCost = total
                }
                var changed = false
                if let d = ev.deltaText { assistantText += d; sawDeltas = true; changed = true }
                if let dt = ev.deltaThinking { thinkingText += dt; sawDeltas = true; changed = true }
                if !sawDeltas {
                    if let th = ev.thinking { thinkingText += th; changed = true }
                    if let tx = ev.assistantText { assistantText += tx; changed = true }
                }
                if ev.type == "result", let r = ev.result { finalResult = r }
                if changed {
                    // Live trace of the decomposition (keyed "planning" so the app routes it apart).
                    onActivity?(LiveSnapshot(topicID: "planning", question: "Planning research angles",
                                             thinking: thinkingText, output: assistantText,
                                             sources: [], costUSD: reportedCost))
                }
            }
        } catch { /* pipe read error — parse whatever we captured */ }
        process.waitUntilExit()
        try Task.checkCancellation()
        return ResearchOutputParser.parseAngles(finalResult ?? assistantText)
    }

    private func planArguments(question: String, count: Int, priorNotes: [URL]) -> [String] {
        let tools = GuardrailMapper.readOnlyTools   // read-only by construction, even for the planner
        return [
            "-p", planPrompt(question: question, count: count, priorNotes: priorNotes),
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--permission-mode", "dontAsk",
            "--tools", tools.joined(separator: ","),
            "--allowedTools", tools.joined(separator: " "),
            "--effort", "low",
            "--max-budget-usd", "0.15",
            "--append-system-prompt", planSystemPrompt(count: count),
        ] + model.args
    }

    private func planPrompt(question: String, count: Int, priorNotes: [URL]) -> String {
        var p = "Question to decompose into \(count) distinct research angles:\n\n\(question)\n"
        let brain = priorNotesExcerpt(priorNotes)
        if !brain.isEmpty {
            p += "\nThe brain already holds related notes (below). Prefer angles that EXTEND or " +
                 "complement these rather than repeat what's known.\n\n\(brain)\n"
        }
        return p
    }

    private func planSystemPrompt(count: Int) -> String {
        """
        Decompose the user's question into \(count) DISTINCT, \
        non-overlapping research angles — different facets, sub-questions, or perspectives — that \
        together cover the question comprehensively. Each angle must stand alone: the researcher \
        assigned an angle will NOT see the others, so make each prompt fully self-contained.

        Do not research now and do not use tools — just think, then output ONLY a fenced ```json block \
        as the very LAST thing in your message, matching exactly:
        [{"title":"short label, <=6 words","prompt":"a full, self-contained research question"}]
        Return exactly \(count) angles unless the question is so narrow that fewer are genuinely distinct.
        """
    }
}

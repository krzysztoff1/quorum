import Foundation
import QuorumCore

/// Compares Quorum's blind fan-out + synthesis against one plain Claude Code CLI call on the same
/// question. Both arms share the same model, effort preset, and read-only tools, so the only variable
/// under test is the architecture (N blind agents + synthesis vs. one agent) — not model choice or tool
/// access. A third, separately prompted call judges the two writeups blind (labels randomized, no
/// mention of which system produced which), so the score isn't Quorum grading its own homework.
///
/// `swift run Quorum -- --benchmark` (or pass questions as extra args to override the defaults).
enum BenchmarkRunner {

    private static let model = ModelChoice.sonnet
    private static let preset = EffortPreset.standard
    private static let angleCount = 3
    private static let perTopicCap = Decimal(0.75)
    private static let quorumRunCap = Decimal(4)
    private static let perTopicTimeout = Duration.seconds(600)

    private static let defaultQuestions = [
        "As of 2026, what is Swift's approach to typed throws, and which Swift version introduced it?",
        "Should a new macOS app in 2026 use SwiftData or stick with Core Data / a raw SQLite layer? " +
        "What do experienced iOS/macOS developers actually recommend, and why?",
        "For a solo developer picking a database for a new side project in 2026 — Postgres, SQLite, or " +
        "a hosted service like Supabase/PlanetScale — what are the real tradeoffs, and which would most " +
        "experienced developers recommend for a project that might scale later?",
    ]

    struct ArmResult {
        let costUSD: Decimal
        let sourcesConsulted: Int
        let durationSeconds: Double
        let writeup: String
    }

    struct Scores: Decodable, Equatable {
        let groundedness: Int, comprehensiveness: Int, honesty: Int, clarity: Int
    }

    struct Verdict {
        let winner: String   // "quorum" / "traditional" / "tie" / "unparsed"
        let scoresQuorum: Scores?
        let scoresTraditional: Scores?
        let reasoning: String
        let raw: String
    }

    private struct RawVerdict: Decodable {
        let scoresA: Scores, scoresB: Scores
        let winner: String
        let reasoning: String
    }

    struct Row {
        let question: String
        let traditional: ArmResult
        let quorum: ArmResult
        let verdict: Verdict
    }

    static func run(arguments: [String]) async {
        selfCheck()

        let dryRun = arguments.contains("--dry-run")
        let questionArgs = arguments.filter { $0 != "--dry-run" }

        if dryRun {
            print("DRY RUN — DryRunExecutor: no subprocess, no API calls, no spend. Validates the pipeline only.")
        } else {
            let pf = Preflight.check(ClaudeCLIProbe())
            print("Preflight: \(pf.message)")
            guard pf.ok else { return }
        }

        let questions = questionArgs.isEmpty ? defaultQuestions : questionArgs
        let clock = SystemClock()
        let executor: any ResearchExecutor & AnglePlanner =
            dryRun ? DryRunExecutor(model: model) : ClaudeCodeExecutor(model: model)
        let stamp = ISO8601DateFormatter().string(from: clock.now()).replacingOccurrences(of: ":", with: "-")
        let outDir = URL(fileURLWithPath: ".scratch/benchmark/\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        print("\(questions.count) question(s) · model \(model.displayName) · preset \(preset.displayName)")
        print("Both arms: same model/effort/read-only tools. Quorum: \(angleCount) angles, single round.")
        print("Writing to \(outDir.path)\n")

        var rows: [Row] = []
        for (i, question) in questions.enumerated() {
            print("[\(i + 1)/\(questions.count)] \(question)")
            let row = await runOne(question: question, index: i, executor: executor, clock: clock, outDir: outDir)
            print("  traditional  \(money(row.traditional.costUSD))  \(row.traditional.sourcesConsulted) source(s)  \(fmtSeconds(row.traditional.durationSeconds))")
            print("  quorum       \(money(row.quorum.costUSD))  \(row.quorum.sourcesConsulted) source(s)  \(fmtSeconds(row.quorum.durationSeconds))")
            print("  judge winner: \(row.verdict.winner)\n")
            rows.append(row)
        }

        let reportPath = outDir.appendingPathComponent("report.md")
        try? renderReport(rows).write(to: reportPath, atomically: true, encoding: .utf8)
        let readmePath = outDir.appendingPathComponent("readme-snippet.md")
        try? renderReadmeSnippet(rows).write(to: readmePath, atomically: true, encoding: .utf8)
        print("Report: \(reportPath.path)")
        print("README snippet: \(readmePath.path)")
    }

    // MARK: - One question, both arms, blind judge

    private static func runOne(question: String, index: Int, executor: any ResearchExecutor & AnglePlanner,
                               clock: RunClock, outDir: URL) async -> Row {
        let brainURL = outDir.appendingPathComponent("q\(index)-quorum-brain", isDirectory: true)
        try? FileManager.default.createDirectory(at: brainURL, withIntermediateDirectories: true)
        let config = RunSettings(projectURL: brainURL, runSpendCapUSD: quorumRunCap,
                                 perTopicSpendCapUSD: perTopicCap, perTopicTimeout: perTopicTimeout,
                                 defaultPreset: preset)

        async let traditional = runTraditional(question: question, cwd: outDir, executor: executor, clock: clock)
        async let quorum = runQuorum(question: question, config: config, executor: executor, clock: clock)
        let (t, q) = await (traditional, quorum)

        write(t.writeup, "q\(index)-traditional.md", in: outDir)
        write(q.writeup, "q\(index)-quorum.md", in: outDir)

        let quorumIsA = Bool.random()
        let verdict = await runJudge(question: question,
                                     responseA: quorumIsA ? q.writeup : t.writeup,
                                     responseB: quorumIsA ? t.writeup : q.writeup,
                                     quorumIsA: quorumIsA, cwd: outDir, executor: executor, clock: clock)
        write(verdict.raw, "q\(index)-judge.md", in: outDir)

        return Row(question: question, traditional: t, quorum: q, verdict: verdict)
    }

    private static func runTraditional(question: String, cwd: URL, executor: any ResearchExecutor & AnglePlanner,
                                       clock: RunClock) async -> ArmResult {
        let cfg = GuardrailMapper.runConfig(preset: preset, perTopicSpendCap: perTopicCap,
                                            perTopicTimeout: perTopicTimeout, depthOverride: nil)
        let prepared = PreparedTopic(id: "traditional", question: question, context: question,
                                     projectURL: cwd, useProjectContext: false,
                                     preset: preset, runConfig: cfg, role: .plain)
        let outcome = await Supervisor.supervise(prepared, executor: executor, clock: clock,
                                                 runSpent: 0, runCap: perTopicCap, startedAt: clock.now())
        let f = outcome.findings
        return ArmResult(costUSD: f.costUSD, sourcesConsulted: f.sourcesConsulted,
                         durationSeconds: f.duration.seconds, writeup: f.writeupMarkdown)
    }

    private static func runQuorum(question: String, config: RunSettings, executor: ClaudeCodeExecutor,
                                  clock: RunClock) async -> ArmResult {
        let store = DiskFindingsStore()
        let angles = (try? await planAngles(question: question, count: angleCount, config: config,
                                            planner: executor, store: store, clock: clock)) ?? []
        guard !angles.isEmpty else {
            return ArmResult(costUSD: 0, sourcesConsulted: 0, durationSeconds: 0,
                             writeup: "_The planner returned no usable angles._")
        }
        let report = await runFanOut(question: question, angles: angles, config: config, executor: executor,
                                     clock: clock, store: store, power: IOKitPowerManager(), notifier: UNNotifier())
        let synth = report.entries.first { $0.isSynthesis == true }
        let writeup = synth?.notePath.flatMap { try? String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8) }
            ?? "_No note written (see the per-angle artifacts in the run dir)._"
        return ArmResult(costUSD: report.totalCostUSD, sourcesConsulted: synth?.sourcesConsulted ?? 0,
                         durationSeconds: report.totalDurationSeconds, writeup: writeup)
    }

    private static func runJudge(question: String, responseA: String, responseB: String, quorumIsA: Bool,
                                 cwd: URL, executor: ClaudeCodeExecutor, clock: RunClock) async -> Verdict {
        let prompt = """
        You are an impartial evaluator comparing two independent answers to the SAME research question. \
        You do not know which system produced which — judge only what's on the page. Do not reward length \
        or formatting for their own sake; a short correct answer beats a long padded one. Do not search the \
        web or use any tool — judge strictly from the two texts below and your own background knowledge.

        Question: \(question)

        ===== RESPONSE A =====
        \(responseA)

        ===== RESPONSE B =====
        \(responseB)

        Score EACH response 1-10 on:
        - groundedness: are claims actually supported by their own cited sources, not fabricated or overreaching
        - comprehensiveness: real coverage of the question, not padding
        - honesty: does it flag what's uncertain/unverified rather than guessing confidently
        - clarity: easy to read and act on

        Then declare "A", "B", or "tie", with a short justification that cites specifics from both responses.

        Reply with ONLY a fenced ```json block, matching exactly:
        {"scoresA":{"groundedness":<1-10>,"comprehensiveness":<1-10>,"honesty":<1-10>,"clarity":<1-10>},
        "scoresB":{"groundedness":<1-10>,"comprehensiveness":<1-10>,"honesty":<1-10>,"clarity":<1-10>},
        "winner":"A|B|tie","reasoning":"..."}
        """
        let cfg = GuardrailMapper.runConfig(preset: .draft, perTopicSpendCap: perTopicCap,
                                            perTopicTimeout: perTopicTimeout, depthOverride: nil)
        let prepared = PreparedTopic(id: "judge", question: "judge", context: prompt,
                                     projectURL: cwd, useProjectContext: false,
                                     preset: .draft, runConfig: cfg, role: .plain)
        let outcome = await Supervisor.supervise(prepared, executor: executor, clock: clock,
                                                 runSpent: 0, runCap: perTopicCap, startedAt: clock.now())
        let text = outcome.findings.writeupMarkdown
        guard let (json, _) = ResearchOutputParser.lastJSONBlock(in: text),
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawVerdict.self, from: data) else {
            return Verdict(winner: "unparsed", scoresQuorum: nil, scoresTraditional: nil,
                           reasoning: "Judge output could not be parsed.", raw: text)
        }
        let (sq, st) = attributeScores(scoresA: raw.scoresA, scoresB: raw.scoresB, quorumIsA: quorumIsA)
        return Verdict(winner: attributeWinner(raw.winner, quorumIsA: quorumIsA),
                       scoresQuorum: sq, scoresTraditional: st, reasoning: raw.reasoning, raw: text)
    }

    // MARK: - Un-blinding (pure — this is what makes attribution trustworthy, so it gets a self-check)

    static func attributeWinner(_ rawWinner: String, quorumIsA: Bool) -> String {
        switch rawWinner.uppercased() {
        case "A": return quorumIsA ? "quorum" : "traditional"
        case "B": return quorumIsA ? "traditional" : "quorum"
        default:  return "tie"
        }
    }

    static func attributeScores(scoresA: Scores, scoresB: Scores, quorumIsA: Bool) -> (quorum: Scores, traditional: Scores) {
        quorumIsA ? (scoresA, scoresB) : (scoresB, scoresA)
    }

    private static func selfCheck() {
        assert(attributeWinner("A", quorumIsA: true) == "quorum")
        assert(attributeWinner("a", quorumIsA: false) == "traditional")
        assert(attributeWinner("B", quorumIsA: true) == "traditional")
        assert(attributeWinner("B", quorumIsA: false) == "quorum")
        assert(attributeWinner("tie", quorumIsA: true) == "tie")
        let sA = Scores(groundedness: 1, comprehensiveness: 2, honesty: 3, clarity: 4)
        let sB = Scores(groundedness: 5, comprehensiveness: 6, honesty: 7, clarity: 8)
        assert(attributeScores(scoresA: sA, scoresB: sB, quorumIsA: true) == (sA, sB))
        assert(attributeScores(scoresA: sA, scoresB: sB, quorumIsA: false) == (sB, sA))
    }

    // MARK: - Output

    private static func write(_ text: String, _ name: String, in dir: URL) {
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private static func money(_ d: Decimal) -> String { String(format: "$%.2f", (d as NSDecimalNumber).doubleValue) }
    private static func fmtDouble(_ d: Decimal) -> String { String(format: "%.2f", (d as NSDecimalNumber).doubleValue) }

    private static func fmtSeconds(_ s: Double) -> String {
        s < 60 ? String(format: "%.0fs", s) : String(format: "%.1fm", s / 60)
    }

    private static func renderMatrix(_ rows: [Row]) -> String {
        var s = "| Question | Traditional cost | Quorum cost | Traditional time | Quorum time | Judge winner |\n"
        s += "|---|---|---|---|---|---|\n"
        for (i, r) in rows.enumerated() {
            let q = r.question.count > 60 ? String(r.question.prefix(57)) + "…" : r.question
            s += "| Q\(i + 1): \(q) | \(money(r.traditional.costUSD)) | \(money(r.quorum.costUSD)) | "
            s += "\(fmtSeconds(r.traditional.durationSeconds)) | \(fmtSeconds(r.quorum.durationSeconds)) | \(r.verdict.winner) |\n"
        }
        return s
    }

    private static func renderMermaidCostChart(_ rows: [Row]) -> String {
        let labels = rows.indices.map { "\"Q\($0 + 1)\"" }.joined(separator: ", ")
        let t = rows.map { fmtDouble($0.traditional.costUSD) }.joined(separator: ", ")
        let q = rows.map { fmtDouble($0.quorum.costUSD) }.joined(separator: ", ")
        return """
        ```mermaid
        xychart-beta
            title "Cost per question (USD)"
            x-axis [\(labels)]
            y-axis "USD"
            bar "Traditional" [\(t)]
            bar "Quorum" [\(q)]
        ```
        """
    }

    private static func renderReport(_ rows: [Row]) -> String {
        let totalT = rows.reduce(Decimal(0)) { $0 + $1.traditional.costUSD }
        let totalQ = rows.reduce(Decimal(0)) { $0 + $1.quorum.costUSD }
        let quorumWins = rows.filter { $0.verdict.winner == "quorum" }.count
        let traditionalWins = rows.filter { $0.verdict.winner == "traditional" }.count
        let ties = rows.count - quorumWins - traditionalWins

        var s = "# Quorum vs. traditional Claude Code — benchmark\n\n"
        s += "Same model (\(model.displayName)), same effort preset (\(preset.displayName)), same "
        s += "read-only tools on both arms. The only variable is architecture: one plain Claude Code "
        s += "call vs. \(angleCount) blind parallel angles + a synthesis. Quorum ran a single round — "
        s += "iterative deepening (round 2+ on unresolved conflicts/gaps) was not exercised here.\n\n"
        s += "## Summary\n\n"
        s += "- Judge verdict: Quorum \(quorumWins) · Traditional \(traditionalWins) · Tie/unparsed \(ties) (of \(rows.count))\n"
        s += "- Total spend: traditional \(money(totalT)) vs. quorum \(money(totalQ))"
        if totalT > 0 {
            let mult = (totalQ as NSDecimalNumber).doubleValue / (totalT as NSDecimalNumber).doubleValue
            s += String(format: " (%.1fx)", mult)
        }
        s += "\n\n" + renderMatrix(rows) + "\n" + renderMermaidCostChart(rows) + "\n\n"

        for (i, r) in rows.enumerated() {
            s += "## Q\(i + 1): \(r.question)\n\n"
            if let sq = r.verdict.scoresQuorum, let st = r.verdict.scoresTraditional {
                s += "| | Traditional | Quorum |\n|---|---|---|\n"
                s += "| Groundedness | \(st.groundedness) | \(sq.groundedness) |\n"
                s += "| Comprehensiveness | \(st.comprehensiveness) | \(sq.comprehensiveness) |\n"
                s += "| Honesty | \(st.honesty) | \(sq.honesty) |\n"
                s += "| Clarity | \(st.clarity) | \(sq.clarity) |\n\n"
            }
            s += "**Judge winner: \(r.verdict.winner)** — \(r.verdict.reasoning)\n\n"
        }

        s += """
        ## Methodology & limitations

        - Both arms run the same model and effort preset, restricted to the same read-only tools \
        (WebSearch, WebFetch, Read, Grep, Glob) — this isolates architecture as the one variable, but \
        also means neither arm reflects a fully unrestricted Claude Code session.
        - The judge is Claude itself, blind to which response is which (order randomized per question), \
        told not to reward length. LLM judges are known to still carry some length/confidence bias, and \
        Quorum's synthesis is structurally longer (it's reconciling N writeups) — read the raw \
        `qN-traditional.md` / `qN-quorum.md` files yourself rather than trusting the verdict alone.
        - Quorum ran ONE round; the product's iterative deepening (re-fanning on unresolved conflicts/gaps) \
        never triggered here, so this understates what a full multi-round run could find.
        - \(rows.count) question(s) is too small a sample to generalize from — this is a spot check, not a \
        statistically powered study.
        """
        return s
    }

    private static func renderReadmeSnippet(_ rows: [Row]) -> String {
        var s = "<!-- Generated by `swift run Quorum -- --benchmark` — review before pasting into README.md -->\n\n"
        s += renderMatrix(rows) + "\n" + renderMermaidCostChart(rows) + "\n\n"
        s += "_Judged blind by a third Claude call, order randomized, told not to reward length — see the "
        s += "full report's Methodology & limitations section before treating this as ground truth._\n"
        return s
    }
}

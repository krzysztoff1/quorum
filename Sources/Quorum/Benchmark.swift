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
    private static let perTopicCap = Decimal(10)     // per angle, and the single traditional agent
    private static let quorumRunCap = Decimal(40)    // full quorum run per question = perTopicCap × (angles + 1 synthesis), so $10/angle actually binds (effective per-angle cap is min(perTopicCap, runCap/(angles+1)))
    private static let judgeCap = Decimal(0.5)       // grading is a short, no-web task
    private static let maxRounds = 2                 // iterative deepening: one extra round on unresolved conflicts/gaps, bounded by the run cap above
    private static let perTopicTimeout = Duration.seconds(600)

    // ponytail: single-run CLI, set once in run(). Names arm B in the console + report — "Traditional"
    // for the Claude-vs-Claude architecture test, or "ChatGPT Deep Research" when arm B is an external
    // file you supplied with --external.
    private static var armBLabel = "Traditional"

    // Set when --reuse-quorum loads the Quorum arm from a prior run's qN-quorum.md instead of re-running it,
    // so a second benchmark (vs. a different arm B) costs only the judge. Flips the cost lines to "reused".
    private static var reusedQuorum = false

    private static let defaultQuestions = [
        "As of 2026, what are the most promising methods for destroying PFAS (\"forever chemicals\") in " +
        "contaminated water, and how close is any of them to large-scale deployment? Distinguish what's " +
        "peer-reviewed and demonstrated at scale from what's still lab-stage or vendor claims.",
        "As of 2026, for grounding an LLM in a private document collection, what are the real tradeoffs " +
        "between retrieval-augmented generation (RAG) and long-context prompting? Which do experienced " +
        "practitioners recommend for which situations, and where does each actually fail?",
        "As of 2026, how urgent is the quantum threat to current public-key encryption, and where does " +
        "post-quantum cryptography migration actually stand? Separate NIST-standardized and deployed " +
        "schemes from research-stage claims, and 'harvest-now-decrypt-later' risk from imminent breaks.",
        "As of 2026, how do the leading AI training chips (NVIDIA Blackwell, Google TPU, AMD MI300-series, " +
        "and major custom silicon) actually compare for large-model training, and who is genuinely " +
        "competitive with NVIDIA? Separate independent benchmarks from vendor claims.",
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
        let externalDir = value(of: "--external", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let reuseQuorumDir = value(of: "--reuse-quorum", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let questionArgs = stripFlags(arguments, valueFlags: ["--external", "--reuse-quorum"], boolFlags: ["--dry-run"])

        if externalDir != nil { armBLabel = "ChatGPT Deep Research" }
        reusedQuorum = reuseQuorumDir != nil

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
        if let externalDir {
            print("Arm B: \(armBLabel) — reading qN.md from \(externalDir.path) (different model/tools; a win reflects the whole product, not architecture). Quorum: \(angleCount) angles, up to \(maxRounds) iterative rounds.")
        } else {
            print("Both arms: same model/effort/read-only tools. Quorum: \(angleCount) angles, up to \(maxRounds) iterative rounds.")
        }
        if let reuseQuorumDir {
            print("Quorum arm: REUSED from \(reuseQuorumDir.path) (loads qN-quorum.md by position — keep the same question order; only the judge spends).")
        }
        print("Writing to \(outDir.path)\n")

        var rows: [Row] = []
        for (i, question) in questions.enumerated() {
            print("[\(i + 1)/\(questions.count)] \(question)")
            let row = await runOne(question: question, index: i, executor: executor, clock: clock,
                                   outDir: outDir, externalDir: externalDir, reuseQuorumDir: reuseQuorumDir)
            let b = row.traditional
            let bMeasured = externalDir == nil
            print("  \(armBLabel.lowercased())  \(bMeasured ? "\(money(b.costUSD))  \(b.sourcesConsulted) source(s)  \(fmtSeconds(b.durationSeconds))" : "(external file — cost/time not measured)")")
            print("  quorum       \(reusedQuorum ? "(reused — not re-metered)" : "\(money(row.quorum.costUSD))  \(row.quorum.sourcesConsulted) source(s)  \(fmtSeconds(row.quorum.durationSeconds))")")
            print("  judge winner: \(displayWinner(row.verdict.winner))\n")
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
                               clock: RunClock, outDir: URL, externalDir: URL?, reuseQuorumDir: URL?) async -> Row {
        let brainURL = outDir.appendingPathComponent("q\(index)-quorum-brain", isDirectory: true)
        try? FileManager.default.createDirectory(at: brainURL, withIntermediateDirectories: true)
        let config = RunSettings(projectURL: brainURL, runSpendCapUSD: quorumRunCap,
                                 perTopicSpendCapUSD: perTopicCap, perTopicTimeout: perTopicTimeout,
                                 defaultPreset: preset)

        // Arm B is either an external file you supplied (--external) or a plain Claude Code call.
        // A missing external file never silently falls back to spending on Claude.
        async let traditional: ArmResult = externalDir == nil
            ? await runTraditional(question: question, cwd: outDir, executor: executor, clock: clock)
            : loadExternal(index: index, dir: externalDir!)
        // Quorum is either reused from a prior run's writeup (--reuse-quorum) or run fresh.
        async let quorum: ArmResult = reuseQuorumDir == nil
            ? await runQuorum(question: question, config: config, executor: executor, clock: clock)
            : loadQuorumWriteup(index: index, dir: reuseQuorumDir!)
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

    private static func runQuorum(question: String, config: RunSettings, executor: any ResearchExecutor & AnglePlanner,
                                  clock: RunClock) async -> ArmResult {
        let store = DiskFindingsStore()
        let angles = (try? await planAngles(question: question, count: angleCount, config: config,
                                            planner: executor, store: store, clock: clock)) ?? []
        guard !angles.isEmpty else {
            return ArmResult(costUSD: 0, sourcesConsulted: 0, durationSeconds: 0,
                             writeup: "_The planner returned no usable angles._")
        }
        let reports = await runIterativeFanOut(question: question, angles: angles, config: config,
                                               executor: executor, clock: clock, store: store,
                                               power: IOKitPowerManager(), notifier: UNNotifier(),
                                               maxRounds: maxRounds, autoresearch: false)
        let synth = reports.last?.entries.first { $0.isSynthesis == true }
        let raw = synth?.notePath.flatMap { try? String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8) }
            ?? "_No note written (see the per-angle artifacts in the run dir)._"
        return ArmResult(costUSD: reports.reduce(Decimal(0)) { $0 + $1.totalCostUSD },
                         sourcesConsulted: synth?.sourcesConsulted ?? 0,
                         durationSeconds: reports.reduce(0.0) { $0 + $1.totalDurationSeconds },
                         writeup: cleanWriteup(raw))
    }

    private static func runJudge(question: String, responseA: String, responseB: String, quorumIsA: Bool,
                                 cwd: URL, executor: any ResearchExecutor & AnglePlanner, clock: RunClock) async -> Verdict {
        let prompt = """
        You are an impartial evaluator comparing two independent answers to the SAME research question. \
        You do not know which system produced which — judge only what's on the page. Do not reward length \
        or formatting for their own sake; a short correct answer beats a long padded one. The two answers \
        may be written in different languages; judge only substance and never reward or penalize a response \
        for its language, and do not use language to guess which system it came from. Do not search the \
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
        let cfg = GuardrailMapper.runConfig(preset: .draft, perTopicSpendCap: judgeCap,
                                            perTopicTimeout: perTopicTimeout, depthOverride: nil)
        let prepared = PreparedTopic(id: "judge", question: "judge", context: prompt,
                                     projectURL: cwd, useProjectContext: false,
                                     preset: .draft, runConfig: cfg, role: .plain)
        let outcome = await Supervisor.supervise(prepared, executor: executor, clock: clock,
                                                 runSpent: 0, runCap: judgeCap, startedAt: clock.now())
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

    // MARK: - Arm B: external file (ChatGPT Deep Research) + arg parsing

    private static func loadExternal(index: Int, dir: URL) -> ArmResult {
        let url = dir.appendingPathComponent("q\(index + 1).md")
        let text = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            print("  ⚠️  no external answer at \(url.path) — arm B left empty for this question")
            return ArmResult(costUSD: 0, sourcesConsulted: 0, durationSeconds: 0,
                             writeup: "_No \(armBLabel) answer supplied for this question (expected \(url.lastPathComponent))._")
        }
        return ArmResult(costUSD: 0, sourcesConsulted: 0, durationSeconds: 0, writeup: text)
    }

    /// Load a prior run's Quorum writeup (already frontmatter-stripped when it was written) to reuse it as
    /// this run's Quorum arm — mapped by position (q<index>-quorum.md), so keep the question order identical.
    private static func loadQuorumWriteup(index: Int, dir: URL) -> ArmResult {
        let url = dir.appendingPathComponent("q\(index)-quorum.md")
        let text = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            print("  ⚠️  no Quorum writeup at \(url.path) — reused arm left empty for this question")
            return ArmResult(costUSD: 0, sourcesConsulted: 0, durationSeconds: 0,
                             writeup: "_No reused Quorum writeup found (expected \(url.lastPathComponent))._")
        }
        return ArmResult(costUSD: 0, sourcesConsulted: 0, durationSeconds: 0, writeup: text)
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func stripFlags(_ args: [String], valueFlags: [String], boolFlags: [String]) -> [String] {
        var out: [String] = []
        var dropNext = false
        for a in args {
            if dropNext { dropNext = false; continue }
            if boolFlags.contains(a) { continue }
            if valueFlags.contains(a) { dropNext = true; continue }
            out.append(a)
        }
        return out
    }

    private static func displayWinner(_ w: String) -> String {
        switch w {
        case "traditional": return armBLabel
        case "quorum":      return "Quorum"
        case "tie":         return "Tie"
        default:            return w
        }
    }

    private static var externalMode: Bool { armBLabel != "Traditional" }

    /// The judged Quorum writeup is its filed brain note, which the store wraps in YAML frontmatter and a
    /// `_Effort: … · $cost_` line — chrome that leaks cost/source metadata to the "blind" judge and cost it
    /// clarity in the first benchmark. Strip both so the judge sees the synthesized answer, like arm B's
    /// clean prose. The note stays intact on disk.
    private static func cleanWriteup(_ md: String) -> String {
        var lines = md.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(of: "---") {
            lines = Array(lines[(close + 1)...])
        }
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("_Effort:") }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
        var s = "| Question | \(armBLabel) cost | Quorum cost | \(armBLabel) time | Quorum time | Judge winner |\n"
        s += "|---|---|---|---|---|---|\n"
        for (i, r) in rows.enumerated() {
            let q = r.question.count > 60 ? String(r.question.prefix(57)) + "…" : r.question
            let bCost = externalMode ? "—" : money(r.traditional.costUSD)
            let bTime = externalMode ? "—" : fmtSeconds(r.traditional.durationSeconds)
            let qCost = reusedQuorum ? "reused" : money(r.quorum.costUSD)
            let qTime = reusedQuorum ? "—" : fmtSeconds(r.quorum.durationSeconds)
            s += "| Q\(i + 1): \(q) | \(bCost) | \(qCost) | \(bTime) | \(qTime) | \(displayWinner(r.verdict.winner)) |\n"
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
            bar "\(armBLabel)" [\(t)]
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

        var s = externalMode
            ? "# Quorum vs. \(armBLabel) — benchmark\n\n"
            : "# Quorum vs. traditional Claude Code — benchmark\n\n"
        if externalMode {
            s += "Quorum (\(model.displayName), \(angleCount) blind parallel angles + a synthesis, up to "
            s += "\(maxRounds) iterative rounds) against \(armBLabel) reports you supplied. This is a **product-vs-product** "
            s += "comparison — different model, tools, and agent — so a win reflects the whole product, "
            s += "not architecture in isolation.\n\n"
        } else {
            s += "Same model (\(model.displayName)), same effort preset (\(preset.displayName)), same "
            s += "read-only tools on both arms. The only variable is architecture: one plain Claude Code "
            s += "call vs. \(angleCount) blind parallel angles + a synthesis, iterated over up to \(maxRounds) "
            s += "rounds (round 2+ re-fans on unresolved conflicts/gaps).\n\n"
        }
        s += "## Summary\n\n"
        s += "- Judge verdict: Quorum \(quorumWins) · \(armBLabel) \(traditionalWins) · Tie/unparsed \(ties) (of \(rows.count))\n"
        if reusedQuorum {
            s += "- Quorum arm reused from a prior run (not re-metered here); only the judge spent this run.\n"
        } else if externalMode {
            s += "- Quorum spend: \(money(totalQ)) (\(armBLabel) cost/time not metered — external files)\n"
        } else {
            s += "- Total spend: \(armBLabel.lowercased()) \(money(totalT)) vs. quorum \(money(totalQ))"
            if totalT > 0 {
                let mult = (totalQ as NSDecimalNumber).doubleValue / (totalT as NSDecimalNumber).doubleValue
                s += String(format: " (%.1fx)", mult)
            }
            s += "\n"
        }
        s += "\n" + renderMatrix(rows) + "\n"
        if !externalMode { s += renderMermaidCostChart(rows) + "\n" }
        s += "\n"

        for (i, r) in rows.enumerated() {
            s += "## Q\(i + 1): \(r.question)\n\n"
            if let sq = r.verdict.scoresQuorum, let st = r.verdict.scoresTraditional {
                s += "| | \(armBLabel) | Quorum |\n|---|---|---|\n"
                s += "| Groundedness | \(st.groundedness) | \(sq.groundedness) |\n"
                s += "| Comprehensiveness | \(st.comprehensiveness) | \(sq.comprehensiveness) |\n"
                s += "| Honesty | \(st.honesty) | \(sq.honesty) |\n"
                s += "| Clarity | \(st.clarity) | \(sq.clarity) |\n\n"
            }
            s += "**Judge winner: \(displayWinner(r.verdict.winner))** — \(r.verdict.reasoning)\n\n"
        }

        let firstBullet = externalMode
            ? "- Arm B is an external \(armBLabel) report you supplied — a different model, tools, and agent " +
              "from Quorum. Cost, time, and sources for arm B are NOT measured, and a win here can't be " +
              "attributed to architecture alone (it's the whole product)."
            : "- Both arms run the same model and effort preset, restricted to the same read-only tools " +
              "(WebSearch, WebFetch, Read, Grep, Glob) — this isolates architecture as the one variable, but " +
              "also means neither arm reflects a fully unrestricted Claude Code session."
        s += """
        ## Methodology & limitations

        \(firstBullet)
        - The judge is Claude itself, blind to which response is which (order randomized per question), \
        told not to reward length. LLM judges are known to still carry some length/confidence bias, and \
        Quorum's synthesis is structurally longer (it's reconciling N writeups) — read the raw \
        `qN-traditional.md` / `qN-quorum.md` files yourself rather than trusting the verdict alone.
        - Quorum iterated up to \(maxRounds) rounds (round 2+ re-fans on the prior synthesis's unresolved \
        conflicts/gaps); all rounds share the one $\(fmtDouble(quorumRunCap)) run cap.
        - \(rows.count) question(s) is too small a sample to generalize from — this is a spot check, not a \
        statistically powered study.
        """
        return s
    }

    private static func renderReadmeSnippet(_ rows: [Row]) -> String {
        var s = "<!-- Generated by `swift run Quorum -- --benchmark` — review before pasting into README.md -->\n\n"
        s += renderMatrix(rows) + "\n"
        if !externalMode { s += renderMermaidCostChart(rows) + "\n" }
        s += "\n"
        s += "_Judged blind by a third Claude call, order randomized, told not to reward length — see the "
        s += "full report's Methodology & limitations section before treating this as ground truth._\n"
        return s
    }
}

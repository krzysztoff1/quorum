import Foundation
import QuorumCore

/// Compares Quorum's blind fan-out + synthesis against one or more opponents on the same set of
/// questions. Opponents can be run in any combination in a single invocation:
///   • **Traditional** — one plain Claude Code CLI call, same model/effort/read-only tools as Quorum
///     (architecture-isolated comparison).
///   • **External** — pre-written reports on disk you supplied (e.g. ChatGPT Deep Research); a
///     product-vs-product comparison, cost/time not measured.
/// The Quorum arm is computed ONCE per question and judged against each opponent, so adding a second
/// opponent adds only the extra judge calls, not another Quorum run.
///
/// Judging is hardened against the two failure modes the LLM-as-judge literature actually validates:
///   • Position bias: each judge is called TWICE per opponent per question (A=Quorum, then
///     A=opponent); a winner is only recorded if BOTH orders agree (see DeepResearch Bench,
///     arXiv:2506.11763).
///   • Family bias: a cross-family judge (OpenAI Codex CLI, if installed) runs the same two-position
///     protocol alongside Claude. A "consensus winner" requires ALL judgments to agree; anything less
///     is scored as a tie. Family bias is the only judge failure mode with a validated fix
///     (Panickssery et al., arXiv:2404.13076).
/// Scoring uses **binary rubric coverage** per question (DeepResearch Bench II style,
/// arXiv:2601.08536), not a 1–10 scale — grade compression makes holistic scales too easy to game.
///
/// Flags:
///   --dry-run              synthetic pipeline, no API calls, no spend
///   --external <dir>       append the External opponent, loading qN.md from <dir>
///   --no-traditional       drop the Traditional opponent (external-only comparison)
///   --no-codex             skip the cross-family judge (Claude judge only)
///   --reuse-quorum <dir>   load the Quorum arm from a prior run's qN-quorum.md
///
/// `swift run Quorum -- --benchmark` (or pass questions as extra args to override the defaults).
enum BenchmarkRunner {

    private static let model = ModelChoice.sonnet
    private static let preset = EffortPreset.standard
    private static let angleCount = 3
    private static let perTopicCap = Decimal(10)     // per angle, and per Traditional agent
    private static let quorumRunCap = Decimal(40)    // full quorum run per question
    private static let judgeCap = Decimal(0.5)       // per Claude judge call; N opponents × 2 orders → 2N per question
    private static let maxRounds = 2
    private static let perTopicTimeout = Duration.seconds(600)

    // Configured once at the top of run(), read everywhere below.
    private static var codexEnabled = true
    private static var reusedQuorum = false

    struct BenchmarkQuestion {
        let question: String
        let rubric: [String]
    }

    // ponytail: rubrics are lay-check coverage items, not domain-expert curation. Swap in an expert's
    // list per question if you're going to publish a headline number.
    private static let defaultQuestions: [BenchmarkQuestion] = [
        BenchmarkQuestion(
            question: "As of 2026, what are the most promising methods for destroying PFAS (\"forever chemicals\") in " +
                      "contaminated water, and how close is any of them to large-scale deployment? Distinguish what's " +
                      "peer-reviewed and demonstrated at scale from what's still lab-stage or vendor claims.",
            rubric: [
                "Names at least three distinct destruction methods (e.g. supercritical water oxidation, plasma, electrochemical, hydrothermal alkaline treatment)",
                "Distinguishes lab / bench scale from pilot from commercial deployment for each method",
                "Cites at least one peer-reviewed source and at least one primary vendor / regulatory source",
                "Flags energy or cost tradeoffs for the leading methods",
                "Explicitly separates vendor claims from independently verified results",
                "States what is still unverified or actively disputed",
            ]),
        BenchmarkQuestion(
            question: "As of 2026, for grounding an LLM in a private document collection, what are the real tradeoffs " +
                      "between retrieval-augmented generation (RAG) and long-context prompting? Which do experienced " +
                      "practitioners recommend for which situations, and where does each actually fail?",
            rubric: [
                "Defines RAG and long-context prompting distinctly, not as interchangeable",
                "Gives at least one concrete failure mode of long-context (e.g. lost-in-the-middle, cost, latency)",
                "Gives at least one concrete failure mode of RAG (e.g. retrieval miss, chunking artifacts, stale index)",
                "Names situations where each approach is preferred, with reasoning",
                "Mentions hybrid approaches or when to combine both",
                "Cites practitioner sources or benchmarks, not just vendor blogs",
            ]),
        BenchmarkQuestion(
            question: "As of 2026, how urgent is the quantum threat to current public-key encryption, and where does " +
                      "post-quantum cryptography migration actually stand? Separate NIST-standardized and deployed " +
                      "schemes from research-stage claims, and 'harvest-now-decrypt-later' risk from imminent breaks.",
            rubric: [
                "Names specific NIST-standardized PQC algorithms (e.g. ML-KEM/Kyber, ML-DSA/Dilithium, SLH-DSA/SPHINCS+)",
                "Separates standardized schemes from research-stage claims",
                "Explains harvest-now-decrypt-later risk distinctly from imminent-break risk",
                "Names at least one real deployment (browsers, TLS, cloud) with a version or date",
                "States current best estimate for cryptographically relevant quantum computer timing, with uncertainty",
                "Flags where claims are speculative or contested",
            ]),
        BenchmarkQuestion(
            question: "As of 2026, how do the leading AI training chips (NVIDIA Blackwell, Google TPU, AMD MI300-series, " +
                      "and major custom silicon) actually compare for large-model training, and who is genuinely " +
                      "competitive with NVIDIA? Separate independent benchmarks from vendor claims.",
            rubric: [
                "Covers all four families named in the question (NVIDIA Blackwell, Google TPU, AMD MI300-series, at least one custom silicon)",
                "Names at least one independent benchmark source (e.g. MLPerf) with a result",
                "Distinguishes training from inference performance",
                "Names software-stack lock-in (CUDA) as a factor, not only raw FLOPs",
                "Separates vendor performance claims from independently reproduced results",
                "States where a competitor is genuinely competitive vs. only on paper",
            ]),
    ]

    // MARK: - Opponent specs (a small enum, not a full protocol — only two shapes)

    enum OpponentSpec {
        case traditional
        case external(URL)

        var label: String {
            switch self {
            case .traditional:  return "Traditional"
            case .external:     return "ChatGPT Deep Research"
            }
        }
        var isMeasured: Bool { if case .traditional = self { return true } else { return false } }
    }

    struct ArmResult {
        let costUSD: Decimal
        let sourcesConsulted: Int
        let durationSeconds: Double
        let writeup: String
        let sourceDiversity: Double
    }

    struct Judgment {
        let judge: String            // "claude" or "codex"
        let quorumIsA: Bool
        let winner: String           // attributed: "quorum" / "opponent" / "tie" / "unparsed"
        let passesQuorum: [Bool]
        let passesOpponent: [Bool]
        let reasoning: String
        let raw: String
    }

    struct Verdict {
        let judgments: [Judgment]
        let consensusWinner: String  // all-agree, else "tie"
        let quorumPassRate: Double
        let opponentPassRate: Double
    }

    struct OpponentOutcome {
        let spec: OpponentSpec
        let arm: ArmResult
        let verdict: Verdict
    }

    private struct RawJudgment: Decodable {
        let passesA: [Bool], passesB: [Bool]
        let winner: String
        let reasoning: String
    }

    struct Row {
        let question: BenchmarkQuestion
        let quorum: ArmResult
        let opponents: [OpponentOutcome]
    }

    static func run(arguments: [String]) async {
        selfCheck()

        let dryRun = arguments.contains("--dry-run")
        let externalDir = value(of: "--external", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let reuseQuorumDir = value(of: "--reuse-quorum", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let noCodex = arguments.contains("--no-codex")
        let noTraditional = arguments.contains("--no-traditional")
        let questionArgs = stripFlags(arguments,
                                      valueFlags: ["--external", "--reuse-quorum"],
                                      boolFlags: ["--dry-run", "--no-codex", "--no-traditional"])

        var opponentSpecs: [OpponentSpec] = []
        if !noTraditional { opponentSpecs.append(.traditional) }
        if let externalDir { opponentSpecs.append(.external(externalDir)) }
        guard !opponentSpecs.isEmpty else {
            print("No opponents configured. Drop --no-traditional or add --external <dir>.")
            return
        }

        reusedQuorum = reuseQuorumDir != nil
        codexEnabled = !noCodex && !dryRun && CodexJudge.isAvailable()

        if dryRun {
            print("DRY RUN — DryRunExecutor: no subprocess, no API calls, no spend. Validates the pipeline only.")
        } else {
            let pf = Preflight.check(ClaudeCLIProbe())
            print("Preflight: \(pf.message)")
            guard pf.ok else { return }
            if noCodex {
                print("Cross-family judge: disabled by --no-codex (Claude judge only).")
            } else if !codexEnabled {
                print("Cross-family judge: codex CLI not on PATH — Claude judge only. Install `codex` to enable cross-family de-biasing.")
            } else {
                print("Cross-family judge: codex CLI found — Claude AND Codex will each judge in both orders (4 judgments per opponent per question).")
            }
        }

        let questions = questionArgs.isEmpty
            ? defaultQuestions
            : questionArgs.map { BenchmarkQuestion(question: $0, rubric: []) }
        let clock = SystemClock()
        let executor: any ResearchExecutor & AnglePlanner =
            dryRun ? DryRunExecutor(model: model) : ClaudeCodeExecutor(model: model)
        let stamp = ISO8601DateFormatter().string(from: clock.now()).replacingOccurrences(of: ":", with: "-")
        let outDir = URL(fileURLWithPath: ".scratch/benchmark/\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let opponentList = opponentSpecs.map { $0.label }.joined(separator: " + ")
        print("\(questions.count) question(s) · model \(model.displayName) · preset \(preset.displayName)")
        print("Opponents: \(opponentList). Quorum: \(angleCount) angles, up to \(maxRounds) iterative rounds.")
        if let reuseQuorumDir {
            print("Quorum arm: REUSED from \(reuseQuorumDir.path) (loads qN-quorum.md by position — keep the same question order; only the judge spends).")
        }
        print("Writing to \(outDir.path)\n")

        var rows: [Row] = []
        for (i, bq) in questions.enumerated() {
            print("[\(i + 1)/\(questions.count)] \(bq.question)")
            let row = await runOne(question: bq, index: i, opponentSpecs: opponentSpecs,
                                   executor: executor, clock: clock, outDir: outDir,
                                   reuseQuorumDir: reuseQuorumDir)
            print("  quorum       \(reusedQuorum ? "(reused — not re-metered) div \(fmtDiv(row.quorum.sourceDiversity))" : "\(money(row.quorum.costUSD))  \(row.quorum.sourcesConsulted) source(s)  \(fmtSeconds(row.quorum.durationSeconds))  div \(fmtDiv(row.quorum.sourceDiversity))")")
            for o in row.opponents {
                let arm = o.arm
                let armLine = o.spec.isMeasured
                    ? "\(money(arm.costUSD))  \(arm.sourcesConsulted) source(s)  \(fmtSeconds(arm.durationSeconds))  div \(fmtDiv(arm.sourceDiversity))"
                    : "(external file — cost/time not measured, div \(fmtDiv(arm.sourceDiversity)))"
                print("  vs \(o.spec.label)")
                print("    arm         \(armLine)")
                print("    rubric      opponent \(pct(o.verdict.opponentPassRate)) · quorum \(pct(o.verdict.quorumPassRate)) (\(o.verdict.judgments.count) judgment(s))")
                print("    consensus   \(displayWinner(o.verdict.consensusWinner, opponentLabel: o.spec.label))  [\(o.verdict.judgments.map { "\($0.judge)/\($0.quorumIsA ? "A=Q" : "A=Opp"):\($0.winner)" }.joined(separator: "  "))]")
            }
            print("")
            rows.append(row)
        }

        let reportPath = outDir.appendingPathComponent("report.md")
        try? renderReport(rows).write(to: reportPath, atomically: true, encoding: .utf8)
        let readmePath = outDir.appendingPathComponent("readme-snippet.md")
        try? renderReadmeSnippet(rows).write(to: readmePath, atomically: true, encoding: .utf8)
        print("Report: \(reportPath.path)")
        print("README snippet: \(readmePath.path)")
    }

    // MARK: - One question: run Quorum once, then judge against each opponent

    private static func runOne(question: BenchmarkQuestion, index: Int, opponentSpecs: [OpponentSpec],
                               executor: any ResearchExecutor & AnglePlanner, clock: RunClock,
                               outDir: URL, reuseQuorumDir: URL?) async -> Row {
        let brainURL = outDir.appendingPathComponent("q\(index)-quorum-brain", isDirectory: true)
        try? FileManager.default.createDirectory(at: brainURL, withIntermediateDirectories: true)
        let config = RunSettings(projectURL: brainURL, runSpendCapUSD: quorumRunCap,
                                 perTopicSpendCapUSD: perTopicCap, perTopicTimeout: perTopicTimeout,
                                 defaultPreset: preset)

        let quorum: ArmResult = reuseQuorumDir == nil
            ? await runQuorum(question: question.question, config: config, executor: executor, clock: clock)
            : loadQuorumWriteup(index: index, dir: reuseQuorumDir!)
        write(quorum.writeup, "q\(index)-quorum.md", in: outDir)

        var outcomes: [OpponentOutcome] = []
        for spec in opponentSpecs {
            let arm: ArmResult
            switch spec {
            case .traditional:
                arm = await runTraditional(question: question.question, cwd: outDir, executor: executor, clock: clock)
                write(arm.writeup, "q\(index)-traditional.md", in: outDir)
            case .external(let dir):
                arm = loadExternal(index: index, dir: dir)
                write(arm.writeup, "q\(index)-external.md", in: outDir)
            }

            var judgments: [Judgment] = []
            for quorumIsA in [true, false] {
                let responseA = quorumIsA ? quorum.writeup : arm.writeup
                let responseB = quorumIsA ? arm.writeup : quorum.writeup
                let prompt = judgePrompt(question: question, opponentLabel: spec.label,
                                         responseA: responseA, responseB: responseB)
                judgments.append(await runClaudeJudge(prompt: prompt, quorumIsA: quorumIsA,
                                                     cwd: outDir, executor: executor, clock: clock))
                if codexEnabled {
                    judgments.append(await runCodexJudge(prompt: prompt, quorumIsA: quorumIsA))
                }
            }

            let winners = judgments.map { $0.winner }
            let verdict = Verdict(
                judgments: judgments,
                consensusWinner: BenchmarkMetrics.allAgree(winners) ? (winners.first ?? "tie") : "tie",
                quorumPassRate: BenchmarkMetrics.meanPassRate(judgments.map { $0.passesQuorum }),
                opponentPassRate: BenchmarkMetrics.meanPassRate(judgments.map { $0.passesOpponent })
            )

            let opponentTag = spec.isMeasured ? "traditional" : "external"
            for (n, j) in judgments.enumerated() {
                write(j.raw, "q\(index)-vs-\(opponentTag)-judge\(n + 1)-\(j.judge)-A=\(j.quorumIsA ? "Q" : "Opp").md", in: outDir)
            }

            outcomes.append(OpponentOutcome(spec: spec, arm: arm, verdict: verdict))
        }

        return Row(question: question, quorum: quorum, opponents: outcomes)
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
                         durationSeconds: f.duration.seconds, writeup: f.writeupMarkdown,
                         sourceDiversity: BenchmarkMetrics.simpsonDiversity(BenchmarkMetrics.urlDomains(in: f.writeupMarkdown)))
    }

    private static func runQuorum(question: String, config: RunSettings, executor: any ResearchExecutor & AnglePlanner,
                                  clock: RunClock) async -> ArmResult {
        let store = DiskFindingsStore()
        let angles = (try? await planAngles(question: question, count: angleCount, config: config,
                                            planner: executor, store: store, clock: clock)) ?? []
        guard !angles.isEmpty else {
            return ArmResult(costUSD: 0, sourcesConsulted: 0, durationSeconds: 0,
                             writeup: "_The planner returned no usable angles._", sourceDiversity: 0)
        }
        let runDir = try? store.makeRunDirectory(projectURL: config.projectURL, startedAt: clock.now())
        let reports = await runIterativeFanOut(question: question, angles: angles, config: config,
                                               executor: executor, clock: clock, store: store,
                                               power: IOKitPowerManager(), notifier: UNNotifier(),
                                               maxRounds: maxRounds, autoresearch: false, runDir: runDir)
        let synth = reports.last?.entries.first { $0.isSynthesis == true }
        let raw = synth?.notePath.flatMap { try? String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8) }
            ?? "_No note written (see the per-angle artifacts in the run dir)._"
        let writeup = cleanWriteup(raw)
        return ArmResult(costUSD: reports.reduce(Decimal(0)) { $0 + $1.totalCostUSD },
                         sourcesConsulted: synth?.sourcesConsulted ?? 0,
                         durationSeconds: reports.reduce(0.0) { $0 + $1.totalDurationSeconds },
                         writeup: writeup,
                         sourceDiversity: BenchmarkMetrics.simpsonDiversity(BenchmarkMetrics.urlDomains(in: writeup)))
    }

    // MARK: - Judge (shared prompt, two executors)

    private static func judgePrompt(question: BenchmarkQuestion, opponentLabel: String,
                                    responseA: String, responseB: String) -> String {
        let rubricBlock: String
        if question.rubric.isEmpty {
            rubricBlock = "(No explicit rubric — return empty passesA/passesB arrays.)"
        } else {
            let numbered = question.rubric.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
            rubricBlock = """
            Rubric (each item is a COVERAGE check — pass = the response substantively addresses it with \
            a specific claim; do not accept vague hand-waves):
            \(numbered)
            """
        }
        return """
        You are an impartial evaluator comparing two independent answers to the SAME research question. \
        You do not know which system produced which — judge only what's on the page. Do not reward length \
        or formatting for their own sake; a short correct answer beats a long padded one. The two answers \
        may be written in different languages; judge only substance and never reward or penalize a response \
        for its language, and do not use language to guess which system it came from. Do not search the \
        web or use any tool — judge strictly from the two texts below and your own background knowledge.

        Question: \(question.question)

        \(rubricBlock)

        ===== RESPONSE A =====
        \(responseA)

        ===== RESPONSE B =====
        \(responseB)

        For EACH rubric item output a boolean per response (true = substantively covered). \
        Then declare a winner "A", "B", or "tie" with a short justification citing specifics.

        Reply with ONLY a fenced ```json block, matching exactly:
        {"passesA":[<bool>,...],"passesB":[<bool>,...],"winner":"A|B|tie","reasoning":"..."}
        """
    }

    private static func runClaudeJudge(prompt: String, quorumIsA: Bool, cwd: URL,
                                       executor: any ResearchExecutor & AnglePlanner, clock: RunClock) async -> Judgment {
        let cfg = GuardrailMapper.runConfig(preset: .draft, perTopicSpendCap: judgeCap,
                                            perTopicTimeout: perTopicTimeout, depthOverride: nil)
        let prepared = PreparedTopic(id: "judge-claude", question: "judge", context: prompt,
                                     projectURL: cwd, useProjectContext: false,
                                     preset: .draft, runConfig: cfg, role: .plain)
        let outcome = await Supervisor.supervise(prepared, executor: executor, clock: clock,
                                                 runSpent: 0, runCap: judgeCap, startedAt: clock.now())
        return parseJudgment(text: outcome.findings.writeupMarkdown, judge: "claude", quorumIsA: quorumIsA)
    }

    private static func runCodexJudge(prompt: String, quorumIsA: Bool) async -> Judgment {
        let text: String
        do { text = try await CodexJudge().judge(prompt: prompt) }
        catch {
            return Judgment(judge: "codex", quorumIsA: quorumIsA, winner: "unparsed",
                            passesQuorum: [], passesOpponent: [],
                            reasoning: "Codex call failed: \(error.localizedDescription)", raw: "")
        }
        return parseJudgment(text: text, judge: "codex", quorumIsA: quorumIsA)
    }

    private static func parseJudgment(text: String, judge: String, quorumIsA: Bool) -> Judgment {
        guard let (json, _) = ResearchOutputParser.lastJSONBlock(in: text),
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawJudgment.self, from: data) else {
            return Judgment(judge: judge, quorumIsA: quorumIsA, winner: "unparsed",
                            passesQuorum: [], passesOpponent: [],
                            reasoning: "Judge output could not be parsed.", raw: text)
        }
        let (pq, po) = quorumIsA ? (raw.passesA, raw.passesB) : (raw.passesB, raw.passesA)
        return Judgment(judge: judge, quorumIsA: quorumIsA,
                        winner: attributeWinner(raw.winner, quorumIsA: quorumIsA),
                        passesQuorum: pq, passesOpponent: po,
                        reasoning: raw.reasoning, raw: text)
    }

    // MARK: - Un-blinding

    static func attributeWinner(_ rawWinner: String, quorumIsA: Bool) -> String {
        switch rawWinner.uppercased() {
        case "A": return quorumIsA ? "quorum" : "opponent"
        case "B": return quorumIsA ? "opponent" : "quorum"
        default:  return "tie"
        }
    }

    private static func selfCheck() {
        assert(attributeWinner("A", quorumIsA: true) == "quorum")
        assert(attributeWinner("a", quorumIsA: false) == "opponent")
        assert(attributeWinner("B", quorumIsA: true) == "opponent")
        assert(attributeWinner("B", quorumIsA: false) == "quorum")
        assert(attributeWinner("tie", quorumIsA: true) == "tie")
        assert(BenchmarkMetrics.allAgree(["quorum", "quorum", "quorum", "quorum"]))
        assert(!BenchmarkMetrics.allAgree(["quorum", "quorum", "tie", "quorum"]))
    }

    // MARK: - Load helpers

    private static func loadExternal(index: Int, dir: URL) -> ArmResult {
        let url = dir.appendingPathComponent("q\(index + 1).md")
        let text = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            print("  ⚠️  no external answer at \(url.path) — external arm left empty for this question")
            return ArmResult(costUSD: 0, sourcesConsulted: 0, durationSeconds: 0,
                             writeup: "_No external answer supplied for this question (expected \(url.lastPathComponent))._",
                             sourceDiversity: 0)
        }
        return ArmResult(costUSD: 0, sourcesConsulted: 0, durationSeconds: 0, writeup: text,
                         sourceDiversity: BenchmarkMetrics.simpsonDiversity(BenchmarkMetrics.urlDomains(in: text)))
    }

    /// Load a prior run's Quorum writeup (already frontmatter-stripped when it was written) — mapped
    /// by position (q<index>-quorum.md), so keep the question order identical.
    private static func loadQuorumWriteup(index: Int, dir: URL) -> ArmResult {
        let url = dir.appendingPathComponent("q\(index)-quorum.md")
        let text = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            print("  ⚠️  no Quorum writeup at \(url.path) — reused arm left empty for this question")
            return ArmResult(costUSD: 0, sourcesConsulted: 0, durationSeconds: 0,
                             writeup: "_No reused Quorum writeup found (expected \(url.lastPathComponent))._",
                             sourceDiversity: 0)
        }
        return ArmResult(costUSD: 0, sourcesConsulted: 0, durationSeconds: 0, writeup: text,
                         sourceDiversity: BenchmarkMetrics.simpsonDiversity(BenchmarkMetrics.urlDomains(in: text)))
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

    private static func displayWinner(_ w: String, opponentLabel: String) -> String {
        switch w {
        case "opponent": return opponentLabel
        case "quorum":   return "Quorum"
        case "tie":      return "Tie (no cross-judge consensus)"
        default:         return w
        }
    }

    /// The judged Quorum writeup is its filed brain note, which the store wraps in YAML frontmatter
    /// and a `_Effort: … · $cost_` line — chrome that leaks cost/source metadata to the "blind" judge.
    /// Strip both so the judge sees the synthesized answer, like an external arm's clean prose.
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
    private static func fmtDiv(_ d: Double) -> String { String(format: "%.2f", d) }
    private static func pct(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }

    private static func fmtSeconds(_ s: Double) -> String {
        s < 60 ? String(format: "%.0fs", s) : String(format: "%.1fm", s / 60)
    }

    /// One matrix per opponent — rows=questions, columns=arm metrics and consensus. Simpler and more
    /// readable than a single mega-matrix when there are multiple opponents.
    private static func renderMatrixFor(_ opponentIndex: Int, label: String, isMeasured: Bool, _ rows: [Row]) -> String {
        var s = "### vs \(label)\n\n"
        s += "| Question | \(label) pass | Quorum pass | \(label) div | Quorum div | \(label) cost | Quorum cost | Consensus |\n"
        s += "|---|---|---|---|---|---|---|---|\n"
        for (i, r) in rows.enumerated() {
            let q = r.question.question.count > 60 ? String(r.question.question.prefix(57)) + "…" : r.question.question
            guard opponentIndex < r.opponents.count else { continue }
            let o = r.opponents[opponentIndex]
            let armCost = isMeasured ? money(o.arm.costUSD) : "—"
            let qCost = reusedQuorum ? "reused" : money(r.quorum.costUSD)
            s += "| Q\(i + 1): \(q) | \(pct(o.verdict.opponentPassRate)) | \(pct(o.verdict.quorumPassRate)) | \(fmtDiv(o.arm.sourceDiversity)) | \(fmtDiv(r.quorum.sourceDiversity)) | \(armCost) | \(qCost) | \(displayWinner(o.verdict.consensusWinner, opponentLabel: label)) |\n"
        }
        return s
    }

    private static func renderMermaidCostChart(_ rows: [Row], opponentIndex: Int, label: String) -> String {
        let labels = rows.indices.map { "\"Q\($0 + 1)\"" }.joined(separator: ", ")
        let armCost = rows.compactMap { $0.opponents[safe: opponentIndex]?.arm.costUSD }
            .map { fmtDouble($0) }.joined(separator: ", ")
        let q = rows.map { fmtDouble($0.quorum.costUSD) }.joined(separator: ", ")
        return """
        ```mermaid
        xychart-beta
            title "Cost per question (USD) vs \(label)"
            x-axis [\(labels)]
            y-axis "USD"
            bar "\(label)" [\(armCost)]
            bar "Quorum" [\(q)]
        ```
        """
    }

    /// The report iterates the opponents each row shares. Rows are validated to have the same opponent
    /// list (same order), so we key everything off the first row's opponents.
    private static func renderReport(_ rows: [Row]) -> String {
        guard let first = rows.first else { return "# Empty benchmark\n" }
        let opponents = first.opponents.map { $0.spec }
        let anyExternal = opponents.contains { !$0.isMeasured }
        let anyMeasured = opponents.contains { $0.isMeasured }

        var s = "# Quorum benchmark — vs \(opponents.map { $0.label }.joined(separator: " & "))\n\n"
        if anyExternal {
            s += "Includes an EXTERNAL opponent — a different model, tools, and agent from Quorum. "
            s += "Cost, time, and sources for external arms are NOT measured, and a win against an "
            s += "external product reflects the whole product, not architecture in isolation.\n\n"
        }
        if anyMeasured {
            s += "The Traditional opponent shares Quorum's model (\(model.displayName)), effort preset "
            s += "(\(preset.displayName)), and read-only tools — isolating architecture as the variable.\n\n"
        }
        s += "Quorum: \(angleCount) blind parallel angles + a synthesis, iterated up to \(maxRounds) rounds "
        s += "(round 2+ re-fans on unresolved conflicts/gaps).\n\n"

        s += "## Summary\n\n"
        for (idx, spec) in opponents.enumerated() {
            let qWins = rows.filter { $0.opponents[safe: idx]?.verdict.consensusWinner == "quorum" }.count
            let oWins = rows.filter { $0.opponents[safe: idx]?.verdict.consensusWinner == "opponent" }.count
            let ties = rows.count - qWins - oWins
            s += "- **vs \(spec.label)** (consensus, all judges + both orders agree): Quorum \(qWins) · \(spec.label) \(oWins) · Tie/no-consensus \(ties) (of \(rows.count))\n"
        }
        s += "- Judging protocol: \(codexEnabled ? "Claude AND Codex" : "Claude only") × two positions per opponent\n"

        if !reusedQuorum {
            let totalQ = rows.reduce(Decimal(0)) { $0 + $1.quorum.costUSD }
            s += "- Quorum spend: \(money(totalQ))"
            if anyMeasured, let tradIdx = opponents.firstIndex(where: { $0.isMeasured }) {
                let totalT = rows.reduce(Decimal(0)) { $0 + ($1.opponents[safe: tradIdx]?.arm.costUSD ?? 0) }
                let mult = totalT > 0 ? (totalQ as NSDecimalNumber).doubleValue / (totalT as NSDecimalNumber).doubleValue : 0
                s += " vs Traditional \(money(totalT))"
                if mult > 0 { s += String(format: " (%.1fx)", mult) }
            }
            s += "\n"
        } else {
            s += "- Quorum arm reused from a prior run (not re-metered here); only the judge spent this run.\n"
        }
        s += "\n"

        for (idx, spec) in opponents.enumerated() {
            s += renderMatrixFor(idx, label: spec.label, isMeasured: spec.isMeasured, rows) + "\n"
            if spec.isMeasured { s += renderMermaidCostChart(rows, opponentIndex: idx, label: spec.label) + "\n\n" }
        }

        for (i, r) in rows.enumerated() {
            s += "## Q\(i + 1): \(r.question.question)\n\n"
            if !r.question.rubric.isEmpty {
                s += "**Rubric (\(r.question.rubric.count) coverage items):**\n\n"
                for item in r.question.rubric { s += "- \(item)\n" }
                s += "\n"
            }
            s += "| | Quorum | \(r.opponents.map { $0.spec.label }.joined(separator: " | ")) |\n"
            s += "|---|---|" + String(repeating: "---|", count: r.opponents.count) + "\n"
            s += "| Rubric pass rate | \(pct(r.opponents.first?.verdict.quorumPassRate ?? 0)) | "
            s += r.opponents.map { pct($0.verdict.opponentPassRate) }.joined(separator: " | ") + " |\n"
            s += "| Source diversity (Simpson) | \(fmtDiv(r.quorum.sourceDiversity)) | "
            s += r.opponents.map { fmtDiv($0.arm.sourceDiversity) }.joined(separator: " | ") + " |\n"
            s += "| Sources consulted | \(r.quorum.sourcesConsulted) | "
            s += r.opponents.map { "\($0.arm.sourcesConsulted)" }.joined(separator: " | ") + " |\n\n"

            for o in r.opponents {
                s += "### vs \(o.spec.label)\n\n"
                s += "**Consensus: \(displayWinner(o.verdict.consensusWinner, opponentLabel: o.spec.label))**\n\n"
                for j in o.verdict.judgments {
                    let order = j.quorumIsA ? "A=Quorum, B=\(o.spec.label)" : "A=\(o.spec.label), B=Quorum"
                    s += "- `\(j.judge)` (\(order)) → \(displayWinner(j.winner, opponentLabel: o.spec.label)) — \(j.reasoning)\n"
                }
                s += "\n"
            }
        }

        s += """
        ## Methodology & limitations

        - Judging is hardened against the two failure modes the LLM-as-judge literature actually validates: \
        (1) position bias, mitigated by scoring both orders and requiring agreement; (2) family bias, \
        mitigated by adding OpenAI Codex as a cross-family judge. A "consensus winner" here requires all \
        \(codexEnabled ? "four" : "two") judgments (per opponent) to agree — anything less is scored as a \
        tie. This does not eliminate bias: partial-stack studies show 30–91% of self-preference bias \
        survives position-swap alone (arXiv:2604.22891), and no paper has published a clean residual for \
        the full swap + cross-family + reference-grounding stack.
        - Calibration bar: on the closest published benchmark (DeepResearch Bench's RACE, \
        arXiv:2506.11763), an LLM judge reaches 71.33% pairwise agreement with expert humans against a \
        68.44% human–human baseline — i.e. modestly at human level. Treat any judge verdict here as \
        roughly that reliable, no better.
        - Rubric scoring is binary coverage per question (DeepResearch Bench II style, \
        arXiv:2601.08536) — harder to game than a 1–10 scale, where agents systematically inflate to \
        7–8 on holistic dimensions. Rubrics here are lay-check coverage items; swap in domain-expert \
        curation before publishing a headline number.
        - Source diversity is Simpson `1 − Σpᵢ²` over the domains of URLs cited in each writeup. Higher \
        = drew from more independent domains. No standard exists for this metric on deep-research \
        reports — it's a proposed proxy for whether the fan-out actually consulted independent sources, \
        not a validated benchmark.
        - The Quorum arm is computed ONCE per question and judged against each opponent, so adding a \
        second opponent adds only the extra judge calls, not another Quorum run.
        - Quorum iterated up to \(maxRounds) rounds (round 2+ re-fans on the prior synthesis's \
        unresolved conflicts/gaps); all rounds share the one $\(fmtDouble(quorumRunCap)) run cap.
        - \(rows.count) question(s) is too small a sample to generalize from — this is a spot check, \
        not a statistically powered study.
        """
        return s
    }

    private static func renderReadmeSnippet(_ rows: [Row]) -> String {
        guard let first = rows.first else { return "" }
        var s = "<!-- Generated by `swift run Quorum -- --benchmark` — review before pasting into README.md -->\n\n"
        for (idx, spec) in first.opponents.map({ $0.spec }).enumerated() {
            s += renderMatrixFor(idx, label: spec.label, isMeasured: spec.isMeasured, rows) + "\n"
            if spec.isMeasured { s += renderMermaidCostChart(rows, opponentIndex: idx, label: spec.label) + "\n\n" }
        }
        s += "_Judged by \(codexEnabled ? "Claude AND Codex" : "Claude") — each in both orders per opponent — "
        s += "with a consensus winner only when all judgments agree. Rubric pass rate is atomic binary "
        s += "coverage; source diversity is Simpson over cited domains. See the full report's Methodology "
        s += "& limitations section before treating this as ground truth._\n"
        return s
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

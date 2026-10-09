import { describe, it, expect } from "vitest";
import { runRun, type RunConfig } from "../src/run.js";
import { sourceIdFor, type Citation, type QuoteMatch } from "../src/evidence.js";
import type { TopicOutcome, RunTopicConfig } from "../src/backend.js";
import type { UsageBlock } from "../src/emitter.js";
import {
  CRITIC_LENSES,
  CLAIM_BATCH_BUDGET_USD,
  claimBatches,
  claimSweepPrompt,
  claimUnits,
  parseClaimVerdicts,
  parseObjections,
  summarizeValidation,
  taskVerdicts,
  type ClaimUnit,
  type CriticLens,
  type ValidationRound,
} from "../src/validate.js";

const SNAPSHOT = "Cold starts fell 40% year over year in tested clusters, the authors report.";
const QUOTE = "fell 40% year over year";
const ANGLE_URL = "https://ex.test/a1";

function citation(id: string, quote: string, match: QuoteMatch = "exact"): Citation {
  return { id, source_id: "s1", quote, match, ...(match === "unresolved" ? {} : { start: 0, end: quote.length }) };
}

function unit(n: number): ClaimUnit {
  return { id: `k${n}`, claim: `claim ${n}`, citations: [citation(`c${n}`, `quote ${n}`)] };
}

describe("claim-bearing sentences", () => {
  it("keeps only sentences whose markers the evidence layer actually located", () => {
    const writeup = [
      "Cold starts rose 40% year over year.[^a1c1]",
      "That trend is expected to continue.",
      "Pricing doubled in 2025.[^a2c1]",
      "",
      "## Sources",
      "",
      "1. [Doc](https://ex.test/a1) — ✓ verified",
      "",
      "[^a1c1]: [Doc](https://ex.test/a1) — “fell 40% year over year”",
    ].join("\n");

    const units = claimUnits(writeup, [citation("a1c1", QUOTE), citation("a2c1", "never found", "unresolved")]);

    expect(units.map((u) => u.claim)).toEqual(["Cold starts rose 40% year over year."]);
    expect(units[0]!.citations.map((c) => c.id)).toEqual(["a1c1"]);
  });

  it("judges the sentence a marker decorates, not the paragraph around it", () => {
    const units = claimUnits("Latency halved.[^c1] Cost tripled.[^c2]", [citation("c1", "q1"), citation("c2", "q2")]);

    expect(units.map((u) => u.claim)).toEqual(["Latency halved.", "Cost tripled."]);
    expect(units.map((u) => u.citations.map((c) => c.id))).toEqual([["c1"], ["c2"]]);
  });

  it("reads no claim out of the fenced json the writeup ends with", () => {
    const result = "Latency halved.[^c1]\n\n```json\n" + JSON.stringify({ findings: [{ claim: "hidden.[^c1]" }] }) + "\n```";

    expect(claimUnits(result, [citation("c1", "q1")]).map((u) => u.claim)).toEqual(["Latency halved."]);
  });

  it("batches at most ten claims per verifier call", () => {
    const units = Array.from({ length: 23 }, (_, i) => unit(i + 1));

    expect(claimBatches(units).map((b) => b.length)).toEqual([10, 10, 3]);
  });

  it("hands the verifier the located quotes and nothing it could reason around them from", () => {
    const prompt = claimSweepPrompt("How did cold starts move?", [
      { id: "k1", claim: "Cold starts rose 40% year over year.", citations: [citation("a1c1", QUOTE)] },
    ]);

    expect(prompt).toContain("Cold starts rose 40% year over year.");
    expect(prompt).toContain(QUOTE);
    expect(prompt).not.toContain(SNAPSHOT);
    expect(prompt).not.toMatch(/search|fetch/i);
  });
});

describe("verdict parsing", () => {
  it("carries severity and reason on every non-supported verdict", () => {
    const units = [unit(1), unit(2)];
    const reply = "```json\n" + JSON.stringify({
      verdicts: [
        { claim: 1, verdict: "misquoted", severity: "blocking", reason: "the quote says fell, the claim says rose" },
        { claim: 2, verdict: "supported" },
      ],
    }) + "\n```";

    const { verdicts, unjudged } = parseClaimVerdicts(reply, units);

    expect(unjudged).toEqual([]);
    expect(verdicts[0]).toMatchObject({
      claim_id: "k1", verdict: "misquoted", severity: "blocking",
      reason: "the quote says fell, the claim says rose",
    });
    expect(verdicts[1]).toMatchObject({ claim_id: "k2", verdict: "supported" });
    expect(verdicts[1]!.severity).toBeUndefined();
  });

  it("names the quotes a failed claim was standing on, so the reader can badge them", () => {
    const reply = "```json\n" + JSON.stringify({
      verdicts: [
        { claim: 1, verdict: "unsupported", severity: "blocking" },
        { claim: 2, verdict: "supported" },
      ],
    }) + "\n```";

    const { verdicts } = parseClaimVerdicts(reply, [unit(1), unit(2)]);

    expect(verdicts[0]!.citation_ids).toEqual(["c1"]);
    expect(verdicts[1]!.citation_ids).toBeUndefined();
  });

  it("treats an unclassified objection as blocking rather than assuming it is minor", () => {
    const reply = "```json\n" + JSON.stringify({ verdicts: [{ claim: 1, verdict: "unsupported" }] }) + "\n```";

    expect(parseClaimVerdicts(reply, [unit(1)]).verdicts[0]!.severity).toBe("blocking");
  });

  it("reports a claim the verifier never ruled on as unjudged instead of as passed", () => {
    const reply = "```json\n" + JSON.stringify({ verdicts: [{ claim: 1, verdict: "supported" }] }) + "\n```";

    const { verdicts, unjudged } = parseClaimVerdicts(reply, [unit(1), unit(2)]);

    expect(verdicts).toHaveLength(1);
    expect(unjudged.map((u) => u.id)).toEqual(["k2"]);
  });

  it("reports every claim of an unparsable reply as unjudged", () => {
    const { verdicts, unjudged } = parseClaimVerdicts("I could not read the sources.", [unit(1), unit(2)]);

    expect(verdicts).toEqual([]);
    expect(unjudged).toHaveLength(2);
  });
});

describe("objection parsing", () => {
  const objection = (statement: string, followup: string, severity = "blocking") =>
    ({ statement, severity, followup });

  it("drops an objection no research could act on", () => {
    const reply = "```json\n" + JSON.stringify({
      objections: [
        objection("2025 pricing is missing", "find Acme's 2025 published pricing page"),
        objection("pricing is unclear", "verify pricing"),
        objection("no source for the growth figure", ""),
      ],
    }) + "\n```";

    const { objections, discarded } = parseObjections(reply, "coverage");

    expect(objections.map((o) => o.followup)).toEqual(["find Acme's 2025 published pricing page"]);
    expect(objections[0]).toMatchObject({ lens: "coverage", severity: "blocking" });
    expect(discarded).toBe(2);
  });

  it("caps a critic at three objections per round", () => {
    const reply = "```json\n" + JSON.stringify({
      objections: Array.from({ length: 5 }, (_, i) =>
        objection(`gap ${i}`, `find the 2025 filing that covers gap ${i}`)),
    }) + "\n```";

    const { objections, discarded } = parseObjections(reply, "coverage");

    expect(objections).toHaveLength(3);
    expect(discarded).toBe(0);
  });

  it("strips citation markers out of an objection so it cannot forge evidence", () => {
    const reply = "```json\n" + JSON.stringify({
      objections: [objection("the claim behind [^a1c1] is thin", "find a second source for the 40% figure")],
    }) + "\n```";

    expect(parseObjections(reply, "sources").objections[0]!.statement).not.toContain("[^a1c1]");
  });
});

/// R7/protocol v4 — one verdict per validator task per round, which is what the canvas draws. A task that
/// filed nothing passed; a task that filed something carries what it filed, never a fix for it.
describe("a verdict per validator task", () => {
  function round(overrides: Partial<ValidationRound> = {}): ValidationRound {
    return {
      round: 1, sweep: "run", critics: "run", claims_found: 2, claims_checked: 2,
      verdicts: [], objections: [], discarded_objections: 0, holds: true, ...overrides,
    };
  }

  it("returns one verdict for each of the four tasks, passing the ones that filed nothing", () => {
    const tasks = taskVerdicts(round());

    expect(tasks.map((t) => t.lens)).toEqual(["claim_sweep", ...CRITIC_LENSES]);
    expect(tasks.every((t) => t.status === "pass")).toBe(true);
    expect(tasks.every((t) => t.objections.length === 0)).toBe(true);
  });

  it("counts a failed claim as an objection of the sweep, carrying the task that would settle it", () => {
    const tasks = taskVerdicts(round({
      holds: false,
      verdicts: [
        { claim_id: "k1", claim: "Cold starts rose 40%.", verdict: "misquoted", severity: "blocking",
          reason: "the quote says fell" },
        { claim_id: "k2", claim: "Cost tripled.", verdict: "supported" },
      ],
      objections: [{ lens: "coverage", statement: "no 2025 pricing", severity: "blocking",
                     followup: "find Acme's 2025 published pricing page" }],
    }));
    const sweep = tasks.find((t) => t.lens === "claim_sweep")!;

    expect(sweep.status).toBe("objections(1)");
    expect(sweep.objections[0]).toMatchObject({ lens: "claim_sweep", severity: "blocking" });
    expect(sweep.objections[0]!.statement).toContain("misquoted");
    expect(sweep.objections[0]!.followup).toContain("Cold starts rose 40%.");
    expect(tasks.find((t) => t.lens === "coverage")!.status).toBe("objections(1)");
    expect(tasks.find((t) => t.lens === "conflicts")!.status).toBe("pass");
  });

  it("says a task was skipped rather than letting it read as a pass", () => {
    const tasks = taskVerdicts(round({ sweep: "skipped", critics: "skipped" }));

    expect(tasks.map((t) => t.status)).toEqual(["skipped", "skipped", "skipped", "skipped"]);
  });

  it("draws an objection nobody asked a model for as its own verdict", () => {
    const tasks = taskVerdicts(round({
      objections: [{ lens: "structure", statement: "a1 returned no machine-readable summary",
                     severity: "minor", followup: "run the a1 angle again and have it report a fenced json summary" }],
    }));

    expect(tasks.map((t) => t.lens)).toEqual(["claim_sweep", ...CRITIC_LENSES, "structure"]);
    expect(tasks.at(-1)).toMatchObject({ status: "objections(1)" });
  });

  it("ships the quotes still failing their claim, and only the ones the last round left failing", () => {
    const failed = (id: string, citations: string[]) =>
      ({ claim_id: id, claim: `claim ${id}`, verdict: "unsupported" as const, severity: "blocking" as const,
         citation_ids: citations });

    const summary = summarizeValidation([
      round({ holds: false, verdicts: [failed("k1", ["a1c1"]), failed("k2", ["a2c1"])] }),
      round({ round: 2, verdicts: [failed("k2", ["a2c1"]), { claim_id: "k3", claim: "fine",
                                                             verdict: "supported" }] }),
    ], 0.04, []);

    expect(summary.unsupported_citations).toEqual(["a2c1"]);
  });

  it("leaves an answer whose every claim held with nothing to badge", () => {
    const summary = summarizeValidation([round({
      verdicts: [{ claim_id: "k1", claim: "fine", verdict: "supported" }],
    })], 0.04, []);

    expect(summary.unsupported_citations).toEqual([]);
  });
});

function usage(cost: number): UsageBlock {
  return {
    provider: "deepseek", model: "deepseek-chat", input_tokens: 10, output_tokens: 5,
    cache_read_tokens: 0, cache_write_tokens: 0, cost_usd: cost, search_calls: 0, fetch_calls: 0,
  };
}

function outcomeOf(cfg: RunTopicConfig, result: string, status: TopicOutcome["status"] = "complete"): TopicOutcome {
  return {
    angle_id: cfg.angleId, role: cfg.role, backend: "engine", provider: "deepseek",
    model: "deepseek-chat", session_id: `qeng-${cfg.angleId}`, status,
    result, usage: usage(0.01), note: null,
  };
}

function fenced(payload: unknown): string {
  return "Judged.\n\n```json\n" + JSON.stringify(payload) + "\n```";
}

interface FixtureOptions {
  sentence?: string;
  verdicts?: unknown[];
  objections?: Partial<Record<CriticLens, unknown[]>>;
  sweepReply?: string;
  synthesisStatus?: TopicOutcome["status"];
}

const tick = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

/// One angle that captures a snapshot and quotes it verbatim, one synthesis that reuses that verified
/// marker on a sentence the fixture chooses, and a judge whose replies the test dictates.
function fixture(options: FixtureOptions = {}) {
  const sentence = options.sentence ?? "Cold starts rose 40% year over year.";
  const sourceId = sourceIdFor(ANGLE_URL);
  const calls: RunTopicConfig[] = [];
  const order: string[] = [];

  const runTopic = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
    if (cfg.role === "validate") {
      calls.push(cfg);
      order.push(`start:${cfg.angleId}`);
      await tick();
      order.push(`end:${cfg.angleId}`);
      if (cfg.angleId.startsWith("claim_sweep")) {
        return outcomeOf(cfg, options.sweepReply
          ?? fenced({ verdicts: options.verdicts ?? [{ claim: 1, verdict: "supported" }] }));
      }
      const lens = cfg.angleId.replace("critic_", "") as CriticLens;
      return outcomeOf(cfg, fenced({ objections: options.objections?.[lens] ?? [] }));
    }
    if (cfg.role === "synthesis") {
      const summary = {
        headline: "Cold starts", status: "complete", sourcesConsulted: 1,
        citations: [{ id: "a1c1", source: sourceId, quote: QUOTE }],
        findings: [{ claim: sentence, sources: [ANGLE_URL], citations: ["a1c1"], confidence: "high" }],
        conflicts: [], gaps: ["what happened to cold starts in 2026?"],
      };
      return outcomeOf(cfg, `${sentence}[^a1c1]\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\``,
                       options.synthesisStatus ?? "complete");
    }
    cfg.evidence!.register({ url: ANGLE_URL, title: "Cold start report", contentType: "html", text: SNAPSHOT });
    const summary = {
      headline: "Cold starts", status: "complete", sourcesConsulted: 1,
      citations: [{ id: "c1", source: sourceId, quote: QUOTE }],
      findings: [{ claim: "cold starts fell", sources: [ANGLE_URL], citations: ["c1"], confidence: "high" }],
    };
    return outcomeOf(cfg, `Cold starts fell.[^c1]\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\``);
  };

  return { calls, order, runTopic };
}

function collector() {
  const raw: string[] = [];
  return {
    sink: (l: string) => raw.push(l),
    events: () => raw.join("").split("\n").filter(Boolean).map((s) => JSON.parse(s)),
  };
}

const oneAngle: RunConfig = {
  question: "How did cold starts move year over year?",
  angles: [{ title: "Cold starts", prompt: "How did cold starts move?" }],
  angleModel: "deepseek/deepseek-chat", synthesisModel: "deepseek/deepseek-chat",
  runBudgetUSD: 2, perTopicBudgetUSD: 0.5, rounds: 1,
};

const CAPTURED = { QUORUM_TAVILY_KEY: "tk" };

async function validated(options: FixtureOptions = {}, env: Record<string, string> = CAPTURED) {
  const c = collector();
  const f = fixture(options);
  await runRun(oneAngle, env, { sink: c.sink, sessionId: "qrun-validate", now: () => 0, runTopic: f.runTopic });
  const events = c.events();
  return {
    events,
    calls: f.calls,
    order: f.order,
    validation: events.at(-1).validation,
    synthesis: events.filter((e) => e.type === "topic_result").find((e) => e.role === "synthesis"),
  };
}

describe("the claim sweep", () => {
  it("files a blocking misquote when the quote resolves but says the opposite", async () => {
    const run = await validated({
      verdicts: [{ claim: 1, verdict: "misquoted", severity: "blocking", reason: "the quote says fell, not rose" }],
    });

    expect(run.validation.status).toBe("validated");
    expect(run.validation.holds).toBe(false);
    expect(run.validation.rounds[0].verdicts).toEqual([
      expect.objectContaining({ verdict: "misquoted", severity: "blocking", claim: "Cold starts rose 40% year over year." }),
    ]);
  });

  it("ships the misquote badged on the answer rather than silently verified", async () => {
    const run = await validated({
      verdicts: [{ claim: 1, verdict: "misquoted", severity: "blocking", reason: "the quote says fell, not rose" }],
    });

    expect(run.synthesis.result).toContain("## Validation");
    expect(run.synthesis.result).toContain("misquoted");
    expect(run.synthesis.result).toContain("the quote says fell, not rose");
    expect(run.synthesis.result).not.toContain("✓ Validated");
  });

  it("passes a claim its quotes support, and says so once", async () => {
    const run = await validated({ sentence: "Cold starts fell 40% year over year." });

    expect(run.validation.holds).toBe(true);
    expect(run.validation.rounds[0]).toMatchObject({ sweep: "run", claims_found: 1, claims_checked: 1 });
    expect(run.synthesis.result).toContain("✓ Validated");
    expect(run.synthesis.result).not.toContain("blocking");
  });

  it("never fixes the answer it judges — the claim survives its own verdict", async () => {
    const run = await validated({
      verdicts: [{ claim: 1, verdict: "misquoted", severity: "blocking", reason: "the quote says fell, not rose" }],
    });
    const summary = JSON.parse(run.synthesis.result.split("```json")[1]!.split("```")[0]!);

    expect(summary.findings[0].claim).toBe("Cold starts rose 40% year over year.");
    expect(run.synthesis.result).toContain("Cold starts rose 40% year over year.");
  });

  it("announces the validating phase before the answer is emitted", async () => {
    const run = await validated();
    const types = run.events.map((e) => `${e.type}:${e.phase ?? e.role ?? ""}`);

    expect(types).toContain("phase:validating");
    expect(types.indexOf("phase:validating")).toBeLessThan(types.indexOf("topic_result:synthesis"));
  });

  it("skips the sweep on a run that captured no evidence, and marks it unvalidated", async () => {
    const run = await validated({}, {});

    expect(run.calls.filter((c) => c.angleId.startsWith("claim_sweep"))).toHaveLength(0);
    expect(run.validation.status).toBe("unvalidated");
    expect(run.validation.rounds[0].sweep).toBe("skipped");
    expect(run.synthesis.result).not.toContain("✓ Validated");
    expect(run.synthesis.result).toMatch(/no claim could be checked/i);
    expect(run.calls.filter((c) => c.angleId.startsWith("critic_"))).toHaveLength(3);
  });

  it("splits a long answer into parallel verifier calls of at most ten claims", async () => {
    const sentence = Array.from({ length: 11 }, (_, i) => `Claim number ${i + 1} holds.[^a1c1]`).join(" ");
    const run = await validated({ sentence, verdicts: [] });
    const sweeps = run.calls.filter((c) => c.angleId.startsWith("claim_sweep"));

    expect(sweeps.map((c) => c.angleId)).toEqual(["claim_sweep_1", "claim_sweep_2"]);
    expect(sweeps[0]!.prompt).toContain("CLAIM 10:");
    expect(sweeps[0]!.prompt).not.toContain("CLAIM 11:");
    expect(sweeps[1]!.prompt).toContain("CLAIM 1: Claim number 11 holds.");
    expect(run.order.slice(0, 2)).toEqual(["start:claim_sweep_1", "start:claim_sweep_2"]);
  });

  it("files an objection when the verifier returns nothing it can read", async () => {
    const run = await validated({ sweepReply: "The sources were unavailable to me." });

    expect(run.validation.rounds[0].claims_checked).toBe(0);
    expect(run.validation.rounds[0].objections).toEqual([
      expect.objectContaining({ lens: "claim_sweep", followup: expect.stringContaining("Cold starts") }),
    ]);
  });
});

describe("the three blind critics", () => {
  it("runs coverage, conflicts and sources in parallel, after the sweep", async () => {
    const run = await validated();
    const critics = run.order.filter((e) => e.includes("critic_"));

    expect(run.calls.map((c) => c.angleId)).toEqual(
      ["claim_sweep_1", ...CRITIC_LENSES.map((l) => `critic_${l}`)]);
    expect(run.order.indexOf("end:claim_sweep_1")).toBeLessThan(run.order.indexOf("start:critic_coverage"));
    expect(critics.slice(0, 3).every((e) => e.startsWith("start:"))).toBe(true);
  });

  it("keeps each critic blind to the others' objections", async () => {
    const run = await validated({
      objections: { coverage: [{ statement: "2025 pricing is missing", severity: "blocking", followup: "find Acme's 2025 pricing page" }] },
    });

    for (const call of run.calls) expect(call.prompt).not.toContain("2025 pricing is missing");
  });

  it("gives every validator a single tool-less turn on a low effort", async () => {
    const run = await validated();

    for (const call of run.calls) {
      expect(call.maxTurns).toBe(1);
      expect(call.effort).toBe("low");
      expect(call.spawn).toBeUndefined();
      expect(call.role).toBe("validate");
    }
  });

  /// R7 — the judge is routed apart from the writer, and capped per call, so a run cannot be talked into
  /// spending its answer's budget on opinions about it.
  it("judges on the configured validator model, within the per-call cap for its lens", async () => {
    const c = collector();
    const f = fixture();
    await runRun({ ...oneAngle, validatorModel: "openrouter/openai/gpt-5-mini" }, CAPTURED,
                 { sink: c.sink, sessionId: "qrun-validator-model", now: () => 0, runTopic: f.runTopic });

    expect(f.calls.map((call) => call.spec)).toEqual(
      Array(1 + CRITIC_LENSES.length).fill("openrouter/openai/gpt-5-mini"));
    expect(f.calls.find((call) => call.angleId === "claim_sweep_1")!.perTopicBudgetUsd).toBeLessThanOrEqual(CLAIM_BATCH_BUDGET_USD);
    for (const critic of f.calls.filter((call) => call.angleId.startsWith("critic_"))) {
      expect(critic.perTopicBudgetUsd).toBeLessThanOrEqual(0.1);
    }
  });

  it("falls back to the synthesis model when nothing else is configured to judge", async () => {
    const run = await validated();

    expect(run.calls.every((call) => call.spec === oneAngle.synthesisModel)).toBe(true);
  });

  it("routes a blocking objection into the run's record with the task that would resolve it", async () => {
    const run = await validated({
      objections: {
        coverage: [
          { statement: "the answer never states 2025 pricing", severity: "blocking", followup: "find Acme's 2025 published pricing page" },
          { statement: "vague", severity: "minor", followup: "check it" },
        ],
      },
    });

    expect(run.validation.rounds[0].objections).toEqual([
      expect.objectContaining({ lens: "coverage", severity: "blocking",
                                followup: "find Acme's 2025 published pricing page" }),
    ]);
    expect(run.validation.rounds[0].discarded_objections).toBe(1);
    expect(run.validation.holds).toBe(false);
    expect(run.synthesis.result).toContain("find Acme's 2025 published pricing page");
  });

  it("reads the angles' findings for conflicts and the answer for coverage", async () => {
    const run = await validated();
    const prompt = (lens: CriticLens) => run.calls.find((c) => c.angleId === `critic_${lens}`)!.prompt;

    expect(prompt("coverage")).toContain("How did cold starts move year over year?");
    expect(prompt("conflicts")).toContain("cold starts fell");
    expect(prompt("sources")).toContain(ANGLE_URL);
  });
});

describe("what the loop no longer rests on", () => {
  it("does not turn the synthesis's own self-reported gaps into the next round", async () => {
    const c = collector();
    const f = fixture();
    await runRun({ ...oneAngle, rounds: 2 }, CAPTURED,
                 { sink: c.sink, sessionId: "qrun-selfreport", now: () => 0, runTopic: f.runTopic });
    const events = c.events();

    expect(events.filter((e) => e.type === "round")).toHaveLength(0);
    expect(events.at(-1).topics.filter((t: TopicOutcome) => t.role === "research")).toHaveLength(1);
    const synthesis = events.filter((e) => e.type === "topic_result").find((e) => e.role === "synthesis");
    const summary = JSON.parse(synthesis.result.split("```json")[1]!.split("```")[0]!);
    expect(summary.gaps).toEqual(["what happened to cold starts in 2026?"]);
  });

  it("validates nothing when the synthesis itself failed", async () => {
    const run = await validated({ synthesisStatus: "error" });

    expect(run.calls).toHaveLength(0);
    expect(run.validation.rounds[0]).toMatchObject({ sweep: "skipped", critics: "skipped" });
  });

  it("spends nothing on validation once the run budget is gone", async () => {
    const c = collector();
    const f = fixture();
    await runRun({ ...oneAngle, runBudgetUSD: 0.02 }, CAPTURED,
                 { sink: c.sink, sessionId: "qrun-validate-budget", now: () => 0, runTopic: f.runTopic });

    expect(f.calls).toHaveLength(0);
    expect(String(c.events().at(-1).validation.rounds[0].note)).toMatch(/budget/i);
  });

  it("keeps validators out of the research record while their spend still counts", async () => {
    const run = await validated();

    expect(run.events.at(-1).topics.map((t: TopicOutcome) => t.role)).toEqual(["research", "synthesis"]);
    expect(run.validation.spend_usd).toBeCloseTo(0.04, 5);
    expect(run.events.at(-1).total_cost_usd).toBeCloseTo(0.06, 5);
  });
});

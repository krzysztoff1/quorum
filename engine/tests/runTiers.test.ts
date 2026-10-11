import { describe, expect, it } from "vitest";
import { runRun, type RunConfig } from "../src/run.js";
import type { RunTopicConfig, TopicOutcome } from "../src/backend.js";
import type { UsageBlock } from "../src/emitter.js";

const SNAPSHOT = "Cold starts fell 40% year over year in tested clusters, the authors report.";
const QUOTE = "fell 40% year over year";

function usage(cost: number): UsageBlock {
  return {
    provider: "claude-code", model: "sonnet", input_tokens: 10, output_tokens: 10, cache_read_tokens: 0,
    cache_write_tokens: 0, cost_usd: cost, search_calls: 0, fetch_calls: 0,
  };
}

function collector() {
  const raw: string[] = [];
  return { sink: (line: string) => raw.push(line), events: () => raw.join("").split("\n").filter(Boolean).map((l) => JSON.parse(l)) };
}

function outcomeOf(cfg: RunTopicConfig, result: string, status: TopicOutcome["status"] = "complete"): TopicOutcome {
  return {
    angle_id: cfg.angleId, role: cfg.role, backend: "cli", provider: "claude-code", model: "sonnet",
    session_id: `qeng-${cfg.angleId}`, status, result, usage: usage(0.01), note: null,
  };
}

function summaryOf(angleId: string, citations: unknown[], findings: unknown[]): string {
  const summary: Record<string, unknown> = { headline: `Finding for ${angleId}`, status: "complete", sourcesConsulted: 1, citations, findings };
  if (angleId === "synthesis") { summary.conflicts = []; summary.gaps = []; }
  return "```json\n" + JSON.stringify(summary) + "\n```";
}

interface Script {
  calls: { role: string; angleId: string; timeoutMs: number }[];
  advance?: { research?: number; synthesis?: number };
  hang?: (cfg: RunTopicConfig) => boolean;
  clock?: { now: number };
}

function scripted(script: Script): (cfg: RunTopicConfig) => Promise<TopicOutcome> {
  const advanced = new Set<string>();
  return async (cfg) => {
    script.calls.push({ role: cfg.role, angleId: cfg.angleId, timeoutMs: cfg.timeoutMs });
    const jump = script.advance?.[cfg.role as "research" | "synthesis"];
    if (jump && script.clock && !advanced.has(cfg.role)) {
      advanced.add(cfg.role);
      script.clock.now += jump * 1000;
    }
    if (script.hang?.(cfg)) {
      await new Promise<void>((resolve) => {
        if (cfg.signal?.aborted) resolve();
        cfg.signal?.addEventListener("abort", () => resolve(), { once: true });
      });
      return outcomeOf(cfg, "The run was halted before Claude produced output.\n\n" + summaryOf(cfg.angleId, [], []), "halted");
    }
    if (cfg.role === "validate") {
      const judged = cfg.angleId.startsWith("claim_sweep") ? { verdicts: [{ claim: 1, verdict: "supported" }] } : { objections: [] };
      return outcomeOf(cfg, "Judged.\n\n```json\n" + JSON.stringify(judged) + "\n```");
    }
    const document = cfg.evidence!.register({ url: `https://ex.test/${cfg.angleId}`, title: `Doc ${cfg.angleId}`, contentType: "html", text: SNAPSHOT });
    cfg.emitter.document(document);
    if (cfg.role === "synthesis") {
      return outcomeOf(cfg, `Cold starts fell 40% year over year.[^a1c1]\n\n` + summaryOf("synthesis",
        [{ id: "a1c1", source: document.source_id, quote: QUOTE }],
        [{ claim: "synthesized claim", sources: ["https://ex.test/a1"], citations: ["a1c1"], confidence: "high" }]));
    }
    return outcomeOf(cfg, `Cold starts fell 40% year over year in ${cfg.angleId}.[^c1]\n\n` + summaryOf(cfg.angleId,
      [{ id: "c1", source: document.source_id, quote: QUOTE }],
      [{ claim: `claim ${cfg.angleId}`, sources: [`https://ex.test/${cfg.angleId}`], citations: ["c1"], confidence: "high" }]));
  };
}

const angles = [
  { title: "Scientific breakeven", prompt: "Has fusion achieved net energy gain?" },
  { title: "Grid timeline", prompt: "When will fusion reach the grid?" },
];

const quick: RunConfig = { question: "Where does fusion energy stand?", tier: "quick", angles };
const deep: RunConfig = { ...quick, tier: "deep" };

async function runTier(config: RunConfig, script: Script, env: Record<string, string> = {}, clock?: { now: number }) {
  const c = collector();
  const outcome = await runRun(config, env, {
    sink: c.sink, sessionId: "qrun-tier", runTopic: scripted(script), ...(clock ? { now: () => clock.now } : {}),
  });
  const events = c.events();
  return { events, result: events.at(-1), outcome };
}

describe("the quick tier", () => {
  it("checks every claim against its quote, and files no critics", async () => {
    const script: Script = { calls: [] };
    const { result } = await runTier(quick, script);
    const judges = script.calls.filter((call) => call.role === "validate").map((call) => call.angleId);

    expect(judges).toContain("claim_sweep_1");
    expect(judges.filter((id) => id.startsWith("critic_"))).toEqual([]);
    expect(result.validation.rounds[0]).toMatchObject({ sweep: "run", critics: "skipped" });
    expect(result.status).toBe("complete");
  });

  it("runs a single round", async () => {
    const script: Script = { calls: [] };
    const { events } = await runTier(quick, script);
    expect(events.filter((e) => e.type === "round")).toEqual([]);
    expect(script.calls.filter((call) => call.role === "synthesis")).toHaveLength(1);
  });

  it("gives each stage its own timeout, none longer than the wall allows", async () => {
    const script: Script = { calls: [] };
    await runTier(quick, script);
    const timeoutOf = (role: string) => script.calls.find((call) => call.role === role)!.timeoutMs;

    expect(timeoutOf("research")).toBe(140_000);
    expect(timeoutOf("synthesis")).toBe(55_000);
    expect(timeoutOf("validate")).toBe(25_000);
  });

  it("reports the wall it ran under", async () => {
    const { events } = await runTier(quick, { calls: [] });
    expect(events.find((e) => e.type === "run_start")).toMatchObject({ tier: "quick" });
    expect(events.at(-1)).toMatchObject({ wall_hit: "none" });
  });
});

describe("the time left", () => {
  it("is estimated from the tier's own stage times when no past run is on disk", async () => {
    const { events } = await runTier(quick, { calls: [] });
    const progress = events.filter((e) => e.type === "run.progress");

    expect(progress.length).toBeGreaterThan(0);
    expect(progress.every((p) => Number.isFinite(p.eta_s) && p.eta_s >= 0)).toBe(true);
    expect(progress[0].eta_s).toBeGreaterThan(progress.at(-1).eta_s);
  });

  it("is absent for a run with no tier, which has no stage times to estimate from", async () => {
    const c = collector();
    await runRun({ question: "q", angles, rounds: 1 }, {}, { sink: c.sink, sessionId: "qrun-legacy", runTopic: scripted({ calls: [] }) });
    expect(c.events().filter((e) => e.type === "run.progress").some((p) => "eta_s" in p)).toBe(false);
  });
});

describe("the deep tier", () => {
  it("keeps the critics and has no wall", async () => {
    const script: Script = { calls: [] };
    const { result } = await runTier(deep, script);
    const judges = script.calls.filter((call) => call.role === "validate").map((call) => call.angleId);

    expect(judges).toEqual(expect.arrayContaining(["critic_coverage", "critic_conflicts", "critic_sources"]));
    expect(result.validation.rounds[0]).toMatchObject({ sweep: "run", critics: "run" });
    expect(result.wall_hit).toBe("none");
    expect(script.calls.find((call) => call.role === "synthesis")!.timeoutMs).toBe(300_000);
  });
});

describe("winding down before the wall", () => {
  it("skips the claim sweep once the wind-down has passed, and says the answer is partial", async () => {
    const clock = { now: 1_000_000 };
    const script: Script = { calls: [], advance: { research: 100, synthesis: 130 }, clock };
    const { result } = await runTier(quick, script, {}, clock);

    expect(script.calls.filter((call) => call.role === "validate")).toEqual([]);
    expect(result.validation.rounds[0]).toMatchObject({ sweep: "skipped", critics: "skipped" });
    expect(result.validation.rounds[0].note).toMatch(/wind/i);
    expect(result).toMatchObject({ status: "partial", wall_hit: "wind_down" });
    expect(result.note).toMatch(/4:30|270|limit/i);
    expect(result.topics.find((t: any) => t.role === "synthesis").status).toBe("complete");
  });

  it("never starts a synthesis that has no room left, and salvages the research instead", async () => {
    const clock = { now: 1_000_000 };
    const script: Script = { calls: [], advance: { research: 240 }, clock };
    const { result } = await runTier(quick, script, {}, clock);

    expect(script.calls.some((call) => call.role === "synthesis")).toBe(false);
    expect(result).toMatchObject({ status: "partial", wall_hit: "wind_down" });
    const salvage = result.topics.find((t: any) => t.role === "synthesis");
    expect(salvage.answer.check.ok).toBe(true);
    expect(salvage.result).toContain("claim a1");
  });

  it("leaves a run that finishes in time complete", async () => {
    const clock = { now: 1_000_000 };
    const script: Script = { calls: [], advance: { research: 60, synthesis: 40 }, clock };
    const { result } = await runTier(quick, script, {}, clock);
    expect(result).toMatchObject({ status: "complete", wall_hit: "none" });
  });
});

describe("the hard wall", () => {
  const tiny = { QUORUM_WALL_SCALE: "0.004" };

  it("kills a synthesis that will not finish and salvages a valid answer from the research", async () => {
    const script: Script = { calls: [], hang: (cfg) => cfg.role === "synthesis" };
    const started = Date.now();
    const { result, outcome } = await runTier(quick, script, tiny);

    expect(Date.now() - started).toBeLessThan(5_000);
    expect(outcome.status).toBe("partial");
    expect(result).toMatchObject({ status: "partial", wall_hit: "hard" });
    expect(result.note).toMatch(/limit/i);
    const salvage = result.topics.filter((t: any) => t.role === "synthesis").at(-1);
    expect(salvage.status).toBe("complete");
    expect(salvage.answer.check.ok).toBe(true);
    expect(salvage.answer.origin).toBe("prose");
    expect(salvage.result).toContain("claim a1");
    expect(salvage.result).toContain("claim a2");
    expect(salvage.citations.length).toBeGreaterThan(0);
  });

  it("salvages from the angles that finished when another one hangs", async () => {
    const script: Script = { calls: [], hang: (cfg) => cfg.role === "research" && cfg.angleId === "a2" };
    const { result } = await runTier(quick, script, tiny);

    expect(result.status).toBe("partial");
    const answer = result.topics.filter((t: any) => t.role === "synthesis").at(-1);
    expect(answer.result).toContain("claim a1");
    expect(answer.result).not.toContain("claim a2");
  });

  it("ends inconclusive, with no invented answer, when nothing had finished", async () => {
    const script: Script = { calls: [], hang: (cfg) => cfg.role === "research" };
    const { result } = await runTier(quick, script, tiny);

    expect(result.status).toBe("inconclusive");
    expect(result.wall_hit).toBe("hard");
    expect(result.topics.some((t: any) => t.role === "synthesis")).toBe(false);
    expect(result.note).toMatch(/limit/i);
  });

  it("is not a halt: a user's cancel still ends halted", async () => {
    const script: Script = { calls: [], hang: (cfg) => cfg.role === "research" };
    const controller = new AbortController();
    const c = collector();
    const pending = runRun(quick, {}, { sink: c.sink, sessionId: "qrun-cancel", runTopic: scripted(script), abortController: controller });
    setTimeout(() => controller.abort(), 30);
    const outcome = await pending;
    expect(outcome.status).toBe("halted");
  });
});

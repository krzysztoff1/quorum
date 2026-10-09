import { describe, it, expect } from "vitest";
import { parsePlannedAngles } from "../src/planner.js";
import { planPrompt, planSystemPrompt } from "../src/systemPrompt.js";
import { runRun, type RunConfig } from "../src/run.js";
import type { RunTopicConfig, TopicOutcome } from "../src/backend.js";
import type { UsageBlock } from "../src/emitter.js";

function usage(cost: number): UsageBlock {
  return {
    provider: "deepseek", model: "deepseek-chat", input_tokens: 0, output_tokens: 0,
    cache_read_tokens: 0, cache_write_tokens: 0, cost_usd: cost, search_calls: 0, fetch_calls: 0,
  };
}

function fenced(value: unknown): string {
  return `Thinking it through.\n\n\`\`\`json\n${JSON.stringify(value)}\n\`\`\``;
}

function scriptedTopic(plannerReply: string, seen: RunTopicConfig[] = []) {
  return async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
    seen.push(cfg);
    const summary = {
      headline: `Finding for ${cfg.angleId}`, status: "complete", sourcesConsulted: 1,
      findings: [{ claim: `claim ${cfg.angleId}`, sources: ["https://example.org"], confidence: "high" }],
      ...(cfg.role === "synthesis" ? { conflicts: [], gaps: [] } : {}),
    };
    return {
      angle_id: cfg.angleId, role: cfg.role, backend: "engine", provider: "deepseek",
      model: "deepseek-chat", session_id: `qeng-${cfg.angleId}`, status: "complete",
      result: cfg.role === "plan" ? plannerReply : `Body.\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\``,
      usage: usage(0.01), note: null,
    };
  };
}

function collector() {
  const raw: string[] = [];
  return {
    sink: (line: string) => raw.push(line),
    events: () => raw.join("").split("\n").filter(Boolean).map((s) => JSON.parse(s)),
  };
}

const unplanned: RunConfig = {
  question: "Where does fusion energy stand?",
  angleCount: 2,
  angleModel: "deepseek/deepseek-chat", synthesisModel: "deepseek/deepseek-chat",
  runBudgetUSD: 1.0, perTopicBudgetUSD: 0.5, maxTurns: 11, rounds: 1,
};

describe("parsePlannedAngles", () => {
  const ids = () => { let n = 0; return () => `a${++n}`; };

  it("reads the last fenced json array into angles numbered by the run", () => {
    const reply = fenced([
      { title: "Breakeven", prompt: "Has fusion achieved net energy gain?", depth: "deep" },
      { title: "Grid", prompt: "When will fusion reach the grid?" },
    ]);
    expect(parsePlannedAngles(reply, 5, ids())).toEqual([
      { angle_id: "a1", title: "Breakeven", prompt: "Has fusion achieved net energy gain?" },
      { angle_id: "a2", title: "Grid", prompt: "When will fusion reach the grid?" },
    ]);
  });

  it("accepts an {angles: [...]} wrapper and forgiving field names", () => {
    const reply = fenced({ angles: [{ name: "Risks", question: "What could go wrong?" }] });
    expect(parsePlannedAngles(reply, 3, ids())).toEqual([
      { angle_id: "a1", title: "Risks", prompt: "What could go wrong?" },
    ]);
  });

  it("titles an angle from its prompt when the model gave none, and drops angles with no prompt", () => {
    const reply = fenced([{ prompt: "  Compare reactor designs  " }, { title: "Empty" }]);
    expect(parsePlannedAngles(reply, 3, ids())).toEqual([
      { angle_id: "a1", title: "Compare reactor designs", prompt: "Compare reactor designs" },
    ]);
  });

  it("never returns more angles than were asked for", () => {
    const reply = fenced([1, 2, 3, 4].map((n) => ({ title: `T${n}`, prompt: `P${n}` })));
    expect(parsePlannedAngles(reply, 2, ids()).map((a) => a.angle_id)).toEqual(["a1", "a2"]);
  });

  it("returns nothing for text with no usable plan", () => {
    expect(parsePlannedAngles("no json here", 3, ids())).toEqual([]);
    expect(parsePlannedAngles("```json\n{not json}\n```", 3, ids())).toEqual([]);
    expect(parsePlannedAngles(fenced({ headline: "not a plan" }), 3, ids())).toEqual([]);
  });
});

describe("planner prompts", () => {
  it("asks for the requested number of self-contained angles in the question's language", () => {
    const system = planSystemPrompt(4);
    expect(system).toContain("4 DISTINCT");
    expect(system).toContain("Return exactly 4 angles");
    expect(system).toContain("in the language the user's question is written in");
    expect(system).toContain("fully self-contained");
  });

  it("hands the planner the question, and the brain only when there is one", () => {
    expect(planPrompt("Why is the sky blue?", 3)).toContain("decompose into 3 distinct research angles:\n\nWhy is the sky blue?");
    expect(planPrompt("Why?", 3)).not.toContain("brain");
    expect(planPrompt("Why?", 3, "--- note ---\nRayleigh")).toContain("Rayleigh");
  });
});

describe("the engine plans its own angles", () => {
  it("asks the model for the plan, tool-less, and researches the angles it returns", async () => {
    const c = collector();
    const seen: RunTopicConfig[] = [];
    const reply = fenced([
      { title: "Breakeven", prompt: "Has fusion achieved net energy gain?" },
      { title: "Grid", prompt: "When will fusion reach the grid?" },
    ]);
    await runRun(unplanned, {}, { sink: c.sink, sessionId: "qrun-plan", runTopic: scriptedTopic(reply, seen) });

    const planCall = seen.find((cfg) => cfg.role === "plan")!;
    expect(planCall.angleId).toBe("planning");
    expect(planCall.spec).toBe("deepseek/deepseek-chat");
    expect(planCall.systemPrompt).toBe(planSystemPrompt(2));
    expect(planCall.prompt).toContain("Where does fusion energy stand?");

    const ev = c.events();
    expect(ev.find((e) => e.type === "plan").angles.map((a: { title: string }) => a.title))
      .toEqual(["Breakeven", "Grid"]);
    expect(seen.filter((cfg) => cfg.role === "research").map((cfg) => cfg.prompt))
      .toEqual(["Has fusion achieved net energy gain?", "When will fusion reach the grid?"]);
  });

  it("counts what planning cost against the run", async () => {
    const planned = collector();
    const reply = fenced([{ title: "A", prompt: "pa" }]);
    await runRun({ ...unplanned, angleCount: 1 }, {}, { sink: planned.sink, sessionId: "qrun-cost", runTopic: scriptedTopic(reply) });

    const given = collector();
    await runRun({ ...unplanned, angles: [{ title: "A", prompt: "pa" }] }, {},
      { sink: given.sink, sessionId: "qrun-free", runTopic: scriptedTopic(reply) });

    expect(planned.events().at(-1).total_cost_usd - given.events().at(-1).total_cost_usd).toBeCloseTo(0.01, 5);
  });

  it("does not plan when the caller already supplied angles", async () => {
    const c = collector();
    const seen: RunTopicConfig[] = [];
    await runRun(
      { ...unplanned, angles: [{ title: "Given", prompt: "given prompt" }] }, {},
      { sink: c.sink, sessionId: "qrun-given", runTopic: scriptedTopic("unused", seen) });
    expect(seen.some((cfg) => cfg.role === "plan")).toBe(false);
  });

  it("hands the planner's angles the prior notes the user already holds", async () => {
    const c = collector();
    const seen: RunTopicConfig[] = [];
    const reply = fenced([{ title: "A", prompt: "pa" }]);
    await runRun({ ...unplanned, angleCount: 1, priorNotesExcerpt: "--- caching.md ---\nTTL is 5 minutes" }, {},
      { sink: c.sink, sessionId: "qrun-notes", runTopic: scriptedTopic(reply, seen) });

    const research = seen.filter((cfg) => cfg.role === "research");
    expect(research).toHaveLength(1);
    expect(research[0]!.prompt).toContain("TTL is 5 minutes");
    expect(research[0]!.prompt).toContain("pa");
  });

  it("plans on a small fixed budget, one low-effort turn, never the per-topic cap", async () => {
    const c = collector();
    const seen: RunTopicConfig[] = [];
    const reply = fenced([{ title: "A", prompt: "pa" }]);
    await runRun({ ...unplanned, angleCount: 1, perTopicBudgetUSD: 10 }, {},
      { sink: c.sink, sessionId: "qrun-budget", runTopic: scriptedTopic(reply, seen) });
    const planCall = seen.find((cfg) => cfg.role === "plan")!;
    expect(planCall.perTopicBudgetUsd).toBe(0.15);
    expect(planCall.effort).toBe("low");
    expect(planCall.maxTurns).toBe(1);
  });

  it("stops inconclusive, naming why, instead of researching generic angles, when the plan is unusable", async () => {
    const c = collector();
    const seen: RunTopicConfig[] = [];
    await runRun(unplanned, {}, { sink: c.sink, sessionId: "qrun-bad", runTopic: scriptedTopic("I cannot plan this.", seen) });

    const ev = c.events();
    expect(seen.map((cfg) => cfg.role)).toEqual(["plan"]);
    expect(ev.find((e) => e.type === "plan").angles).toEqual([]);
    const result = ev.at(-1);
    expect(result.type).toBe("run_result");
    expect(result.status).toBe("inconclusive");
    expect(result.note).toMatch(/planner/i);
    expect(result.topics).toEqual([]);
  });

  it("carries the planner's own reason when its call failed", async () => {
    const c = collector();
    const failing = async (cfg: RunTopicConfig): Promise<TopicOutcome> => ({
      angle_id: cfg.angleId, role: cfg.role, backend: "cli", provider: "claude-code", model: "m", session_id: "s",
      status: "error", result: "", usage: usage(0), note: "claude is not signed in",
    });
    await runRun(unplanned, {}, { sink: c.sink, sessionId: "qrun-fail", runTopic: failing });
    const result = c.events().at(-1);
    expect(result.status).toBe("inconclusive");
    expect(result.note).toContain("claude is not signed in");
  });

  it("halts without researching anything when Stop lands during planning", async () => {
    const c = collector();
    const seen: RunTopicConfig[] = [];
    const controller = new AbortController();
    const reply = fenced([{ title: "A", prompt: "pa" }, { title: "B", prompt: "pb" }]);
    const inner = scriptedTopic(reply, seen);
    const abortWhilePlanning = async (cfg: RunTopicConfig) => {
      const outcome = await inner(cfg);
      if (cfg.role === "plan") controller.abort();
      return outcome;
    };
    await runRun(unplanned, {}, { sink: c.sink, sessionId: "qrun-stop", runTopic: abortWhilePlanning, abortController: controller });

    expect(seen.map((cfg) => cfg.role)).toEqual(["plan"]);
    const result = c.events().at(-1);
    expect(result.status).toBe("halted");
    expect(result.note).toMatch(/planning/i);
  });
});

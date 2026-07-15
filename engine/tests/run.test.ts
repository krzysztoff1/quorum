import { describe, it, expect } from "vitest";
import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { runRun, type RunConfig, type RunDeps } from "../src/run.js";
import type { TopicOutcome, RunTopicConfig } from "../src/backend.js";
import type { UsageBlock } from "../src/emitter.js";

function usage(cost: number): UsageBlock {
  return {
    provider: "deepseek", model: "deepseek-chat", input_tokens: 100, output_tokens: 50,
    cache_read_tokens: 0, cache_write_tokens: 0, cost_usd: cost, search_calls: 1, fetch_calls: 0,
  };
}

function mockTopic(cost = 0.01): (cfg: RunTopicConfig) => Promise<TopicOutcome> {
  return async (cfg) => {
    cfg.emitter.textDelta(`Researching ${cfg.angleId}. `);
    cfg.emitter.toolUse("web_search", { query: `q-${cfg.angleId}` });
    cfg.emitter.usage(cost, usage(cost));
    const summary: Record<string, unknown> = {
      headline: `Finding for ${cfg.angleId}`, status: "complete", sourcesConsulted: 1,
      findings: [{ claim: `claim ${cfg.angleId}`, sources: ["https://example.org"], confidence: "high" }],
    };
    if (cfg.role === "synthesis") { summary.conflicts = []; summary.gaps = []; }
    return {
      angle_id: cfg.angleId, role: cfg.role, backend: "engine", provider: "deepseek",
      model: "deepseek-chat", session_id: `qeng-${cfg.angleId}`, status: "complete",
      result: `Body for ${cfg.angleId}.\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\``,
      usage: usage(cost), note: null,
    };
  };
}

function collector() {
  const raw: string[] = [];
  return {
    sink: (l: string) => raw.push(l),
    events: () => raw.join("").split("\n").filter(Boolean).map((s) => JSON.parse(s)),
  };
}

const twoAngles: RunConfig = {
  question: "Where does fusion energy stand?",
  angles: [
    { title: "Scientific breakeven", prompt: "Has fusion achieved net energy gain?" },
    { title: "Grid timeline", prompt: "When will fusion reach the grid?" },
  ],
  angleModel: "deepseek/deepseek-chat", synthesisModel: "deepseek/deepseek-chat",
  runBudgetUSD: 1.0, perTopicBudgetUSD: 0.5, maxTurns: 11, rounds: 1,
};

describe("run orchestrator", () => {
  it("emits the full run protocol and uses pre-approved angles (no planning)", async () => {
    const c = collector();
    const deps: RunDeps = {
      sink: c.sink, sessionId: "qrun-test", runTopic: mockTopic(),
      planAngles: () => { throw new Error("planner must not run when angles are pre-approved"); },
    };
    await runRun(twoAngles, {}, deps);
    const ev = c.events();
    const types = ev.map((e) => e.type);
    expect(types[0]).toBe("run_start");
    expect(types).toContain("plan");
    const plan = ev.find((e) => e.type === "plan");
    expect(plan.angles).toHaveLength(2);
    // one topic_result per angle + one synthesis
    const results = ev.filter((e) => e.type === "topic_result");
    expect(results.filter((r) => r.role === "research")).toHaveLength(2);
    expect(results.filter((r) => r.role === "synthesis")).toHaveLength(1);
    // per-angle live events are namespaced by angle_id
    const activity = ev.filter((e) => e.type === "usage" && e.angle_id);
    expect(activity.length).toBeGreaterThanOrEqual(2);
    const runResult = ev.at(-1);
    expect(runResult.type).toBe("run_result");
    expect(runResult.status).toBe("complete");
    expect(runResult.topics).toHaveLength(3);
  });

  it("plans its own angles when none are pre-approved", async () => {
    const c = collector();
    let planned = false;
    await runRun(
      { question: "q", angleCount: 2, angleModel: "deepseek/deepseek-chat", synthesisModel: "deepseek/deepseek-chat" },
      {},
      { sink: c.sink, sessionId: "qrun-2", runTopic: mockTopic(),
        planAngles: (input) => { planned = true; return [
          { angle_id: input.nextAngleId(), title: "A", prompt: "pa" },
          { angle_id: input.nextAngleId(), title: "B", prompt: "pb" },
        ]; } });
    expect(planned).toBe(true);
    expect(c.events().find((e) => e.type === "plan").angles).toHaveLength(2);
  });

  it("stops with an inconclusive run_result when the run budget is exceeded", async () => {
    const c = collector();
    await runRun(
      { ...twoAngles, runBudgetUSD: 0.005 },   // below one angle's cost → wall trips after round 1 research
      {},
      { sink: c.sink, sessionId: "qrun-3", runTopic: mockTopic(0.02),
        planAngles: () => [] });
    const runResult = c.events().at(-1);
    expect(runResult.type).toBe("run_result");
    expect(runResult.status).toBe("inconclusive");
    expect(String(runResult.note)).toContain("budget");
  });

  it("allocates parallel topic budgets so completed work cannot exceed the run cap", async () => {
    const c = collector();
    const assigned: Array<{ role: string; budget: number; maxTurns: number | undefined }> = [];
    const spendAssignedBudget = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      assigned.push({ role: cfg.role, budget: cfg.perTopicBudgetUsd, maxTurns: cfg.maxTurns });
      const cost = cfg.perTopicBudgetUsd;
      const summary: Record<string, unknown> = {
        headline: `Finding for ${cfg.angleId}`, status: "complete", sourcesConsulted: 1,
        findings: [{ claim: `claim ${cfg.angleId}`, sources: ["https://example.org"], confidence: "high" }],
      };
      if (cfg.role === "synthesis") { summary.conflicts = []; summary.gaps = []; }
      return {
        angle_id: cfg.angleId, role: cfg.role, backend: "engine", provider: "deepseek",
        model: "deepseek-chat", session_id: `qeng-${cfg.angleId}`, status: "complete",
        result: `Body.\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\``,
        usage: usage(cost), note: null,
      };
    };

    await runRun(
      { ...twoAngles, runBudgetUSD: 1, perTopicBudgetUSD: 0.9 },
      {},
      { sink: c.sink, sessionId: "qrun-budget-allocation", runTopic: spendAssignedBudget },
    );

    const result = c.events().at(-1);
    expect(result.status).toBe("complete");
    expect(result.total_cost_usd).toBeLessThanOrEqual(1);
    expect(assigned.filter((x) => x.role === "research")).toHaveLength(2);
    expect(assigned.find((x) => x.role === "synthesis")?.budget).toBeCloseTo(1 / 3);
    for (const topic of assigned) expect(topic.budget).toBeCloseTo(1 / 3);
    for (const topic of assigned) expect(topic.maxTurns).toBe(11);
  });

  it("never reports complete when a backend returns more spend than its assigned synthesis cap", async () => {
    const c = collector();
    const overspendSynthesis = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      const cost = cfg.role === "synthesis" ? 2 : 0.01;
      const summary: Record<string, unknown> = {
        headline: "Result", status: "complete", sourcesConsulted: 1,
        findings: [{ claim: "claim", sources: ["https://example.org"], confidence: "high" }],
      };
      if (cfg.role === "synthesis") { summary.conflicts = []; summary.gaps = []; }
      return {
        angle_id: cfg.angleId, role: cfg.role, backend: "engine", provider: "deepseek",
        model: "deepseek-chat", session_id: `qeng-${cfg.angleId}`, status: "complete",
        result: `Body.\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\``, usage: usage(cost), note: null,
      };
    };

    await runRun(twoAngles, {}, {
      sink: c.sink, sessionId: "qrun-synthesis-overspend", runTopic: overspendSynthesis,
    });
    const result = c.events().at(-1);
    expect(result.total_cost_usd).toBeGreaterThan(1);
    expect(result.status).toBe("inconclusive");
    expect(String(result.note)).toContain("budget");
  });

  it("gives each role its own system prompt and never leaks the template name into research", async () => {
    const c = collector();
    const seen: Array<{ role: string; systemPrompt: string; prompt: string }> = [];
    const spyTopic = async (cfg: RunTopicConfig) => {
      seen.push({ role: cfg.role, systemPrompt: cfg.systemPrompt, prompt: cfg.prompt });
      return mockTopic()(cfg);
    };
    await runRun({ ...twoAngles, template: "comparisonMatrix" }, {}, {
      sink: c.sink, sessionId: "qrun-prompts", runTopic: spyTopic,
    });
    const research = seen.filter((s) => s.role === "research");
    expect(research).toHaveLength(2);
    for (const r of research) {
      expect(r.systemPrompt).toContain("You are an unattended research engine.");
      expect(r.systemPrompt).not.toContain("comparisonMatrix");
      expect(r.systemPrompt).not.toContain("COMPARISON MATRIX");
    }
    const synthesis = seen.find((s) => s.role === "synthesis");
    expect(synthesis?.systemPrompt).toContain("Write to be SKIMMED");
    expect(synthesis?.systemPrompt).not.toContain("unattended research engine");
    expect(synthesis?.prompt).toContain("COMPARISON MATRIX");
    expect(synthesis?.prompt).toContain("Writeup excerpt:");
  });

  it("verifies untraceable synthesis citations with one cheap gated call and annotates the writeup", async () => {
    const c = collector();
    const seen: Array<{ role: string; budget: number; systemPrompt: string; prompt: string }> = [];
    const fabricating = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      seen.push({ role: cfg.role, budget: cfg.perTopicBudgetUsd, systemPrompt: cfg.systemPrompt, prompt: cfg.prompt });
      if (cfg.role === "research") return mockTopic()(cfg);
      if (cfg.role === "verify") {
        const corrected = { findings: [
          { claim: "made up", sources: [], confidence: "unverified" },
          { claim: "still fabricated", sources: ["https://fabricated.example/stubborn"], confidence: "low" },
        ] };
        return {
          angle_id: cfg.angleId, role: cfg.role, backend: "engine", provider: "deepseek",
          model: "deepseek-chat", session_id: "qeng-verify", status: "complete",
          result: `\`\`\`json\n${JSON.stringify(corrected)}\n\`\`\``, usage: usage(0.001), note: null,
        };
      }
      const summary = {
        headline: "Synthesis", status: "complete", sourcesConsulted: 2,
        findings: [
          { claim: "made up", sources: ["https://fabricated.example/nope"], confidence: "high" },
          { claim: "still fabricated", sources: ["https://fabricated.example/stubborn"], confidence: "high" },
        ],
        conflicts: [], gaps: [],
      };
      return {
        angle_id: cfg.angleId, role: cfg.role, backend: "engine", provider: "deepseek",
        model: "deepseek-chat", session_id: "qeng-synth", status: "complete",
        result: `Confident prose.\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\``, usage: usage(0.01), note: null,
      };
    };
    await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-verify", runTopic: fabricating });

    const verify = seen.find((s) => s.role === "verify");
    expect(verify, "an untraceable citation must trigger the verify pass").toBeDefined();
    expect(verify!.budget).toBeLessThanOrEqual(0.05);
    expect(verify!.systemPrompt).toContain("You are a citation checker.");
    expect(verify!.prompt).toContain("https://example.org");
    expect(verify!.prompt).toContain("https://fabricated.example/nope");

    const ev = c.events();
    const emitted = ev.filter((e) => e.type === "topic_result");
    expect(emitted.map((e) => e.role)).not.toContain("verify");
    const synth = emitted.find((e) => e.role === "synthesis");
    const corrected = JSON.parse(synth.result.split("```json")[1].split("```")[0]);
    expect(corrected.findings[0].confidence).toBe("unverified");
    expect(corrected.findings[0].sources).toHaveLength(0);
    expect(synth.result).toContain("## Citation check");
    expect(synth.result).toContain("https://fabricated.example/stubborn");
    expect(synth.result).not.toContain("https://fabricated.example/nope");
    expect(String(synth.note)).toContain("untraceable");

    const runResult = ev.at(-1);
    expect(runResult.topics.map((t: any) => t.role)).toContain("verify");
    expect(runResult.total_cost_usd).toBeCloseTo(0.02 + 0.01 + 0.001, 5);
  });

  it("skips the verify pass when every synthesis citation traces to an angle, including prose-only links", async () => {
    const c = collector();
    const roles: string[] = [];
    const proseCiting = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      roles.push(cfg.role);
      if (cfg.role === "research") {
        const summary = {
          headline: "H", status: "complete", sourcesConsulted: 1,
          findings: [{ claim: "c", sources: ["https://example.org"], confidence: "high" }],
        };
        return {
          angle_id: cfg.angleId, role: cfg.role, backend: "engine", provider: "deepseek",
          model: "deepseek-chat", session_id: `qeng-${cfg.angleId}`, status: "complete",
          result: `Body.\n\n## Sources\n- [Paper](https://prose-only.example/paper)\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\``,
          usage: usage(0.01), note: null,
        };
      }
      const summary = {
        headline: "Synthesis", status: "complete", sourcesConsulted: 2,
        findings: [
          { claim: "from findings", sources: ["https://example.org/"], confidence: "high" },
          { claim: "from prose", sources: ["https://prose-only.example/paper"], confidence: "medium" },
        ],
        conflicts: [], gaps: [],
      };
      return {
        angle_id: cfg.angleId, role: cfg.role, backend: "engine", provider: "deepseek",
        model: "deepseek-chat", session_id: "qeng-synth", status: "complete",
        result: `Prose.\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\``, usage: usage(0.01), note: null,
      };
    };
    await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-clean", runTopic: proseCiting });
    expect(roles).not.toContain("verify");
    const synth = c.events().filter((e) => e.type === "topic_result").find((e) => e.role === "synthesis");
    expect(synth.result).not.toContain("## Citation check");
  });

  it("records the run fixture for the Swift consumer contract test", async () => {
    const c = collector();
    await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-fixture", runTopic: mockTopic() });
    const lines = c.events();
    for (const e of lines) expect(typeof e.type).toBe("string");   // every line valid JSON with a type
    const dir = join(import.meta.dirname, "..", "fixtures");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "run-transcript.ndjson"), lines.map((e) => JSON.stringify(e)).join("\n") + "\n");
    expect(lines[0].type).toBe("run_start");
    expect(lines.at(-1).type).toBe("run_result");
  });
});

import { describe, it, expect } from "vitest";
import { writeFileSync, mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MockLanguageModelV4, convertArrayToReadableStream } from "ai/test";
import { runRun, type RunConfig, type RunDeps } from "../src/run.js";
import { EvidenceStore } from "../src/evidence.js";
import type { TopicOutcome, RunTopicConfig } from "../src/backend.js";
import type { UsageBlock } from "../src/emitter.js";
import type { SearchLike } from "../src/agent.js";

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

  it("constructs ONE search client shared by every angle in the run", async () => {
    const c = collector();
    let constructed = 0;
    const stubSearch: SearchLike = {
      search: async (query) => ({ results: [{ title: "t", url: "https://ex/1", snippet: query }] }),
      fetch: async (url) => ({ url, markdown: "doc" }),
    };
    const oneStepModel = () =>
      new MockLanguageModelV4({
        doStream: async () => ({
          stream: convertArrayToReadableStream([
            { type: "stream-start", warnings: [] },
            { type: "text-start", id: "0" },
            { type: "text-delta", id: "0", delta: 'Done.\n\n```json\n{"headline":"h","status":"complete","sourcesConsulted":1,"findings":[{"claim":"c","sources":["https://ex/1"],"confidence":"high"}],"conflicts":[],"gaps":[]}\n```' },
            { type: "text-end", id: "0" },
            { type: "finish", finishReason: "stop", usage: { inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 5, text: 5, reasoning: 0 }, totalTokens: 15 } },
          ]),
        }),
      });
    await runRun(twoAngles, { QUORUM_DEEPSEEK_KEY: "k", QUORUM_TAVILY_KEY: "k" }, {
      sink: c.sink, sessionId: "qrun-shared-search",
      backendDeps: {
        resolveModel: () => ({ model: oneStepModel(), provider: "deepseek", modelId: "deepseek-chat" }),
        makeSearchClient: () => {
          constructed++;
          return stubSearch;
        },
      },
    });
    expect(c.events().at(-1).type).toBe("run_result");
    expect(constructed, "N angles must share one rate-limited client, not build N×").toBe(1);
  });

  it("records the run fixture for the Swift consumer contract test", async () => {
    const c = collector();
    await runRun(twoAngles, {}, {
      sink: c.sink, sessionId: "qrun-fixture", now: () => 0, runTopic: citingTopic(),
    });
    const lines = c.events();
    for (const e of lines) expect(typeof e.type).toBe("string");   // every line valid JSON with a type
    const dir = join(import.meta.dirname, "..", "fixtures");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "run-transcript.ndjson"), lines.map((e) => JSON.stringify(e)).join("\n") + "\n");
    expect(lines[0].type).toBe("run_start");
    expect(lines[0].protocol_version).toBe(3);
    expect(lines.at(-1).type).toBe("run_result");
    expect(lines.some((e) => e.type === "document" && e.angle_id)).toBe(true);
    expect(lines.filter((e) => e.type === "topic_result").every((e) => Array.isArray(e.citations))).toBe(true);
    expect(lines.at(-1).documents.length).toBeGreaterThan(0);
    expect(lines.at(-1).topics).toHaveLength(3);   // the Swift golden test reads 2 angles + 1 synthesis
  });
});

/// The frontier: planned angles and spawned children run through one queue, and the run only synthesizes
/// once nothing is left to chase.
describe("frontier and spawning", () => {
  function spawningTopic(spawns: Record<string, { question: string; why: string }>) {
    return async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      const ask = spawns[cfg.angleId];
      if (ask && cfg.spawn) cfg.spawn({ ...ask, provoked_by: "s3f9a1c2" });
      return mockTopic()(cfg);
    };
  }

  function approvalsFor(verdicts: Array<{ id: string; verdict: "approved" | "rejected" }>) {
    const queue = [...verdicts];
    return { take: async () => queue.shift() };
  }

  const oneAngle: RunConfig = {
    ...twoAngles,
    angles: [{ title: "Scientific breakeven", prompt: "Has fusion achieved net energy gain?" }],
    runBudgetUSD: 40, perTopicBudgetUSD: 10,
  };

  it("draws the whole planned shape as graph nodes before any angle runs", async () => {
    const c = collector();
    await runRun(oneAngle, {}, { sink: c.sink, sessionId: "qrun-graph", runTopic: mockTopic() });
    const nodes = c.events().filter((e) => e.type === "graph_node");

    expect(nodes[0].node).toMatchObject({ id: "root", kind: "question", origin: "root" });
    expect(nodes[1].node).toMatchObject({ kind: "inquiry", depth: 1, origin: "planner" });
    expect(c.events().some((e) => e.type === "graph_edge" && e.edge.kind === "decomposes")).toBe(true);
  });

  it("files a spawned question as a pending node carrying its why and its price", async () => {
    const c = collector();
    await runRun({ ...oneAngle, spawnMode: "ask" }, {}, {
      sink: c.sink, sessionId: "qrun-pending", runTopic: spawningTopic({
        a1: { question: "What did the 2024 filing say about renewals?", why: "hit a paywall" },
      }),
    });
    const pending = c.events().find((e) => e.type === "graph_node" && e.node.status === "pending");

    expect(pending.node).toMatchObject({
      kind: "question", origin: "spawn", depth: 2,
      meta: { why: "hit a paywall", provoked_by: "s3f9a1c2", est_cost_usd: 5 },
    });
    expect(c.events().some((e) => e.type === "graph_edge" && e.edge.kind === "spawned")).toBe(true);
  });

  it("leaves a pending question unrun when nobody rules on it, and still synthesizes", async () => {
    const c = collector();
    await runRun({ ...oneAngle, spawnMode: "ask" }, {}, {
      sink: c.sink, sessionId: "qrun-unruled", runTopic: spawningTopic({
        a1: { question: "What did the 2024 filing say?", why: "hit a paywall" },
      }),
    });
    const events = c.events();

    expect(events.some((e) => e.type === "graph_node_update" && e.status === "expired")).toBe(true);
    expect(events.at(-1)).toMatchObject({ type: "run_result", status: "complete" });
    expect(events.at(-1).topics.filter((t: TopicOutcome) => t.role === "research")).toHaveLength(1);
  });

  it("runs an approved question as a real inquiry whose findings reach the synthesis", async () => {
    const c = collector();
    await runRun({ ...oneAngle, spawnMode: "ask" }, {}, {
      sink: c.sink, sessionId: "qrun-approved",
      runTopic: spawningTopic({ a1: { question: "What did the 2024 filing say?", why: "hit a paywall" } }),
      approvals: approvalsFor([{ id: "x1", verdict: "approved" }]),
    });
    const events = c.events();
    const research = events.at(-1).topics.filter((t: TopicOutcome) => t.role === "research");

    expect(research.map((t: TopicOutcome) => t.angle_id)).toEqual(["a1", "x1"]);
    expect(events.some((e) => e.type === "graph_node_update" && e.status === "approved")).toBe(true);
    const synthesis = events.at(-1).topics.find((t: TopicOutcome) => t.role === "synthesis");
    expect(synthesis).toBeTruthy();
  });

  it("charges a spawned child a smaller ceiling than the angle that raised it", async () => {
    const ceilings: Record<string, number> = {};
    const c = collector();
    await runRun({ ...oneAngle, spawnMode: "ask" }, {}, {
      sink: c.sink, sessionId: "qrun-ceiling",
      runTopic: async (cfg) => {
        ceilings[cfg.angleId] = cfg.perTopicBudgetUsd;
        if (cfg.angleId === "a1" && cfg.spawn) {
          cfg.spawn({ question: "What did the filing say?", why: "paywall", provoked_by: "s1" });
        }
        return mockTopic()(cfg);
      },
      approvals: approvalsFor([{ id: "x1", verdict: "approved" }]),
    });

    expect(ceilings.x1).toBeLessThan(ceilings.a1!);
  });

  it("draws a refused question with its reason rather than swallowing it", async () => {
    const c = collector();
    await runRun({ ...oneAngle, spawnMode: "auto" }, {}, {
      sink: c.sink, sessionId: "qrun-refused",
      runTopic: async (cfg) => {
        if (cfg.spawn) {
          cfg.spawn({ question: "Which regulator approved the tariff?", why: "paywall", provoked_by: "s1" });
          cfg.spawn({ question: "Which regulator approved the tariff?", why: "again", provoked_by: "s1" });
        }
        return mockTopic()(cfg);
      },
    });
    const refused = c.events().find((e) => e.type === "graph_node" && e.node.status === "rejected");

    expect(refused.node.title).toBe("Which regulator approved the tariff?");
    expect(refused.node.meta.rejected_reason).toMatch(/duplicate/i);
  });

  it("never offers the tool when spawning is off", async () => {
    let sawTool = false;
    const c = collector();
    await runRun({ ...oneAngle, spawnMode: "off" }, {}, {
      sink: c.sink, sessionId: "qrun-off",
      runTopic: async (cfg) => {
        sawTool = sawTool || Boolean(cfg.spawn);
        return mockTopic()(cfg);
      },
    });

    expect(sawTool).toBe(false);
  });

  it("approves without a human when the run is in auto mode", async () => {
    const c = collector();
    await runRun({ ...oneAngle, spawnMode: "auto" }, {}, {
      sink: c.sink, sessionId: "qrun-auto",
      runTopic: spawningTopic({ a1: { question: "What did the 2024 filing say?", why: "paywall" } }),
    });
    const research = c.events().at(-1).topics.filter((t: TopicOutcome) => t.role === "research");

    expect(research.map((t: TopicOutcome) => t.angle_id)).toEqual(["a1", "x1"]);
  });

  it("stops the chain at the depth limit instead of digging forever", async () => {
    const distinct: Record<string, string> = {
      a1: "Which regulator approved the tariff schedule?",
      x1: "How did copper smelting margins move afterwards?",
      x2: "What replacement alloys did shipbuilders qualify?",
    };
    const c = collector();
    await runRun({ ...oneAngle, spawnMode: "auto" }, {}, {
      sink: c.sink, sessionId: "qrun-depth",
      runTopic: async (cfg) => {
        const question = distinct[cfg.angleId];
        if (cfg.spawn && question) cfg.spawn({ question, why: "deeper", provoked_by: "s1" });
        return mockTopic()(cfg);
      },
    });
    const research = c.events().at(-1).topics.filter((t: TopicOutcome) => t.role === "research");

    expect(research.map((t: TopicOutcome) => t.angle_id)).toEqual(["a1", "x1", "x2"]);
  });
});

const SNAPSHOT = "Cold starts fell 40% year over year in tested clusters, the authors report.";
const QUOTE = "fell 40% year over year";

function citedResult(angleId: string, citations: unknown[], findings: unknown[], marker = "[^c1]"): string {
  const summary: Record<string, unknown> = {
    headline: `Finding for ${angleId}`, status: "complete", sourcesConsulted: 1, citations, findings,
  };
  if (angleId === "synthesis") { summary.conflicts = []; summary.gaps = []; }
  return `Body for ${angleId}.${marker}\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\``;
}

function outcomeOf(cfg: RunTopicConfig, result: string, cost = 0.01): TopicOutcome {
  return {
    angle_id: cfg.angleId, role: cfg.role, backend: "engine", provider: "deepseek",
    model: "deepseek-chat", session_id: `qeng-${cfg.angleId}`, status: "complete",
    result, usage: usage(cost), note: null,
  };
}

/// Every topic captures one document and cites a verbatim span of it, the way a real angle does through
/// web_fetch. `sharedUrl` makes two angles land on the same page, to exercise run-wide dedupe.
function citingTopic(options: { sharedUrl?: string } = {}): (cfg: RunTopicConfig) => Promise<TopicOutcome> {
  return async (cfg) => {
    const url = options.sharedUrl ?? `https://ex.test/${cfg.angleId}`;
    const document = cfg.evidence!.register({ url, title: `Doc ${cfg.angleId}`, contentType: "html", text: SNAPSHOT });
    cfg.emitter.document(document);
    cfg.emitter.textDelta(`Researching ${cfg.angleId}. `);
    cfg.emitter.usage(0.01, usage(0.01));
    if (cfg.role === "synthesis") {
      const traceable = options.sharedUrl ?? "https://ex.test/a1";   // a url an angle cited → no verify pass
      return outcomeOf(cfg, citedResult("synthesis",
        [{ id: "a1c1", source: document.source_id, quote: QUOTE }],
        [{ claim: "synthesized claim", sources: [traceable], citations: ["a1c1"], confidence: "high" }], "[^a1c1]"));
    }
    return outcomeOf(cfg, citedResult(cfg.angleId,
      [{ id: "c1", source: document.source_id, quote: QUOTE }],
      [{ claim: `claim ${cfg.angleId}`, sources: [url], citations: ["c1"], confidence: "high" }]));
  };
}

describe("run evidence grounding", () => {
  it("prefixes each angle's citation ids globally and rewrites its markers to match", async () => {
    const c = collector();
    await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-ev-ids", now: () => 0, runTopic: citingTopic() });
    const angles = c.events().filter((e) => e.type === "topic_result" && e.role === "research");

    expect(angles.map((a) => a.citations.map((x: any) => x.id))).toEqual([["a1c1"], ["a2c1"]]);
    expect(angles[0].result).toContain("[^a1c1]");
    expect(angles[0].result).not.toContain("[^c1]");
    expect(angles[1].result).toContain("[^a2c1]");
    for (const angle of angles) {
      const summary = JSON.parse(angle.result.split("```json")[1].split("```")[0]);
      expect(summary.citations[0].id).toBe(`${angle.angle_id}c1`);
      expect(summary.findings[0].citations).toEqual([`${angle.angle_id}c1`]);
    }
  });

  it("resolves each citation against the snapshot the angle actually captured", async () => {
    const c = collector();
    await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-ev-resolve", now: () => 0, runTopic: citingTopic() });
    const angle = c.events().find((e) => e.type === "topic_result");
    const citation = angle.citations[0];
    expect(citation.match).toBe("exact");
    expect(citation.quote).toBe(QUOTE);
    expect(SNAPSHOT.slice(citation.start, citation.end)).toBe(QUOTE);
    expect(citation.source_id).toBe(c.events().find((e) => e.type === "document").document.source_id);
  });

  it("reports one deduped run-wide document registry on run_result", async () => {
    const c = collector();
    await runRun(twoAngles, {}, {
      sink: c.sink, sessionId: "qrun-ev-dedupe", now: () => 0,
      runTopic: citingTopic({ sharedUrl: "https://shared.example/paper" }),
    });
    const runResult = c.events().at(-1);
    expect(runResult.documents).toHaveLength(1);
    expect(runResult.documents[0]).toMatchObject({
      url: "https://shared.example/paper",
      content_type: "html",
      text_length: SNAPSHOT.length,
      page_offsets: [],
    });
  });

  it("hands the synthesis each angle's resolved quotes under their global ids", async () => {
    const c = collector();
    let synthesisPrompt = "";
    const spy = async (cfg: RunTopicConfig) => {
      if (cfg.role === "synthesis") synthesisPrompt = cfg.prompt;
      return citingTopic()(cfg);
    };
    await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-ev-context", now: () => 0, runTopic: spy });
    expect(synthesisPrompt).toContain("a1c1");
    expect(synthesisPrompt).toContain("a2c1");
    expect(synthesisPrompt).toContain(QUOTE);
    expect(synthesisPrompt).toMatch(/reuse/i);
  });

  it("keeps a reused angle citation verified without re-resolving it", async () => {
    const c = collector();
    await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-ev-reuse", now: () => 0, runTopic: citingTopic() });
    const synthesis = c.events().filter((e) => e.type === "topic_result").find((e) => e.role === "synthesis");
    expect(synthesis.citations).toHaveLength(1);
    expect(synthesis.citations[0]).toMatchObject({ id: "a1c1", match: "exact", quote: QUOTE });
  });

  it("floors a finding with no resolvable quote to unverified without dropping the claim, and asks no model", async () => {
    const c = collector();
    const roles: string[] = [];
    const fabricatingSynthesis = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      roles.push(cfg.role);
      const url = `https://ex.test/${cfg.angleId}`;
      const document = cfg.evidence!.register({ url, title: "Doc", contentType: "html", text: SNAPSHOT });
      if (cfg.role !== "synthesis") {
        return outcomeOf(cfg, citedResult(cfg.angleId,
          [{ id: "c1", source: document.source_id, quote: QUOTE }],
          [{ claim: `claim ${cfg.angleId}`, sources: [url], citations: ["c1"], confidence: "high" }]));
      }
      return outcomeOf(cfg, citedResult("synthesis",
        [{ id: "c1", source: document.source_id, quote: "cold starts were eliminated outright everywhere" }],
        [
          { claim: "invented detail", sources: ["https://ex.test/a1"], citations: ["c1"], confidence: "high" },
          { claim: "cited nothing at all", sources: ["https://ex.test/a2"], confidence: "high" },
        ], "[^c1]"));
    };
    await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-ev-floor", now: () => 0, runTopic: fabricatingSynthesis });

    expect(roles).not.toContain("verify");   // the urls trace; only the quotes failed, and that needs no model
    const synthesis = c.events().filter((e) => e.type === "topic_result").find((e) => e.role === "synthesis");
    expect(synthesis.citations[0].match).toBe("unresolved");
    expect(synthesis.citations[0].start).toBeUndefined();
    const summary = JSON.parse(synthesis.result.split("```json")[1].split("```")[0]);
    expect(summary.findings.map((f: any) => f.claim)).toEqual(["invented detail", "cited nothing at all"]);
    expect(summary.findings.map((f: any) => f.confidence)).toEqual(["unverified", "unverified"]);
  });

  it("leaves confidence alone when the run captured no snapshots to check against", async () => {
    const c = collector();
    await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-ev-nocapture", runTopic: mockTopic() });
    const results = c.events().filter((e) => e.type === "topic_result");
    for (const topic of results) {
      const summary = JSON.parse(topic.result.split("```json")[1].split("```")[0]);
      expect(summary.findings[0].confidence).toBe("high");
      expect(topic.citations).toEqual([]);
    }
    expect(c.events().at(-1).documents).toEqual([]);
  });

  it("appends a portable Sources section with badges and footnote definitions to the synthesis", async () => {
    const c = collector();
    await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-ev-sources", now: () => 0, runTopic: citingTopic() });
    const synthesis = c.events().filter((e) => e.type === "topic_result").find((e) => e.role === "synthesis");
    expect(synthesis.result).toContain("## Sources");
    expect(synthesis.result).toContain("[Doc a1](https://ex.test/a1)");
    expect(synthesis.result).toContain("verified");
    expect(synthesis.result).toContain(`[^a1c1]: [Doc a1](https://ex.test/a1) — “${QUOTE}”`);
    expect(synthesis.result.indexOf("## Sources")).toBeLessThan(synthesis.result.indexOf("```json"));
  });

  it("marks an unverifiable quote plainly in the Sources section instead of implying a check", async () => {
    const c = collector();
    const unverifiable = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      const url = `https://ex.test/${cfg.angleId}`;
      const document = cfg.evidence!.register({ url, title: "Doc", contentType: "html", text: SNAPSHOT });
      const quote = cfg.role === "synthesis" ? "words that appear in no snapshot anywhere" : QUOTE;
      return outcomeOf(cfg, citedResult(cfg.role === "synthesis" ? "synthesis" : cfg.angleId,
        [{ id: "c1", source: document.source_id, quote }],
        [{ claim: "a claim", sources: [url], citations: ["c1"], confidence: "high" }]));
    };
    await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-ev-unverifiable", now: () => 0, runTopic: unverifiable });
    const synthesis = c.events().filter((e) => e.type === "topic_result").find((e) => e.role === "synthesis");
    expect(synthesis.result).toContain("not verifiable");
    expect(synthesis.result).toContain("quote not verifiable against a stored snapshot");
  });

  it("picks up what a claude-code angle's mcp-serve subprocess captured on disk", async () => {
    const dir = mkdtempSync(join(tmpdir(), "quorum-run-evidence-"));
    const c = collector();
    const cliTopic = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      expect(cfg.evidenceDir).toBe(dir);
      // a separate process wrote these — the angle's own in-memory store never sees them
      const subprocess = new EvidenceStore({ dir, now: () => 0 });
      const document = subprocess.register({
        url: `https://cli.example/${cfg.angleId}`, title: "CLI capture", contentType: "html", text: SNAPSHOT,
      });
      return {
        ...outcomeOf(cfg, citedResult(cfg.role === "synthesis" ? "synthesis" : cfg.angleId,
          [{ id: "c1", source: document.source_id, quote: QUOTE }],
          [{ claim: "cli claim", sources: [`https://cli.example/${cfg.angleId}`], citations: ["c1"], confidence: "high" }])),
        backend: "cli", provider: "claude-code", model: "claude-code", session_id: "real-cli-1",
      };
    };
    await runRun({ ...twoAngles, evidenceDir: dir, angleModel: "claude-code", synthesisModel: "claude-code" }, {}, {
      sink: c.sink, sessionId: "qrun-ev-cli", now: () => 0, runTopic: cliTopic,
    });

    const events = c.events();
    const angles = events.filter((e) => e.type === "topic_result" && e.role === "research");
    expect(angles.map((a) => a.citations[0].match)).toEqual(["exact", "exact"]);
    expect(angles[0].citations[0].id).toBe("a1c1");
    expect(events.at(-1).documents.map((d: any) => d.url).sort()).toEqual([
      "https://cli.example/a1", "https://cli.example/a2", "https://cli.example/synthesis",
    ]);
    const announced = events.filter((e) => e.type === "document");
    expect(announced.map((e) => e.document.url).sort()).toEqual([
      "https://cli.example/a1", "https://cli.example/a2", "https://cli.example/synthesis",
    ]);
    expect(announced.every((e) => typeof e.angle_id === "string")).toBe(true);
    expect(events.at(-1).documents[0].snapshot_path).toMatch(/^sources\/s[0-9a-f]+\.md$/);
  });

  it("picks up what a codex angle's mcp-serve subprocess captured on disk", async () => {
    const dir = mkdtempSync(join(tmpdir(), "quorum-run-evidence-"));
    const c = collector();
    const codexTopic = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      const subprocess = new EvidenceStore({ dir, now: () => 0 });
      const document = subprocess.register({
        url: `https://codex.example/${cfg.angleId}`, title: "Codex capture", contentType: "html", text: SNAPSHOT,
      });
      return {
        ...outcomeOf(cfg, citedResult(cfg.role === "synthesis" ? "synthesis" : cfg.angleId,
          [{ id: "c1", source: document.source_id, quote: QUOTE }],
          [{ claim: "codex claim", sources: [`https://codex.example/${cfg.angleId}`], citations: ["c1"], confidence: "high" }])),
        backend: "codex", provider: "codex", model: "gpt-5.6-terra", session_id: "019fe6d6",
      };
    };
    await runRun({ ...twoAngles, evidenceDir: dir, angleModel: "codex/terra", synthesisModel: "codex/terra" }, {}, {
      sink: c.sink, sessionId: "qrun-ev-codex", now: () => 0, runTopic: codexTopic,
    });

    const events = c.events();
    const angles = events.filter((e) => e.type === "topic_result" && e.role === "research");
    expect(angles.map((a) => a.citations[0].match)).toEqual(["exact", "exact"]);
    expect(events.filter((e) => e.type === "document").map((e) => e.document.url).sort()).toEqual([
      "https://codex.example/a1", "https://codex.example/a2", "https://codex.example/synthesis",
    ]);
  });

  it("blames codex, not the BYOK engine, when a codex angle throws", async () => {
    const c = collector();
    await runRun({ ...twoAngles, angleModel: "codex/luna", synthesisModel: "codex/luna" }, {}, {
      sink: c.sink, sessionId: "qrun-codex-throw", now: () => 0,
      runTopic: async () => { throw new Error("codex CLI not found"); },
    });
    const angles = c.events().filter((e) => e.type === "topic_result" && e.role === "research");
    expect(angles[0].backend).toBe("codex");
    expect(angles[0].provider).toBe("codex");
    expect(angles[0].usage.provider).toBe("codex");
  });

  it("falls back to the evidence directory in the environment when the config carries none", async () => {
    const dir = mkdtempSync(join(tmpdir(), "quorum-run-evidence-"));
    const c = collector();
    await runRun(twoAngles, { QUORUM_EVIDENCE_DIR: dir }, {
      sink: c.sink, sessionId: "qrun-ev-env", now: () => 0, runTopic: citingTopic(),
    });
    expect(EvidenceStore.load(dir).all().length).toBeGreaterThan(0);
  });

  it("scopes each angle's store to the shared evidence directory", async () => {
    const dir = mkdtempSync(join(tmpdir(), "quorum-run-evidence-"));
    const c = collector();
    const seen: Array<string | undefined> = [];
    await runRun({ ...twoAngles, evidenceDir: dir }, {}, {
      sink: c.sink, sessionId: "qrun-ev-dir", now: () => 0,
      runTopic: async (cfg) => {
        seen.push(cfg.evidenceDir);
        return citingTopic()(cfg);
      },
    });
    expect(seen).toEqual([dir, dir, dir]);
    const onDisk = EvidenceStore.load(dir);
    expect(onDisk.all().map((d) => d.url).sort()).toEqual([
      "https://ex.test/a1", "https://ex.test/a2", "https://ex.test/synthesis",
    ]);
    expect(onDisk.resolveCitation({ id: "c1", source: onDisk.all()[0]!.source_id, quote: QUOTE }).match).toBe("exact");
  });
});

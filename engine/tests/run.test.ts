import { describe, it, expect } from "vitest";
import { answerLanguage } from "../src/systemPrompt.js";
import { writeFileSync, mkdirSync, mkdtempSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MockLanguageModelV4, convertArrayToReadableStream } from "ai/test";
import { runRun, type RunConfig, type RunDeps } from "../src/run.js";
import { ControlQueue } from "../src/approvals.js";
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

  /// The app draws the plan before the engine ever sees it, and the reader edits it there. If the engine
  /// renames those angles, its graph is a second graph of the same run: the cards someone approved vanish
  /// and identical ones appear under new ids. So an angle that arrives with an id keeps it.
  it("keeps the id an approved angle already had, and only numbers the ones with none", async () => {
    const c = collector();
    await runRun(
      { ...twoAngles,
        angles: [
          { id: "plan-cost", title: "Cost", prompt: "compare pricing" },
          { title: "Latency", prompt: "compare regions" },
        ] },
      {},
      { sink: c.sink, sessionId: "qrun-plan-ids", runTopic: mockTopic(),
        planAngles: () => { throw new Error("planner must not run when angles are pre-approved"); } });
    const ev = c.events();

    expect(ev.find((e) => e.type === "plan").angles.map((a: { angle_id: string }) => a.angle_id))
      .toEqual(["plan-cost", "a1"]);
    const inquiries = ev.filter((e) => e.type === "graph_node" && e.node.kind === "inquiry");
    expect(inquiries.map((e) => e.node.id)).toEqual(["plan-cost", "a1"]);
    expect(ev.filter((e) => e.type === "graph_edge" && e.edge.kind === "decomposes")
             .map((e) => e.edge.to)).toEqual(["plan-cost", "a1"]);
    expect(ev.at(-1).topics.filter((t: TopicOutcome) => t.role === "research")
             .map((t: TopicOutcome) => t.angle_id)).toEqual(["plan-cost", "a1"]);
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

  it("tells every research angle the language of the user's question, whatever language its prompt is in", async () => {
    const c = collector();
    const seen: Array<{ role: string; systemPrompt: string }> = [];
    const spyTopic = async (cfg: RunTopicConfig) => {
      seen.push({ role: cfg.role, systemPrompt: cfg.systemPrompt });
      return mockTopic()(cfg);
    };
    const question = "Zrób reaserch systemów personalizacji w food tech";
    await runRun({ ...twoAngles, question }, {}, { sink: c.sink, sessionId: "qrun-lang", runTopic: spyTopic });
    const research = seen.filter((s) => s.role === "research");
    expect(research.length).toBeGreaterThan(0);
    for (const r of research) expect(r.systemPrompt).toContain(answerLanguage(question));
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
    expect(synthesis?.prompt).toContain("Writeup from angle 1, in full");
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
    expect(runResult.validation.spend_usd, "three critics, no sweep on an uncaptured run").toBeCloseTo(0.03, 5);
    expect(runResult.total_cost_usd).toBeCloseTo(0.02 + 0.01 + 0.001 + runResult.validation.spend_usd, 5);
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
    await runRun(twoAngles, { QUORUM_TAVILY_KEY: "fixture" }, {
      sink: c.sink, sessionId: "qrun-fixture", now: () => 0, runTopic: citingTopic(),
    });
    const lines = c.events();
    for (const e of lines) expect(typeof e.type).toBe("string");   // every line valid JSON with a type
    const dir = join(import.meta.dirname, "..", "fixtures");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "run-transcript.ndjson"), lines.map((e) => JSON.stringify(e)).join("\n") + "\n");
    expect(lines[0].type).toBe("run_start");
    expect(lines[0].protocol_version).toBe(4);
    expect(lines[0].grounding).toBe("captured");   // the fixture is a run that DID capture; it cites snapshots
    expect(lines.at(-1).grounding).toBe("captured");
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
      controls: approvalsFor([{ id: "x1", verdict: "approved" }]),
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
      controls: approvalsFor([{ id: "x1", verdict: "approved" }]),
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

/// R5 — a verdict the run waits for is a verdict the run pays for. Approving a spawn stays the user's call,
/// but it happens beside the wave: pending offers sit outside the frontier, an approval joins the wave that
/// is running, and nothing anyone forgot to answer holds the run open.
describe("approvals that never hold the wave", () => {
  const blindPair: RunConfig = { ...twoAngles, runBudgetUSD: 40, perTopicBudgetUSD: 10 };
  const paywalled = { question: "What did the 2024 filing say about renewals?", why: "hit a paywall",
                      provoked_by: "s3f9a1c2" };

  function spawnsThen(extra: (cfg: RunTopicConfig) => void | Promise<void>) {
    return async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      if (cfg.angleId === "a1" && cfg.spawn) cfg.spawn(paywalled);
      await extra(cfg);
      return mockTopic()(cfg);
    };
  }

  function offeredQuestionId(events: any[]): string {
    return events.find((e) => e.type === "graph_node" && e.node.status === "pending").node.id;
  }

  it("finishes its wave on a clock that never moves and a verdict that never comes", async () => {
    const c = collector();
    let takes = 0;
    await runRun({ ...blindPair, spawnMode: "ask" }, {}, {
      sink: c.sink, sessionId: "qrun-nonblocking", now: () => 0,
      runTopic: spawnsThen(() => {}),
      controls: { take: async () => { takes += 1; return undefined; } },
    });
    const events = c.events();
    const research = events.at(-1).topics.filter((t: TopicOutcome) => t.role === "research");

    expect(events.some((e) => e.type === "phase" && e.phase === "awaiting_approval")).toBe(false);
    expect(takes, "the run reads what arrived; it never sits on the pipe").toBeLessThan(8);
    expect(research.map((t: TopicOutcome) => t.angle_id)).toEqual(["a1", "a2"]);
    expect(events.at(-1)).toMatchObject({ type: "run_result", status: "complete" });
  });

  it("leaves an unanswered offer live past the wave and expires it only when the run is over", async () => {
    const c = collector();
    await runRun({ ...blindPair, spawnMode: "ask" }, {}, {
      sink: c.sink, sessionId: "qrun-offer-outlives-wave", now: () => 0,
      runTopic: spawnsThen(() => {}),
      controls: { take: async () => undefined },
    });
    const events = c.events();
    const expiredAt = events.findIndex((e) => e.type === "graph_node_update" && e.status === "expired");
    const synthesizingAt = events.findIndex((e) => e.type === "phase" && e.phase === "synthesizing");

    expect(expiredAt).toBeGreaterThan(synthesizingAt);
  });

  it("admits an approval into the wave already running rather than into one that waited", async () => {
    const c = collector();
    const queue = new ControlQueue();
    let secondAngleRunning = false;
    let joinedTheRunningWave = false;
    let releaseSecondAngle: () => void = () => {};
    const secondAngleHeld = new Promise<void>((resolve) => { releaseSecondAngle = resolve; });

    await runRun({ ...blindPair, spawnMode: "ask" }, {}, {
      sink: c.sink, sessionId: "qrun-midwave", controls: queue,
      runTopic: async (cfg) => {
        if (cfg.angleId === "a1" && cfg.spawn) {
          const verdict = cfg.spawn(paywalled);
          queue.push({ id: verdict.inquiry_id!, verdict: "approved" });
        }
        if (cfg.angleId === "a2") {
          secondAngleRunning = true;
          await secondAngleHeld;
          secondAngleRunning = false;
        }
        if (cfg.angleId === "x1") {
          joinedTheRunningWave = secondAngleRunning;
          releaseSecondAngle();
        }
        return mockTopic()(cfg);
      },
    });
    const research = c.events().at(-1).topics.filter((t: TopicOutcome) => t.role === "research");

    expect(joinedTheRunningWave, "the approved question runs beside the angles still working").toBe(true);
    expect(research.map((t: TopicOutcome) => t.angle_id)).toContain("x1");
  });

  it("admits the offer approved under the id the canvas draws it by, which is all the user can click", async () => {
    const c = collector();
    const queue = new ControlQueue();

    await runRun({ ...blindPair, spawnMode: "ask" }, {}, {
      sink: c.sink, sessionId: "qrun-canvas-approval", now: () => 0,
      runTopic: spawnsThen(async (cfg) => {
        if (cfg.angleId === "a1") queue.push({ id: offeredQuestionId(c.events()), verdict: "approved" });
      }),
      controls: queue,
    });
    const events = c.events();
    const research = events.at(-1).topics.filter((t: TopicOutcome) => t.role === "research");

    expect(research.map((t: TopicOutcome) => t.angle_id)).toContain("x1");
    expect(events.some((e) => e.type === "graph_node_update"
                           && e.id === offeredQuestionId(events) && e.status === "approved")).toBe(true);
  });

  it("draws the question the user turned down under that same id, so the canvas stops offering it", async () => {
    const c = collector();
    const queue = new ControlQueue();

    await runRun({ ...blindPair, spawnMode: "ask" }, {}, {
      sink: c.sink, sessionId: "qrun-canvas-rejection", now: () => 0,
      runTopic: spawnsThen(async (cfg) => {
        if (cfg.angleId === "a1") queue.push({ id: offeredQuestionId(c.events()), verdict: "rejected" });
      }),
      controls: queue,
    });
    const events = c.events();
    const research = events.at(-1).topics.filter((t: TopicOutcome) => t.role === "research");
    const turnedDown = events.filter((e) => e.type === "graph_node_update" && e.status === "rejected");

    expect(turnedDown.map((e) => e.id)).toEqual([offeredQuestionId(events)]);
    expect(research.map((t: TopicOutcome) => t.angle_id)).not.toContain("x1");
    expect(events.some((e) => e.type === "graph_node_update" && e.status === "expired")).toBe(false);
  });

  it("expires an offer nobody took inside the approval window, before the answer is drafted", async () => {
    const c = collector();
    let clock = 0;
    await runRun({ ...blindPair, spawnMode: "ask", angleConcurrency: 1, approvalWindowSec: 30 }, {}, {
      sink: c.sink, sessionId: "qrun-approval-window", now: () => clock,
      runTopic: spawnsThen((cfg) => { if (cfg.angleId === "a2") clock += 31_000; }),
      controls: { take: async () => undefined },
    });
    const events = c.events();
    const expiredAt = events.findIndex((e) => e.type === "graph_node_update" && e.status === "expired");
    const synthesizingAt = events.findIndex((e) => e.type === "phase" && e.phase === "synthesizing");

    expect(expiredAt).toBeGreaterThan(-1);
    expect(expiredAt).toBeLessThan(synthesizingAt);
  });

  it("takes up nothing past the spawn freeze the run deadline makes real", async () => {
    const c = collector();
    let clock = 0;
    await runRun({ ...blindPair, spawnMode: "ask", angleConcurrency: 1, runDeadlineSec: 100 }, {}, {
      sink: c.sink, sessionId: "qrun-freeze", now: () => clock,
      runTopic: async (cfg) => {
        if (cfg.angleId === "a1" && cfg.spawn) {
          cfg.spawn(paywalled);
          clock += 71_000;
        }
        if (cfg.angleId === "a2" && cfg.spawn) {
          cfg.spawn({ question: "Which regulator signed off on the tariff?", why: "gap", provoked_by: "s7" });
        }
        return mockTopic()(cfg);
      },
      controls: { take: async () => undefined },
    });
    const events = c.events();
    const refused = events.find((e) => e.type === "graph_node" && e.node.status === "rejected");
    const research = events.at(-1).topics.filter((t: TopicOutcome) => t.role === "research");

    expect(refused.node.meta.rejected_reason).toMatch(/freeze/i);
    expect(events.some((e) => e.type === "graph_node_update" && e.status === "expired")).toBe(true);
    expect(research.map((t: TopicOutcome) => t.angle_id)).toEqual(["a1", "a2"]);
  });
});

const SNAPSHOT ="Cold starts fell 40% year over year in tested clusters, the authors report.";
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
    if (cfg.role === "validate") {
      const judged = cfg.angleId.startsWith("claim_sweep")
        ? { verdicts: [{ claim: 1, verdict: "supported" }] }
        : { objections: [] };
      return outcomeOf(cfg, "Judged.\n\n```json\n" + JSON.stringify(judged) + "\n```");
    }
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

describe("claim sweep when the synthesis summary cannot be read", () => {
  it("still checks the answer's footnoted claims against the citations its angles located", async () => {
    const brokenSynthesis = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      if (cfg.role !== "synthesis") return citingTopic()(cfg);
      return outcomeOf(cfg, "Cold starts fell sharply in tested clusters.[^a1c1]\n\n```json\n{\"headline\": \"unterminated \"quote\" here\n```");
    };
    const c = collector();
    await runRun(twoAngles, { QUORUM_TAVILY_KEY: "tk" }, {
      sink: c.sink, sessionId: "qrun-sweep-fallback", now: () => 0, runTopic: brokenSynthesis,
    });
    const result = c.events().at(-1);
    expect(result.validation.rounds[0]).toMatchObject({ sweep: "run", claims_found: 1, claims_checked: 1 });
  });
});

describe("declared grounding tiers", () => {
  it("declares a keyless run unvalidated, on the first line and on the last", async () => {
    const c = collector();
    await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-grounding-none", runTopic: mockTopic() });
    const events = c.events();
    expect(events[0]).toMatchObject({ type: "run_start", grounding: "none" });
    expect(events.at(-1)).toMatchObject({ type: "run_result", grounding: "none" });
  });

  it("declares a run with a search key captured, since its fetches leave snapshots behind", async () => {
    for (const env of [{ QUORUM_TAVILY_KEY: "tk" }, { QUORUM_BRAVE_KEY: "bk" }]) {
      const c = collector();
      await runRun(twoAngles, env, { sink: c.sink, sessionId: "qrun-grounding-captured", runTopic: mockTopic() });
      expect(c.events()[0]).toMatchObject({ type: "run_start", grounding: "captured" });
      expect(c.events().at(-1)).toMatchObject({ type: "run_result", grounding: "captured" });
    }
  });

  it("declares a keyless Claude subscription run captured, since its page reads go through the engine's own fetch", async () => {
    const c = collector();
    await runRun({ ...twoAngles, angleModel: "claude-code/claude-haiku-4-5", synthesisModel: "claude-code/claude-haiku-4-5" }, {}, {
      sink: c.sink, sessionId: "qrun-grounding-subscription", runTopic: mockTopic(),
    });
    expect(c.events()[0]).toMatchObject({ type: "run_start", grounding: "captured" });
    expect(c.events().at(-1)).toMatchObject({ type: "run_result", grounding: "captured" });
  });

  it("still declares a keyless Codex run unvalidated, because its built-in search leaves nothing behind", async () => {
    const c = collector();
    await runRun({ ...twoAngles, angleModel: "codex/terra", synthesisModel: "codex/terra" }, {}, {
      sink: c.sink, sessionId: "qrun-grounding-codex", runTopic: mockTopic(),
    });
    expect(c.events()[0]).toMatchObject({ type: "run_start", grounding: "none" });
  });

  it("renders no verified badge in an unvalidated run, however well its quotes happen to line up", async () => {
    const c = collector();
    await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-grounding-badge", now: () => 0, runTopic: citingTopic() });
    const synthesis = c.events().filter((e) => e.type === "topic_result").find((e) => e.role === "synthesis");
    expect(synthesis.citations[0].match).toBe("exact");
    expect(synthesis.result).not.toContain("✓ verified");
    expect(synthesis.result).not.toContain("≈ close match");
    expect(synthesis.result).toContain("unvalidated — no evidence was captured");
  });

  it("badges a captured run's exact quote verified, as before", async () => {
    const c = collector();
    await runRun(twoAngles, { QUORUM_TAVILY_KEY: "tk" }, {
      sink: c.sink, sessionId: "qrun-grounding-ok", now: () => 0, runTopic: citingTopic(),
    });
    const synthesis = c.events().filter((e) => e.type === "topic_result").find((e) => e.role === "synthesis");
    expect(synthesis.result).toContain("✓ verified");
    expect(synthesis.result).not.toContain("unvalidated — no evidence was captured");
  });

  it("reports what the run could not keep alongside the documents it did", async () => {
    const dir = mkdtempSync(join(tmpdir(), "quorum-run-unwritable-"));
    chmodSync(dir, 0o500);
    try {
      const c = collector();
      await runRun({ ...twoAngles, evidenceDir: dir }, {}, {
        sink: c.sink, sessionId: "qrun-capture-failed", now: () => 0, runTopic: citingTopic(),
      });
      const announced = c.events().filter((e) => e.type === "document");
      expect(announced.every((e) => e.document.capture === "failed")).toBe(true);
      const failures = c.events().at(-1).capture_failures;
      expect(failures.length).toBeGreaterThan(0);
      expect(failures.every((f: any) => f.stage === "write")).toBe(true);
    } finally {
      chmodSync(dir, 0o700);
    }
  });
});

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
    await runRun(twoAngles, { QUORUM_TAVILY_KEY: "tk" }, {
      sink: c.sink, sessionId: "qrun-ev-sources", now: () => 0, runTopic: citingTopic(),
    });
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
    await runRun(twoAngles, { QUORUM_TAVILY_KEY: "tk" }, {
      sink: c.sink, sessionId: "qrun-ev-unverifiable", now: () => 0, runTopic: unverifiable,
    });
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

  it("announces each fetch a claude-code angle failed, once, with the url and why", async () => {
    const dir = mkdtempSync(join(tmpdir(), "quorum-run-evidence-"));
    const c = collector();
    const cliTopic = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      if (cfg.role === "research") {
        new EvidenceStore({ dir, now: () => 0 })
          .recordFetchFailure(`https://paywalled.example/${cfg.angleId}`, "paywall", "HTTP 402: requires payment");
      }
      return { ...outcomeOf(cfg, citedResult("synthesis", [], [])), backend: "cli", provider: "claude-code", model: "claude-code" };
    };
    await runRun({ ...twoAngles, evidenceDir: dir, angleModel: "claude-code", synthesisModel: "claude-code" }, {}, {
      sink: c.sink, sessionId: "qrun-ev-cli-failures", now: () => 0, runTopic: cliTopic,
    });

    const events = c.events();
    const announced = events.filter((e) => e.type === "capture_failure");
    expect(announced.map((e) => [e.failure.url, e.failure.kind]).sort()).toEqual([
      ["https://paywalled.example/a1", "paywall"],
      ["https://paywalled.example/a2", "paywall"],
    ]);
    expect(announced.every((e) => typeof e.angle_id === "string")).toBe(true);
    expect(events.at(-1).capture_failures.map((f: any) => f.stage)).toEqual(["fetch", "fetch"]);
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
    expect(seen.filter(Boolean), "only the roles that capture get the shared directory").toEqual([dir, dir, dir]);
    const onDisk = EvidenceStore.load(dir);
    expect(onDisk.all().map((d) => d.url).sort()).toEqual([
      "https://ex.test/a1", "https://ex.test/a2", "https://ex.test/synthesis",
    ]);
    expect(onDisk.resolveCitation({ id: "c1", source: onDisk.all()[0]!.source_id, quote: QUOTE }).match).toBe("exact");
  });
});

/// A pass that rewrites cited prose must carry the markers through it. When one comes back reworded, the
/// link is re-attached by matching the claim rather than dropped — and when nothing matches, the loss is
/// reported instead of being absorbed into a quiet confidence downgrade.
describe("marker-preserving rewrites", () => {
  const SYNTHESIZED_CLAIM = "Cold starts fell 40% year over year in tested clusters";

  function rewritingRun(corrected: unknown[]) {
    return async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      if (cfg.role === "verify") {
        return outcomeOf(cfg, `\`\`\`json\n${JSON.stringify({ findings: corrected })}\n\`\`\``, 0.001);
      }
      const url = `https://ex.test/${cfg.angleId}`;
      const document = cfg.evidence!.register({ url, title: `Doc ${cfg.angleId}`, contentType: "html", text: SNAPSHOT });
      if (cfg.role !== "synthesis") {
        return outcomeOf(cfg, citedResult(cfg.angleId,
          [{ id: "c1", source: document.source_id, quote: QUOTE }],
          [{ claim: `claim ${cfg.angleId}`, sources: [url], citations: ["c1"], confidence: "high" }]));
      }
      return outcomeOf(cfg, citedResult("synthesis",
        [{ id: "a1c1", source: document.source_id, quote: QUOTE }],
        [{ claim: SYNTHESIZED_CLAIM, sources: ["https://fabricated.example/nope"], citations: ["a1c1"],
           confidence: "high" }], "[^a1c1]"));
    };
  }

  async function rewriteWith(corrected: unknown[], sessionId: string) {
    const c = collector();
    await runRun(twoAngles, { QUORUM_TAVILY_KEY: "tk" }, {
      sink: c.sink, sessionId, now: () => 0, runTopic: rewritingRun(corrected),
    });
    const events = c.events();
    const synthesis = events.filter((e) => e.type === "topic_result").find((e) => e.role === "synthesis");
    return { events, synthesis, summary: JSON.parse(synthesis.result.split("```json")[1].split("```")[0]) };
  }

  it("hands the rewriting pass the markers each finding is standing on", async () => {
    const seen: string[] = [];
    const c = collector();
    await runRun(twoAngles, { QUORUM_TAVILY_KEY: "tk" }, {
      sink: c.sink, sessionId: "qrun-rewrite-context", now: () => 0,
      runTopic: async (cfg) => {
        if (cfg.role === "verify") seen.push(cfg.prompt);
        return rewritingRun([])(cfg);
      },
    });
    expect(seen[0]).toContain("a1c1");
  });

  it("re-attaches a reworded claim's marker instead of orphaning it", async () => {
    const { summary, events } = await rewriteWith(
      [{ claim: "Cold starts dropped 40% year on year across the tested clusters", sources: [], confidence: "medium" }],
      "qrun-rewrite-fuzzy");

    expect(summary.findings[0].citations).toEqual(["a1c1"]);
    expect(summary.findings[0].confidence).toBe("medium");
    expect(events.at(-1).citation_orphans).toEqual([]);
  });

  it("keeps the markers a compliant rewrite carried inline, without re-matching them", async () => {
    const { summary } = await rewriteWith(
      [{ claim: "A wholly restated claim about cluster cold starts", sources: [], citations: ["a1c1"], confidence: "low" }],
      "qrun-rewrite-carried");

    expect(summary.findings[0].citations).toEqual(["a1c1"]);
  });

  it("reports an orphaned marker rather than dropping it, so the validator loop can object", async () => {
    const { summary, events } = await rewriteWith(
      [{ claim: "Serverless adoption grew across European retail last quarter", sources: [], confidence: "high" }],
      "qrun-rewrite-orphan");

    expect(events.at(-1).citation_orphans).toEqual([
      { stage: "verify", claim: SYNTHESIZED_CLAIM, citation_ids: ["a1c1"] },
    ]);
    expect(summary.findings[0].citations).toBeUndefined();
    expect(summary.findings[0].confidence, "an orphan loses its evidence, so the claim stops claiming support")
      .toBe("unverified");
  });

  it("files the orphan as an objection, so a claim that lost its quote is researched again", async () => {
    const { events } = await rewriteWith(
      [{ claim: "Serverless adoption grew across European retail last quarter", sources: [], confidence: "high" }],
      "qrun-rewrite-objection");
    const objections = events.at(-1).validation.rounds[0].objections;

    expect(objections).toContainEqual(expect.objectContaining({
      lens: "claim_sweep", severity: "blocking", statement: expect.stringContaining(SYNTHESIZED_CLAIM),
    }));
  });
});

const DISTINCT_OBJECTIONS = [
  { statement: "the answer never states 2025 pricing", followup: "find Acme's 2025 published pricing page" },
  { statement: "no regulator decision is cited", followup: "locate the smelting tariff decision a regulator issued" },
  { statement: "churn is asserted without disclosure", followup: "obtain quarterly churn numbers from vendor filings" },
  { statement: "the queue is never quantified", followup: "read 2026 interconnection queue statistics" },
];
const PRICING_FOLLOWUP = DISTINCT_OBJECTIONS[0]!.followup;
/// Room for the loop to buy another round: the gate holds back a synthesis reserve the size of one angle,
/// so a run budget of exactly two angle ceilings can never admit a third question.
const loopBudget: RunConfig = { ...twoAngles, runBudgetUSD: 4 };
const tick = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

/// A run whose coverage critic keeps objecting. `objectingRounds` is how many rounds it files in, and
/// `distinctPerRound` decides whether it re-files the SAME objection (which must dedup) or a fresh one
/// each round (which must be admitted until a wall stops the loop).
function objectingRun(options: { objectingRounds: number; distinctPerRound?: boolean }) {
  const researched: string[] = [];
  let round = 0;
  const runTopic = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
    if (cfg.role === "validate") {
      const files = cfg.angleId === "critic_coverage" && round <= options.objectingRounds;
      const filed = DISTINCT_OBJECTIONS[
        options.distinctPerRound ? Math.min(round, DISTINCT_OBJECTIONS.length) - 1 : 0]!;
      return {
        ...(await mockTopic(0.001)(cfg)),
        result: "Judged.\n\n```json\n"
          + JSON.stringify({ objections: files ? [{ ...filed, severity: "blocking" }] : [] }) + "\n```",
      };
    }
    if (cfg.role === "synthesis") round += 1;
    else researched.push(cfg.angleId);
    return mockTopic()(cfg);
  };
  return { runTopic, researched };
}

/// R3/R4 — a validator never fixes the answer, so an objection it files has to become work: a question the
/// run admits itself, researches, and then re-judges the redrafted answer against.
describe("objections drive the loop", () => {
  it("turns a blocking objection into an origin:objection question that runs the next round", async () => {
    const c = collector();
    const f = objectingRun({ objectingRounds: 1 });
    await runRun({ ...loopBudget, rounds: 3 }, {}, {
      sink: c.sink, sessionId: "qrun-objection-loop", runTopic: f.runTopic,
    });
    const events = c.events();
    const question = events.find((e) => e.type === "graph_node" && e.node.origin === "objection");

    expect(question.node).toMatchObject({
      kind: "question", status: "approved", round: 1,
      meta: { lens: "coverage", statement: "the answer never states 2025 pricing" },
    });
    expect(question.node.title).toContain("Acme");
    expect(f.researched, "the objection is researched, never answered by the critic").toEqual(["a1", "a2", "x1"]);
    expect(events.filter((e) => e.type === "round").map((e) => e.round)).toEqual([2]);

    const validation = events.at(-1).validation;
    expect(validation.rounds).toHaveLength(2);
    expect(validation.holds, "the re-sweep passes once the objection was researched").toBe(true);
    expect(validation.objections_resolved).toBe(1);
    expect(validation.objections_outstanding).toEqual([]);
    expect(events.at(-1).status).toBe("complete");
  });

  it("hands the objection's research the task that would settle it, not the whole critique", async () => {
    const prompts: string[] = [];
    const c = collector();
    const f = objectingRun({ objectingRounds: 1 });
    await runRun({ ...loopBudget, rounds: 3 }, {}, {
      sink: c.sink, sessionId: "qrun-objection-prompt",
      runTopic: async (cfg) => {
        if (cfg.angleId === "x1") prompts.push(cfg.prompt);
        return f.runTopic(cfg);
      },
    });

    expect(prompts[0]).toContain(PRICING_FOLLOWUP);
    expect(prompts[0]).toContain("the answer never states 2025 pricing");
    expect(prompts[0]).toContain(twoAngles.question);
  });

  it("refuses a re-filed objection as a duplicate instead of letting it ping-pong the loop", async () => {
    const c = collector();
    const f = objectingRun({ objectingRounds: 4 });
    await runRun({ ...loopBudget, rounds: 4 }, {}, {
      sink: c.sink, sessionId: "qrun-objection-dedup", runTopic: f.runTopic,
    });
    const events = c.events();
    const refused = events.find((e) => e.type === "graph_node" && e.node.status === "rejected");

    expect(f.researched, "the same objection buys exactly one inquiry").toEqual(["a1", "a2", "x1"]);
    expect(refused.node.meta.rejected_reason).toMatch(/duplicate/i);
    expect(events.at(-1).validation.rounds).toHaveLength(2);
    expect(events.at(-1).validation.objections_outstanding).toHaveLength(1);
  });

  it("stops at the round cap with the standing objection recorded rather than dropped", async () => {
    const c = collector();
    const f = objectingRun({ objectingRounds: 9, distinctPerRound: true });
    await runRun({ ...loopBudget, rounds: 2 }, {}, {
      sink: c.sink, sessionId: "qrun-objection-roundcap", runTopic: f.runTopic,
    });
    const runResult = c.events().at(-1);

    expect(f.researched).toEqual(["a1", "a2", "x1"]);
    expect(runResult.validation.rounds).toHaveLength(2);
    expect(runResult.validation.holds).toBe(false);
    expect(runResult.validation.objections_outstanding).toEqual([
      expect.objectContaining({ lens: "coverage", severity: "blocking" }),
    ]);
    expect(runResult.status).toBe("inconclusive");
    expect(String(runResult.note)).toMatch(/round/i);
  });

  /// A synthesis that reports an open conflict is telling the run what it could not settle. Nothing used to
  /// read it: the loop only continued on a critic's blocking objection, so an answer could end round 1
  /// carrying "McKinsey says 1–2%, vendors say 30%" with a single lookup between it and an answer.
  function conflictedRun(conflicts: unknown[]) {
    const researched: string[] = [];
    let synthesized = 0;
    const runTopic = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      if (cfg.role === "validate") {
        return { ...(await mockTopic(0.001)(cfg)), result: "Judged.\n\n```json\n{\"objections\":[]}\n```" };
      }
      if (cfg.role !== "synthesis") { researched.push(cfg.angleId); return mockTopic()(cfg); }
      synthesized += 1;
      const base = await mockTopic()(cfg);
      const summary = {
        headline: "Answer", status: "complete", sourcesConsulted: 1, findings: [],
        conflicts: synthesized === 1 ? conflicts : [], gaps: [],
      };
      return { ...base, result: `Body.\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\`` };
    };
    return { runTopic, researched };
  }

  const GROCERY_CONFLICT = {
    claim: "How much does personalization lift grocery baskets?",
    positions: ["McKinsey: 1–2%", "Vendor case studies: 30%"],
  };

  it("sends research after a conflict the answer itself reported, instead of leaving it open", async () => {
    const c = collector();
    const f = conflictedRun([GROCERY_CONFLICT]);
    await runRun({ ...loopBudget, rounds: 3 }, {}, {
      sink: c.sink, sessionId: "qrun-conflict-loop", runTopic: f.runTopic,
    });
    const events = c.events();
    const question = events.find((e) => e.type === "graph_node" && e.node.origin === "objection");

    expect(question.node).toMatchObject({ kind: "question", status: "approved", meta: { lens: "conflicts" } });
    expect(question.node.meta.statement).toContain("McKinsey");
    expect(f.researched, "the conflict buys one targeted angle").toEqual(["a1", "a2", "x1"]);
    expect(events.filter((e) => e.type === "round").map((e) => e.round)).toEqual([2]);
  });

  it("does not call the answer unsound just because it was honest about a conflict", async () => {
    const c = collector();
    const f = conflictedRun([GROCERY_CONFLICT]);
    await runRun({ ...loopBudget, rounds: 3 }, {}, {
      sink: c.sink, sessionId: "qrun-conflict-holds", runTopic: f.runTopic,
    });
    const runResult = c.events().at(-1);

    expect(runResult.validation.holds, "a reported conflict is unfinished research, not a defect").toBe(true);
    expect(runResult.status).toBe("complete");
  });

  it("chases each open conflict once, not once per round", async () => {
    const c = collector();
    const f = conflictedRun([GROCERY_CONFLICT, GROCERY_CONFLICT]);
    await runRun({ ...loopBudget, rounds: 3 }, {}, {
      sink: c.sink, sessionId: "qrun-conflict-dedup", runTopic: f.runTopic,
    });
    expect(f.researched).toEqual(["a1", "a2", "x1"]);
  });

  it("stops the loop when the run budget cannot fund another round", async () => {
    const c = collector();
    const f = objectingRun({ objectingRounds: 9, distinctPerRound: true });
    await runRun({ ...twoAngles, rounds: 4, runBudgetUSD: 0.032 }, {}, {
      sink: c.sink, sessionId: "qrun-objection-budget", runTopic: f.runTopic,
    });
    const runResult = c.events().at(-1);

    expect(f.researched).toEqual(["a1", "a2"]);
    expect(runResult.validation.objections_outstanding).toHaveLength(1);
    expect(runResult.status).toBe("inconclusive");
    expect(String(runResult.note)).toMatch(/budget/i);
  });

  it("stops the loop at the run deadline, which is also what makes the spawn freeze real", async () => {
    const c = collector();
    const f = objectingRun({ objectingRounds: 9, distinctPerRound: true });
    let clock = 0;
    await runRun({ ...loopBudget, rounds: 4, runDeadlineSec: 60 }, {}, {
      sink: c.sink, sessionId: "qrun-objection-deadline",
      now: () => clock,
      runTopic: async (cfg) => {
        if (cfg.role === "synthesis") clock += 61_000;
        return f.runTopic(cfg);
      },
    });
    const runResult = c.events().at(-1);

    expect(f.researched).toEqual(["a1", "a2"]);
    expect(runResult.validation.objections_outstanding).toHaveLength(1);
    expect(String(runResult.note)).toMatch(/deadline/i);
  });
});

/// R8 — the structural honesty fixes the loop leans on.
describe("what the synthesis is given and what the run admits", () => {
  it("runs at most four angles at once, however many the frontier holds", async () => {
    const c = collector();
    let inFlight = 0;
    let peak = 0;
    await runRun(
      { ...twoAngles, angles: Array.from({ length: 7 }, (_, i) => ({ title: `A${i}`, prompt: `p${i}` })) },
      {},
      { sink: c.sink, sessionId: "qrun-concurrency",
        runTopic: async (cfg) => {
          if (cfg.role !== "research") return mockTopic()(cfg);
          inFlight += 1;
          peak = Math.max(peak, inFlight);
          await tick();
          inFlight -= 1;
          return mockTopic()(cfg);
        } });

    expect(peak).toBe(4);
    expect(c.events().at(-1).topics.filter((t: TopicOutcome) => t.role === "research")).toHaveLength(7);
  });

  it("never calls a run complete when an angle failed", async () => {
    const c = collector();
    await runRun(twoAngles, {}, {
      sink: c.sink, sessionId: "qrun-failed-angle",
      runTopic: async (cfg) => {
        if (cfg.angleId === "a2") throw new Error("backend exploded");
        return mockTopic()(cfg);
      },
    });
    const runResult = c.events().at(-1);

    expect(runResult.status).toBe("inconclusive");
    expect(String(runResult.note)).toMatch(/angle/i);
  });

  it("gives the synthesis every angle's findings first and never truncates the writeup under them", async () => {
    const body = "Long body sentence. ".repeat(200);
    let synthesisPrompt = "";
    const c = collector();
    await runRun(twoAngles, {}, {
      sink: c.sink, sessionId: "qrun-synthesis-context",
      runTopic: async (cfg) => {
        if (cfg.role === "synthesis") synthesisPrompt = cfg.prompt;
        const outcome = await mockTopic()(cfg);
        return cfg.role === "research"
          ? { ...outcome, result: body + "\n\n" + outcome.result.split("\n\n").slice(1).join("\n\n") }
          : outcome;
      },
    });

    expect(synthesisPrompt).toContain(body.trim());
    expect(synthesisPrompt).not.toContain("truncated");
    expect(synthesisPrompt.indexOf("Findings"))
      .toBeLessThan(synthesisPrompt.indexOf("Writeup"));
  });

  it("files an objection when an angle's fenced summary cannot be read, instead of skipping grounding silently", async () => {
    const c = collector();
    await runRun(twoAngles, {}, {
      sink: c.sink, sessionId: "qrun-unparsable",
      runTopic: async (cfg) => {
        const outcome = await mockTopic()(cfg);
        return cfg.angleId === "a2" ? { ...outcome, result: "Prose with no machine-readable summary." } : outcome;
      },
    });
    const objections = c.events().at(-1).validation.rounds[0].objections;

    expect(objections).toContainEqual(expect.objectContaining({
      lens: "structure", severity: "minor", statement: expect.stringContaining("a2"),
    }));
  });
});

const OVERTURNED = "OVERTURNEDCLAIM — round one read the pilot plant as arriving in 2030.";
const CORRECTION = "Round two found the schedule slipped.";
const CURRENT_ANSWER = "CURRENTANSWER — the first pilot plant is now scheduled for 2035.";

function fenced(summary: Record<string, unknown>): string {
  return "\n\n```json\n" + JSON.stringify({
    headline: "Round", status: "complete", sourcesConsulted: 2, conflicts: [], gaps: [], ...summary,
  }) + "\n```";
}

/// A dive that actually moved: round 1 reports a conflict and draws a blocking objection, round 2
/// corrects the claim and holds, so the two rounds leave two contradictory answers behind them.
function divergingRun(options: { fuse?: string; synthesisCost?: number } = {}) {
  const prompts = new Map<string, string>();
  let synthCalls = 0;
  const runTopic = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
    prompts.set(cfg.angleId, cfg.prompt);
    if (cfg.role === "validate") {
      const files = cfg.angleId === "critic_coverage" && synthCalls === 1;
      return {
        ...(await mockTopic(0.001)(cfg)),
        result: "Judged." + "\n\n```json\n"
          + JSON.stringify({ objections: files ? [{ ...DISTINCT_OBJECTIONS[0]!, severity: "blocking" }] : [] })
          + "\n```",
      };
    }
    if (cfg.angleId === "reconciliation") {
      const body = options.fuse ?? CURRENT_ANSWER;
      return {
        ...(await mockTopic(0.01)(cfg)),
        result: body === "" ? "" : body + fenced({
          headline: "Current answer",
          findings: [{ claim: "the pilot plant is scheduled for 2035", sources: ["https://example.org"], confidence: "high" }],
        }),
      };
    }
    if (cfg.role === "synthesis") {
      synthCalls += 1;
      const first = synthCalls === 1;
      const cost = first ? 0.01 : (options.synthesisCost ?? 0.01);
      return {
        ...(await mockTopic(cost)(cfg)),
        result: (first ? OVERTURNED : CORRECTION) + fenced(first
          ? { headline: "First pass",
              findings: [{ claim: "the pilot plant arrives in 2030", sources: ["https://example.org"], confidence: "medium" }],
              conflicts: [{ claim: "when the pilot plant arrives", positions: ["2030", "2035"] }] }
          : { headline: "Second pass",
              findings: [{ claim: "the pilot plant is scheduled for 2035", sources: ["https://example.org"], confidence: "high" }] }),
      };
    }
    return mockTopic()(cfg);
  };
  return { runTopic, prompts };
}

const reconciledTopics = (events: any[]) =>
  events.filter((e) => e.type === "topic_result" && e.reconciled === true);

/// R6 — the rounds are not the answer. A dive that changed its mind ends with ONE current answer the
/// engine composed, so the note the app writes is not a log of what each round believed.
describe("one current answer, not a round log", () => {
  it("fuses a two-round dive into one reconciled terminal synthesis", async () => {
    const c = collector();
    await runRun({ ...loopBudget, rounds: 3 }, {}, {
      sink: c.sink, sessionId: "qrun-reconcile", runTopic: divergingRun().runTopic,
    });
    const events = c.events();
    const fused = reconciledTopics(events);

    expect(fused).toHaveLength(1);
    expect(fused[0].role).toBe("synthesis");
    expect(fused[0].result).toContain(CURRENT_ANSWER);
    expect(fused[0].result, "the overturned round is not left standing in the answer")
      .not.toContain(OVERTURNED);
    expect(events.filter((e) => e.type === "topic_result").at(-1).reconciled,
           "the fuse is the terminal synthesis").toBe(true);
    expect(events.filter((e) => e.type === "phase").map((e) => e.phase)).toContain("reconciling");
    expect(events.at(-1).topics.filter((t: any) => t.reconciled)).toHaveLength(1);
    expect(events.at(-1).status).toBe("complete");
  });

  it("gives the reconciler the rounds and what the validators left standing", async () => {
    const f = divergingRun();
    const c = collector();
    let ceiling = 0;
    await runRun({ ...loopBudget, rounds: 3 }, {}, {
      sink: c.sink, sessionId: "qrun-reconcile-context",
      runTopic: async (cfg) => {
        if (cfg.angleId === "reconciliation") ceiling = cfg.perTopicBudgetUsd;
        return f.runTopic(cfg);
      },
    });
    const prompt = f.prompts.get("reconciliation")!;

    expect(ceiling, "the fuse draws one topic's worth of what the rounds left")
      .toBeLessThanOrEqual(loopBudget.perTopicBudgetUSD!);

    expect(prompt).toContain("ROUND 1");
    expect(prompt).toContain("ROUND 2");
    expect(prompt).toContain(OVERTURNED);
    expect(prompt).toContain(CORRECTION);
    expect(prompt).toContain(DISTINCT_OBJECTIONS[0]!.statement);
  });

  it("leaves a single-round run exactly as it was", async () => {
    const c = collector();
    await runRun({ ...loopBudget, rounds: 3 }, {}, {
      sink: c.sink, sessionId: "qrun-reconcile-single",
      runTopic: objectingRun({ objectingRounds: 0 }).runTopic,
    });
    const events = c.events();

    expect(reconciledTopics(events)).toHaveLength(0);
    expect(events.filter((e) => e.type === "phase").map((e) => e.phase)).not.toContain("reconciling");
  });

  it("does not pay to reformat rounds that only restated each other", async () => {
    const c = collector();
    await runRun({ ...loopBudget, rounds: 3 }, {}, {
      sink: c.sink, sessionId: "qrun-reconcile-convergent",
      runTopic: objectingRun({ objectingRounds: 1 }).runTopic,
    });
    const events = c.events();

    expect(events.filter((e) => e.type === "round")).toHaveLength(1);
    expect(reconciledTopics(events)).toHaveLength(0);
  });

  it("keeps the rounds' answer when the fuse comes back with nothing, and still owns its spend", async () => {
    const c = collector();
    await runRun({ ...loopBudget, rounds: 3 }, {}, {
      sink: c.sink, sessionId: "qrun-reconcile-empty", runTopic: divergingRun({ fuse: "" }).runTopic,
    });
    const events = c.events();
    const runResult = events.at(-1);

    expect(reconciledTopics(events)).toHaveLength(0);
    expect(events.filter((e) => e.type === "topic_result").at(-1).result).toContain(CORRECTION);
    expect(runResult.topics.some((t: any) => t.angle_id === "reconciliation"),
           "a fuse that came back empty still cost the run and is still on the ledger").toBe(true);
  });

  it("leaves the rounds standing when there is not a topic's worth of budget left to fuse them", async () => {
    const c = collector();
    await runRun({ ...twoAngles, rounds: 3, runBudgetUSD: 1, perTopicBudgetUSD: 0.25 }, {}, {
      sink: c.sink, sessionId: "qrun-reconcile-budget",
      runTopic: divergingRun({ synthesisCost: 0.9 }).runTopic,
    });
    const events = c.events();

    expect(events.filter((e) => e.type === "round")).toHaveLength(1);
    expect(reconciledTopics(events)).toHaveLength(0);
  });

  it("records the reconciled two-round fixture for the Swift consumer contract test", async () => {
    const c = collector();
    await runRun({ ...loopBudget, rounds: 3 }, { QUORUM_TAVILY_KEY: "fixture" }, {
      sink: c.sink, sessionId: "qrun-reconciled-fixture", now: () => 0,
      runTopic: divergingRun().runTopic,
    });
    const lines = c.events();
    const dir = join(import.meta.dirname, "..", "fixtures");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "run-reconciled-transcript.ndjson"),
                  lines.map((e) => JSON.stringify(e)).join("\n") + "\n");

    expect(lines[0].type).toBe("run_start");
    expect(lines.at(-1).type).toBe("run_result");
    expect(lines.filter((e) => e.type === "topic_result" && e.role === "synthesis")).toHaveLength(3);
    expect(reconciledTopics(lines)).toHaveLength(1);
  });
});

/// Protocol v4 — the judgement is on the wire and on the graph: the answer is a node, each validator task
/// is a verdict beside it, and what a validator files rides on that verdict instead of only reaching the
/// reader as prose at the end of the run.
describe("verdicts on the graph and validators on the wire", () => {
  it("draws the answer as a node the angles feed and the verdicts judge", async () => {
    const c = collector();
    await runRun(twoAngles, { QUORUM_TAVILY_KEY: "k" }, {
      sink: c.sink, sessionId: "qrun-verdict-graph", runTopic: citingTopic(),
    });
    const events = c.events();
    const nodes = events.filter((e) => e.type === "graph_node").map((e) => e.node);
    const edges = events.filter((e) => e.type === "graph_edge").map((e) => e.edge);

    expect(nodes.find((n) => n.id === "synthesis")).toMatchObject({ kind: "synthesis", round: 1 });
    expect(edges.filter((e) => e.kind === "synthesizes").map((e) => e.from)).toEqual(["a1", "a2"]);

    const verdicts = nodes.filter((n) => n.kind === "verdict");
    expect(verdicts.map((n) => n.id)).toEqual(
      ["v1_claim_sweep", "v1_coverage", "v1_conflicts", "v1_sources"]);
    expect(verdicts.every((n) => n.status === "pass")).toBe(true);
    expect(edges.filter((e) => e.kind === "judges")).toEqual(
      verdicts.map((n) => expect.objectContaining({ from: n.id, to: "synthesis" })));
  });

  it("carries what a critic filed on its verdict, round by round", async () => {
    const c = collector();
    const f = objectingRun({ objectingRounds: 1 });
    await runRun({ ...loopBudget, rounds: 3 }, {}, {
      sink: c.sink, sessionId: "qrun-verdict-objections", runTopic: f.runTopic,
    });
    const verdicts = c.events().filter((e) => e.type === "graph_node" && e.node.kind === "verdict")
      .map((e) => e.node);
    const coverage = verdicts.find((n) => n.id === "v1_coverage");

    expect(coverage).toMatchObject({ status: "objections(1)", round: 1, title: "Coverage critic" });
    expect(coverage.meta.objections).toEqual([expect.objectContaining({
      lens: "coverage", severity: "blocking", statement: "the answer never states 2025 pricing",
      followup: PRICING_FOLLOWUP,
    })]);
    expect(verdicts.filter((n) => n.round === 2).map((n) => n.id)).toEqual(
      ["v2_claim_sweep", "v2_coverage", "v2_conflicts", "v2_sources"]);
    expect(verdicts.find((n) => n.id === "v2_coverage").status).toBe("pass");
  });

  it("hangs the objection's question off the verdict that filed it, feeding the next round", async () => {
    const c = collector();
    const f = objectingRun({ objectingRounds: 1 });
    await runRun({ ...loopBudget, rounds: 3 }, {}, {
      sink: c.sink, sessionId: "qrun-objection-wired", runTopic: f.runTopic,
    });
    const events = c.events();
    const question = events.find((e) => e.type === "graph_node" && e.node.origin === "objection").node;
    const edges = events.filter((e) => e.type === "graph_edge").map((e) => e.edge);

    expect(question.parent_ids).toEqual(["v1_coverage"]);
    expect(edges).toContainEqual(expect.objectContaining({
      from: "v1_coverage", to: question.id, kind: "spawned", label: "coverage",
    }));
    expect(edges).toContainEqual(expect.objectContaining({
      from: question.id, to: "x1", kind: "decomposes",
    }));
  });

  it("streams the sweep, the critics and the citation check instead of judging invisibly", async () => {
    const c = collector();
    const judgingOutLoud = async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      if (cfg.role === "validate" || cfg.role === "verify") {
        cfg.emitter.textDelta(`Reading the answer as ${cfg.angleId}. `);
        cfg.emitter.usage(0.001, usage(0.001));
        const judged = cfg.role === "verify" ? { findings: [] }
          : cfg.angleId.startsWith("claim_sweep") ? { verdicts: [{ claim: 1, verdict: "supported" }] }
          : { objections: [] };
        return outcomeOf(cfg, "Judged.\n\n```json\n" + JSON.stringify(judged) + "\n```");
      }
      if (cfg.role !== "synthesis") return citingTopic()(cfg);
      const document = cfg.evidence!.register({
        url: "https://ex.test/synthesis", title: "Doc synthesis", contentType: "html", text: SNAPSHOT });
      return outcomeOf(cfg, citedResult("synthesis",
        [{ id: "a1c1", source: document.source_id, quote: QUOTE }],
        [{ claim: "synthesized claim", sources: ["https://nobody-cited.example/x"], citations: ["a1c1"],
           confidence: "high" }], "[^a1c1]"));
    };
    await runRun(twoAngles, { QUORUM_TAVILY_KEY: "k" },
                 { sink: c.sink, sessionId: "qrun-live-validators", runTopic: judgingOutLoud });
    const live = c.events().filter((e) => e.type === "stream_event" && e.angle_id);

    expect(live.map((e) => e.angle_id)).toEqual(expect.arrayContaining(
      ["verify", "claim_sweep_1", "critic_coverage", "critic_conflicts", "critic_sources"]));
  });

  it("holds back the validation reserve, so the loop cannot spend the sweep out of existence", async () => {
    const c = collector();
    const f = objectingRun({ objectingRounds: 9, distinctPerRound: true });
    await runRun({ ...twoAngles, rounds: 3, runBudgetUSD: 1.1 }, {}, {
      sink: c.sink, sessionId: "qrun-validation-reserve", runTopic: f.runTopic,
    });
    const events = c.events();
    const refused = events.find((e) => e.type === "graph_node" && e.node.status === "rejected");

    expect(f.researched, "the reserve is not spendable on another round of research").toEqual(["a1", "a2"]);
    expect(refused.node.meta.rejected_reason).toMatch(/validation/i);
    expect(events.at(-1).validation.spend_usd).toBeGreaterThan(0);
  });

  it("prunes a question the user waved off from the canvas", async () => {
    const c = collector();
    const queue = new ControlQueue();
    const spawns = { a1: { question: "What did the 2024 filing say?", why: "a paywall blocked it" } };
    const ran: string[] = [];
    await runRun(twoAngles, {}, {
      sink: c.sink, sessionId: "qrun-prune", controls: queue,
      runTopic: async (cfg) => {
        const ask = (spawns as Record<string, { question: string; why: string }>)[cfg.angleId];
        if (ask && cfg.spawn) {
          cfg.spawn({ ...ask, provoked_by: "s3f9a1c2" });
          queue.push({ type: "prune", id: "q1" });
        }
        if (cfg.role === "research") ran.push(cfg.angleId);
        return mockTopic()(cfg);
      },
    });
    const events = c.events();

    expect(ran).toEqual(["a1", "a2"]);
    expect(events.filter((e) => e.type === "graph_node_update" && e.id === "q1").at(-1))
      .toMatchObject({ status: "rejected" });
  });

  it("re-runs an angle the user retried, exactly once", async () => {
    const c = collector();
    const queue = new ControlQueue();
    const attempts: string[] = [];
    await runRun(twoAngles, {}, {
      sink: c.sink, sessionId: "qrun-retry", controls: queue,
      runTopic: async (cfg) => {
        attempts.push(cfg.angleId);
        if (cfg.angleId === "a1") queue.push({ type: "retry", id: "a1" });
        return mockTopic()(cfg);
      },
    });

    expect(attempts.filter((id) => id === "a1")).toHaveLength(2);
    expect(c.events().at(-1).topics.filter((t: TopicOutcome) => t.angle_id === "a1")).toHaveLength(2);
  });

  it("records the validated fixture for the Swift consumer contract test", async () => {
    const c = collector();
    await runRun({ ...loopBudget, rounds: 3 }, { QUORUM_TAVILY_KEY: "fixture" }, {
      sink: c.sink, sessionId: "qrun-validated-fixture", now: () => 0, runTopic: citingAndObjecting(),
    });
    const lines = c.events();
    const dir = join(import.meta.dirname, "..", "fixtures");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "run-validated-transcript.ndjson"),
                  lines.map((e) => JSON.stringify(e)).join("\n") + "\n");

    expect(lines[0]).toMatchObject({ type: "run_start", protocol_version: 4 });
    expect(lines.filter((e) => e.type === "graph_node" && e.node.kind === "verdict")).toHaveLength(8);
    expect(lines.some((e) => e.type === "graph_node" && e.node.origin === "objection")).toBe(true);
    expect(lines.filter((e) => e.type === "graph_edge" && e.edge.kind === "judges")).toHaveLength(8);
    expect(lines.some((e) => e.type === "stream_event" && e.angle_id === "claim_sweep_1")).toBe(true);
    expect(lines.at(-1).validation).toMatchObject({ status: "validated", holds: true, rounds: [{}, {}] });
    expect(lines.at(-1).type).toBe("run_result");
  });
});

/// The fixture's run: every topic captures a source and quotes it verbatim, the sweep passes what it is
/// handed, and the coverage critic objects once — so the recorded transcript carries evidence, verdicts,
/// an objection-born question and the second round that settles it.
function citingAndObjecting(): (cfg: RunTopicConfig) => Promise<TopicOutcome> {
  const research = citingTopic();
  let round = 0;
  return async (cfg) => {
    if (cfg.role === "synthesis") round += 1;
    if (cfg.role === "validate") {
      cfg.emitter.textDelta(`Reading the answer as ${cfg.angleId}. `);
      cfg.emitter.usage(0.001, usage(0.001));
      if (cfg.angleId === "critic_coverage" && round === 1) {
        return outcomeOf(cfg, "Judged.\n\n```json\n"
          + JSON.stringify({ objections: [{ ...DISTINCT_OBJECTIONS[0], severity: "blocking" }] }) + "\n```");
      }
    }
    return research(cfg);
  };
}

describe("a Claude CLI that is not logged in", () => {
  const refusal = {
    kind: "not_logged_in" as const,
    reason: "The Claude CLI is not logged in. Run `claude` in a terminal, sign in with /login, then try again.",
  };

  function refusingTopic(calls: string[]) {
    return async (cfg: RunTopicConfig): Promise<TopicOutcome> => {
      calls.push(`${cfg.role}:${cfg.angleId}`);
      return {
        angle_id: cfg.angleId, role: cfg.role, backend: "cli", provider: "claude-code",
        model: "sonnet", session_id: "qeng-x", status: "error",
        result: "Claude Code backend could not run.", usage: { ...usage(0), provider: "claude-code" },
        note: refusal.reason, refusal,
      };
    };
  }

  it("ends the run at planning with the refusal named, spending nothing more", async () => {
    const c = collector();
    const calls: string[] = [];
    const outcome = await runRun(
      { question: "q", angleModel: "claude-code/claude-haiku-4-5", synthesisModel: "claude-code/claude-haiku-4-5" },
      {},
      { sink: c.sink, sessionId: "qrun-logged-out", runTopic: refusingTopic(calls) },
    );
    const result = c.events().at(-1);

    expect(calls).toEqual(["plan:planning"]);
    expect(result).toMatchObject({ type: "run_result", status: "inconclusive", refusal });
    expect(result.note).toContain(refusal.reason);
    expect(outcome).toEqual({ status: "inconclusive", refusal });
  });

  it("stops launching angles once one of them is refused, and never synthesizes", async () => {
    const c = collector();
    const calls: string[] = [];
    await runRun(
      { ...twoAngles, angleConcurrency: 1, angleModel: "claude-code/claude-haiku-4-5",
        synthesisModel: "claude-code/claude-haiku-4-5" },
      {},
      { sink: c.sink, sessionId: "qrun-logged-out-wave", runTopic: refusingTopic(calls) },
    );
    const result = c.events().at(-1);

    expect(calls).toEqual(["research:a1"]);
    expect(result).toMatchObject({ status: "inconclusive", refusal });
    expect(result.note).toBe(refusal.reason);
  });

  it("leaves a run that was not refused without a refusal", async () => {
    const c = collector();
    const outcome = await runRun(twoAngles, {}, { sink: c.sink, sessionId: "qrun-fine", runTopic: mockTopic() });

    expect(outcome.refusal).toBeUndefined();
    expect(c.events().at(-1).refusal).toBeUndefined();
  });
});

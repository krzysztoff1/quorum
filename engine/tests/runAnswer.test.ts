import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { runRun, type RunConfig } from "../src/run.js";
import type { RunTopicConfig, TopicOutcome } from "../src/backend.js";
import type { UsageBlock } from "../src/emitter.js";
import { RunRecordSchema, type RunRecord } from "../src/record/schema.js";

const PAGE = "Fusion reached scientific breakeven at NIF in December 2022, producing 3.15 MJ from 2.05 MJ of laser energy.";
const QUOTE = "producing 3.15 MJ from 2.05 MJ of laser energy";

function usage(cost: number): UsageBlock {
  return { provider: "deepseek", model: "deepseek-chat", input_tokens: 1, output_tokens: 1, cache_read_tokens: 0,
           cache_write_tokens: 0, cost_usd: cost, search_calls: 0, fetch_calls: 0 };
}

function outcome(cfg: RunTopicConfig, result: string): TopicOutcome {
  return { angle_id: cfg.angleId, role: cfg.role, backend: "engine", provider: "deepseek", model: "deepseek-chat",
           session_id: `s-${cfg.angleId}`, status: "complete", result, usage: usage(0.01), note: null };
}

const fenced = (summary: unknown) => "```json\n" + JSON.stringify(summary) + "\n```";
const mj = (v: number) => ({ v, unit: "other", suffix: "MJ", basis: "reported", cite: ["a1c1"] });
const add = (path: string, value: unknown) => JSON.stringify({ op: "add", path, value });

function spec(extra: string[] = []): string {
  return "```qvs\n" + [
    add("/v", 1),
    add("/root", "answer"),
    add("/elements/answer", { type: "Answer", props: { lead: "NIF reached breakeven in 2022[^a1c1].", verdict: "settled" }, children: ["g1", "g2"] }),
    add("/elements/g1", { type: "Group", props: { title: "More energy out than in" }, children: ["c1", "energy"] }),
    add("/elements/c1", { type: "Claim", props: { text: "NIF produced 3.15 MJ from 2.05 MJ[^a1c1].", confidence: "high" } }),
    add("/elements/energy", { type: "RangeCompare", props: { measure: "Laser shot energy", rows: [
      { label: "Out", value: mj(3.15) }, { label: "In", value: mj(2.05) },
    ], caption: "Output beat the laser input[^a1c1]." } }),
    add("/elements/g2", { type: "Group", props: { title: "Gain" }, children: ["gain"] }),
    add("/elements/gain", { type: "Stat", props: { value: { v: 4, unit: "ratio", basis: "reported", cite: ["a1c1"] }, label: "Target gain", caption: "Gain was above one[^a1c1]." } }),
    ...extra,
  ].join("\n") + "\n```\n\n" + fenced({ headline: "Breakeven happened in 2022", status: "complete",
    findings: [{ claim: "NIF produced 3.15 MJ", sources: ["https://ex.test/a1"], confidence: "high", citations: ["a1c1"] }],
    conflicts: [], gaps: [] });
}

interface Calls {
  sweepPrompts: string[];
  repairPrompts: string[];
}

function topics(synthesis: string, calls: Calls, repairReply?: string): (cfg: RunTopicConfig) => Promise<TopicOutcome> {
  return async (cfg) => {
    if (cfg.angleId === "answer_repair") {
      calls.repairPrompts.push(cfg.prompt);
      return outcome(cfg, repairReply ?? "");
    }
    if (cfg.role === "validate") {
      if (cfg.angleId.startsWith("claim_sweep")) calls.sweepPrompts.push(cfg.prompt);
      const judged = cfg.angleId.startsWith("claim_sweep") ? { verdicts: [] } : { objections: [] };
      return outcome(cfg, "Judged.\n\n" + fenced(judged));
    }
    const document = cfg.evidence!.register({ url: `https://ex.test/${cfg.angleId}`, title: `Doc ${cfg.angleId}`, contentType: "html", text: PAGE });
    cfg.emitter.document(document);
    if (cfg.role === "synthesis") return outcome(cfg, synthesis);
    return outcome(cfg, `Breakeven was reached.[^c1]\n\n` + fenced({
      headline: "Breakeven", status: "complete",
      findings: [{ claim: "Breakeven was reached", sources: [document.url], confidence: "high", citations: ["c1"] }],
      citations: [{ id: "c1", source: document.source_id, quote: QUOTE }],
    }));
  };
}

const config: RunConfig = {
  question: "Has fusion reached scientific breakeven?",
  angles: [{ title: "Breakeven", prompt: "Has fusion reached net energy gain?" }],
  angleModel: "deepseek/deepseek-chat", synthesisModel: "deepseek/deepseek-chat",
  runBudgetUSD: 1, perTopicBudgetUSD: 0.5, rounds: 1, runDeadlineSec: 600,
};

async function run(synthesis: string, repairReply?: string) {
  const brainDir = mkdtempSync(join(tmpdir(), "brain-answer-"));
  const lines: string[] = [];
  const calls: Calls = { sweepPrompts: [], repairPrompts: [] };
  let runDir = "";
  await runRun({ ...config, brainDir }, { QUORUM_TAVILY_KEY: "k" }, {
    sink: (line) => {
      lines.push(line);
      const event = JSON.parse(line);
      if (event.type === "run_start") runDir = event.run_dir;
    },
    sessionId: "qrun-answer", now: () => Date.parse("2026-10-09T10:00:00.000Z"),
    runTopic: topics(synthesis, calls, repairReply),
  });
  const events = lines.map((l) => JSON.parse(l));
  const record: RunRecord = RunRecordSchema.parse(JSON.parse(readFileSync(join(runDir, "run.json"), "utf8")));
  return { events, record, calls };
}

describe("the synthesis writes the answer as a spec, and the engine settles it", () => {
  it("puts one compiled answer in the record, never the patches", async () => {
    const { record, events } = await run(spec());
    expect(record.answer).toMatchObject({ catalog: "qvs/1", origin: "spec", display: { energy: "chart", gain: "chart" } });
    expect(record.answer!.markdown).not.toContain("\"op\"");
    const topic = events.find((e) => e.type === "topic_result" && e.angle_id === "synthesis");
    expect(topic.answer.spec.root).toBe("answer");
    expect(topic.result).not.toContain("```qvs");
  });

  it("checks every number against its quote, shows the one that is not there, and files it", async () => {
    const { record, events } = await run(spec());
    const gain = (record.answer!.spec.elements.gain as any).props.value.trust;
    expect(gain).toEqual({ tier: "supported", trace: "untraced", confidence: "unverified" });
    expect((record.answer!.spec.elements.energy as any).props.rows[0].value.trust.trace).toBe("quoted");
    expect(record.stats).toMatchObject({ visuals: 2, datums: 3, datums_unverified: 1 });
    const filed = events.at(-1).validation.rounds[0].objections;
    expect(filed).toContainEqual(expect.objectContaining({ lens: "claim_sweep", statement: expect.stringContaining("Target gain = 4×") }));
  });

  it("sends each located datum through the claim sweep with its chart as context", async () => {
    const { calls } = await run(spec());
    const prompt = calls.sweepPrompts.join("\n");
    expect(prompt).toContain("(a figure in a chart: Laser shot energy — Output beat the laser input.): Out: 3.15 MJ");
    expect(prompt).toContain("NIF produced 3.15 MJ from 2.05 MJ.");
  });

  it("asks one repair call about a broken visual and keeps the text when it cannot help", async () => {
    const broken = add("/elements/g2/children/-", "bars");
    const bars = add("/elements/bars", { type: "BarCompare", props: { measure: "Shots", bars: [
      { label: "A", value: { ...mj(3.15), as_of: "2022" } }, { label: "B", value: { ...mj(2.05), as_of: "2022" } },
      { label: "C", value: { v: 2, unit: "count", basis: "reported", cite: ["a1c1"], as_of: "2022" } },
    ], caption: "Three shots[^a1c1]." } });
    const { calls, record } = await run(spec([broken, bars]));
    expect(calls.repairPrompts).toHaveLength(1);
    expect(calls.repairPrompts[0]).toContain("unit_mixed");
    expect(record.answer!.spec.elements.c1).toBeDefined();
    expect(record.answer!.repairs.map((r) => r.action)).toContain("to_table");
    expect(record.checks.find((c) => c.id === "spec")?.status).toBe("pass");
  });

  it("falls back to the writer's prose when it wrote no spec", async () => {
    const { record } = await run("NIF produced 3.15 MJ from 2.05 MJ.[^a1c1]\n\n" + fenced({ headline: "h", status: "complete", findings: [] }));
    expect(record.answer).toMatchObject({ origin: "prose", markdown: "NIF produced 3.15 MJ from 2.05 MJ.[^a1c1]" });
  });
});

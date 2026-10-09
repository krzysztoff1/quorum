import { existsSync, mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { runRun, type RunConfig } from "../src/run.js";
import type { RunTopicConfig, TopicOutcome } from "../src/backend.js";
import type { UsageBlock } from "../src/emitter.js";
import { RunRecordSchema, QuestionSchema, type RunRecord } from "../src/record/schema.js";
import { checkRun, loadRunDir } from "../src/check.js";

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

function fenced(summary: unknown): string {
  return "```json\n" + JSON.stringify(summary) + "\n```";
}

interface Seen {
  recordDuringSynthesis?: RunRecord;
}

function topics(runDirOf: () => string | undefined, seen: Seen): (cfg: RunTopicConfig) => Promise<TopicOutcome> {
  return async (cfg) => {
    if (cfg.role === "validate") {
      const judged = cfg.angleId.startsWith("claim_sweep") ? { verdicts: [{ claim: 1, verdict: "supported" }] } : { objections: [] };
      return outcome(cfg, "Judged.\n\n" + fenced(judged));
    }
    const document = cfg.evidence!.register({ url: `https://ex.test/${cfg.angleId}`, title: `Doc ${cfg.angleId}`, contentType: "html", text: PAGE });
    cfg.emitter.document(document);
    cfg.emitter.textDelta(`Researching ${cfg.angleId}. `);
    if (cfg.role === "synthesis") {
      const dir = runDirOf();
      if (dir) seen.recordDuringSynthesis = JSON.parse(readFileSync(join(dir, "run.json"), "utf8"));
      return outcome(cfg, "NIF produced 3.15 MJ from 2.05 MJ.[^a1c1]\n\n" + fenced({
        headline: "Breakeven happened in 2022", status: "complete",
        findings: [{ claim: "NIF produced 3.15 MJ", sources: ["https://ex.test/a1"], confidence: "high", citations: ["a1c1"] }],
        conflicts: [], gaps: [],
      }));
    }
    return outcome(cfg, `Breakeven was reached.[^c1] A second figure.[^c17]\n\n` + fenced({
      headline: `Finding ${cfg.angleId}`, status: "complete",
      findings: [{ claim: "Breakeven was reached", sources: [document.url], confidence: "high", citations: ["c1", "c17"] }],
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

async function runInBrain() {
  const brainDir = mkdtempSync(join(tmpdir(), "brain-"));
  const lines: string[] = [];
  const seen: Seen = {};
  let ids = 0;
  let runDir: string | undefined;
  await runRun({ ...config, brainDir }, { QUORUM_TAVILY_KEY: "k" }, {
    sink: (line) => {
      lines.push(line);
      const event = JSON.parse(line);
      if (event.type === "run_start") runDir = event.run_dir;
    },
    sessionId: "qrun-brain", now: () => Date.parse("2026-10-09T10:00:00.000Z"),
    newId: () => ["QUESTION0000000000000000AA", "RUN000000000000000000000AA"][ids++]!,
    runTopic: topics(() => runDir, seen),
  });
  const events = lines.map((l) => JSON.parse(l));
  return { brainDir, events, seen, runDir: runDir! };
}

describe("a run in the brain folder", () => {
  it("lays out questions/<id>/question.json and runs/<id>/ and says where on run_start", async () => {
    const { brainDir, events, runDir } = await runInBrain();
    const questionDir = join(brainDir, "questions", "QUESTION0000000000000000AA");
    expect(runDir).toBe(join(questionDir, "runs", "RUN000000000000000000000AA"));
    expect(events[0]).toMatchObject({ type: "run_start", run_id: "RUN000000000000000000000AA", question_id: "QUESTION0000000000000000AA" });
    const question = JSON.parse(readFileSync(join(questionDir, "question.json"), "utf8"));
    expect(QuestionSchema.parse(question)).toMatchObject({
      title: "Has fusion reached scientific breakeven", title_source: "question", language: "en",
      run_ids: ["RUN000000000000000000000AA"],
    });
    expect(existsSync(join(runDir, "events.ndjson"))).toBe(true);
    expect(existsSync(join(runDir, "evidence", "documents.jsonl"))).toBe(true);
  });

  it("writes a finished run.json the schema accepts, with the checks it ran", async () => {
    const { events, runDir } = await runInBrain();
    const record = RunRecordSchema.parse(JSON.parse(readFileSync(join(runDir, "run.json"), "utf8")));
    expect(record.status).toBe(events.at(-1).status);
    expect(record.checks.map((c) => c.id)).toEqual(events.at(-1).checks.results.map((c: any) => c.id));
    expect(record.answer?.markdown).toBe("NIF produced 3.15 MJ from 2.05 MJ.[^a1c1]");
    expect(record.stats.sources_cited).toBe(1);
    expect(record.limits).toEqual({ cap_usd: 1, deadline_s: 600 });
  });

  it("keeps run.json valid while the run is still going", async () => {
    const { seen } = await runInBrain();
    expect(seen.recordDuringSynthesis?.status).toBe("running");
    expect(RunRecordSchema.safeParse(seen.recordDuringSynthesis).success).toBe(true);
  });

  it("writes each task's own stream to transcripts/", async () => {
    const { runDir } = await runInBrain();
    expect(readdirSync(join(runDir, "transcripts")).sort()).toContain("a1.ndjson");
    const lines = readFileSync(join(runDir, "transcripts", "a1.ndjson"), "utf8").trim().split("\n").map((l) => JSON.parse(l));
    expect(lines.every((l) => l.angle_id === "a1")).toBe(true);
  });

  it("exports the answer to answers/ on finish", async () => {
    const { brainDir } = await runInBrain();
    const [file] = readdirSync(join(brainDir, "answers"));
    expect(file).toBe("has-fusion-reached-scientific-breakeven-000aa.md");
    const markdown = readFileSync(join(brainDir, "answers", file!), "utf8");
    expect(markdown).toContain("[^a1c1]: [Doc a1](https://ex.test/a1)");
  });

  it("strips a footnote marker the angle never declared, flags it, and still passes check", async () => {
    const { events, runDir } = await runInBrain();
    const result = events.at(-1);
    expect(result.stripped_markers).toEqual([{ angle_id: "a1", marker: "a1c17" }]);
    const angle = result.topics.find((t: TopicOutcome) => t.angle_id === "a1");
    expect(angle.result).not.toContain("[^a1c17]");
    expect(angle.result).not.toContain('"a1c17"');
    const record: RunRecord = JSON.parse(readFileSync(join(runDir, "run.json"), "utf8"));
    expect(record.stripped_markers).toEqual([{ task_id: "a1", marker: "a1c17" }]);

    const report = checkRun(loadRunDir(runDir));
    expect(report.results.filter((r) => r.status === "fail")).toEqual([]);
    expect(report.results.find((r) => r.id === "markers")?.status).toBe("warn");
    expect(report.results.find((r) => r.id === "references")?.status).toBe("warn");
  });

  it("reads back from disk the same verdict it attached to run_result", async () => {
    const { events, runDir } = await runInBrain();
    expect(checkRun(loadRunDir(runDir))).toEqual(events.at(-1).checks);
  });
});

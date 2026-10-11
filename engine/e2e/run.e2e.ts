import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { appendFileSync, existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { RunRecordSchema, QuestionSchema } from "../src/record/schema.js";
import { checkRunDir, E2E_BUILD, engineBinary, exportRunDir, runEngine, serveFixtureSite, type EngineRun, type FixtureSite } from "./harness.js";

let binary: string;
let site: FixtureSite;
let happy: EngineRun;

beforeAll(async () => {
  binary = engineBinary();
  site = await serveFixtureSite();
  happy = await runEngine({ binary, baseUrl: site.baseUrl });
});

afterAll(async () => {
  await site.close();
});

const result = () => happy.events.at(-1);
const ofType = (type: string) => happy.events.filter((e) => e.type === type);

describe("the compiled engine, a scripted claude CLI and a local web, end to end", () => {
  it("plans, researches, grounds, validates and finishes complete with a clean exit", () => {
    expect(happy.exitCode, happy.stderr).toBe(0);
    expect(result()).toMatchObject({ type: "run_result", status: "complete", grounding: "captured" });
    expect(ofType("plan")[0].angles).toHaveLength(2);
    expect(ofType("phase").map((p) => p.phase)).toEqual(
      expect.arrayContaining(["planning", "researching", "synthesizing", "grounding", "validating", "done"]),
    );
  });

  it("stamps the run with the build that was compiled into the binary", () => {
    expect(happy.events[0]).toMatchObject({ type: "run_start", build: E2E_BUILD });
  });

  it("captures the pages the angles read as snapshots on disk, over the engine's own fetch", () => {
    const documents = result().documents.filter((d: any) => d.snapshot_path);
    expect(documents.length).toBeGreaterThanOrEqual(2);
    const obligations = documents.find((d: any) => d.url.endsWith("/ai-act-obligations.html"));
    const snapshot = readFileSync(join(happy.runDir, "evidence", obligations.snapshot_path), "utf8");
    expect(snapshot).toContain("technical documentation of the model");
    expect(snapshot).not.toContain("Cookie settings");
    expect(obligations.source_type).toBeDefined();
  });

  it("records the blocked page as a capture failure instead of dropping it", () => {
    expect(result().capture_failures).toEqual(
      expect.arrayContaining([expect.objectContaining({ stage: "fetch", kind: "blocked" })]),
    );
    expect(ofType("capture_failure").length).toBeGreaterThanOrEqual(1);
  });

  it("verifies every quote the answer cites against a snapshot, none left unresolved", () => {
    const synthesis = result().topics.find((t: any) => t.role === "synthesis");
    expect(synthesis.citations.length).toBeGreaterThanOrEqual(2);
    expect(synthesis.citations.map((c: any) => c.match).sort()).toEqual(["exact", "normalized"]);
    expect(synthesis.result).toMatch(/\[\^a1c1\]/);
    expect(synthesis.result).toMatch(/\[\^a2c1\]/);
  });

  it("sweeps the claims against located quotes and runs the critics", () => {
    const validation = result().validation;
    expect(validation.status).toBe("validated");
    expect(validation.rounds[0].claims_checked).toBeGreaterThanOrEqual(2);
    expect(validation.rounds[0].verdicts.every((v: any) => v.verdict === "supported")).toBe(true);
    expect(validation.rounds[0]).toMatchObject({ sweep: "run", critics: "run" });
    expect(validation.spend_usd).toBeGreaterThan(0);
  });

  it("evaluates its own checks and passes them", () => {
    expect(result().checks.failed, JSON.stringify(result().checks.results)).toBe(0);
    expect(result().checks.ok).toBe(true);
  });

  it("keeps events.ndjson that quorum-engine check audits to the same verdict", () => {
    expect(existsSync(join(happy.runDir, "events.ndjson"))).toBe(true);
    const audit = checkRunDir(binary, happy.runDir);
    expect(audit.exitCode, audit.stdout).toBe(0);
    expect(audit.json.ok).toBe(true);
    expect(audit.json.run).toMatchObject({ build: E2E_BUILD, status: "complete", grounding: "captured", stripped_markers: 0 });
    expect(audit.json.run.snapshots).toBeGreaterThanOrEqual(2);
  });

  it("writes the run into the brain folder as questions/<id>/question.json and runs/<id>/run.json", () => {
    const start = happy.events[0];
    expect(happy.runDir).toBe(join(happy.brainDir, "questions", start.question_id, "runs", start.run_id));
    const question = QuestionSchema.parse(JSON.parse(readFileSync(join(happy.brainDir, "questions", start.question_id, "question.json"), "utf8")));
    expect(question.run_ids).toEqual([start.run_id]);
    const record = RunRecordSchema.parse(JSON.parse(readFileSync(join(happy.runDir, "run.json"), "utf8")));
    expect(record).toMatchObject({ id: start.run_id, question_id: start.question_id, status: "complete" });
    expect(record.pipeline).toMatchObject({ build: E2E_BUILD, backend: "claude-code", grounding: "captured" });
    expect(record.stats.sources_cited).toBeGreaterThanOrEqual(2);
    expect(record.stats.sources_read).toBe(record.sources.filter((s) => s.snapshot_path).length);
    expect(record.claims.length).toBeGreaterThanOrEqual(2);
    expect(record.claims.every((c) => c.verdict.verdict === "supported")).toBe(true);
    expect(record.checks.filter((c) => c.status === "fail")).toEqual([]);
  });

  it("keeps each task's raw stream under transcripts/", () => {
    expect(readdirSync(join(happy.runDir, "transcripts"))).toEqual(expect.arrayContaining(["a1.ndjson", "a2.ndjson", "synthesis.ndjson"]));
  });

  it("exports a self-contained markdown answer, every marker defined, also into answers/", () => {
    const exported = exportRunDir(binary, happy.runDir);
    expect(exported.exitCode, exported.stderr).toBe(0);
    const markers = new Set([...exported.stdout.matchAll(/\[\^([A-Za-z0-9_-]+)\](?!:)/g)].map((m) => m[1]));
    const definitions = new Set([...exported.stdout.matchAll(/^\[\^([A-Za-z0-9_-]+)\]:/gm)].map((m) => m[1]));
    expect(markers.size).toBeGreaterThanOrEqual(2);
    expect(definitions).toEqual(markers);
    const [file] = readdirSync(join(happy.brainDir, "answers"));
    expect(readFileSync(join(happy.brainDir, "answers", file!), "utf8")).toBe(exported.stdout);
  });

  it("reports a snapshot edited after the run as a failed check", () => {
    const documents = result().documents.filter((d: any) => d.snapshot_path);
    appendFileSync(join(happy.runDir, "evidence", documents[0].snapshot_path), " edited afterwards");
    const audit = checkRunDir(binary, happy.runDir);
    expect(audit.exitCode).toBe(1);
    expect(audit.stdout).toMatch(/FAIL\s+snapshots/);
  });
});

describe("a Claude CLI that is not logged in", () => {
  let refused: EngineRun;
  beforeAll(async () => {
    refused = await runEngine({ binary, baseUrl: site.baseUrl, scenario: "logged-out" });
  });

  it("ends the run refused with its own exit code, naming the fix, having spent nothing", () => {
    const final = refused.events.at(-1);
    expect(refused.exitCode).toBe(3);
    expect(final).toMatchObject({ type: "run_result", status: "inconclusive", total_cost_usd: 0 });
    expect(final.refusal).toMatchObject({ kind: "not_logged_in" });
    expect(final.refusal.reason).toContain("/login");
    expect(refused.events.filter((e) => e.type === "topic_result")).toHaveLength(0);
  });

  it("passes its own checks: a refused run is consistent, only incomplete", () => {
    expect(refused.events.at(-1).checks.ok).toBe(true);
  });
});

describe("a run that was scoped first", () => {
  const brief = {
    asked: "ai act gpai", question: "What do the EU AI Act's obligations for general-purpose AI models require, and from when?",
    title: "EU AI Act: obligations for general-purpose AI", language: "en", tier: "deep", suggested_tier: "deep",
    tier_reason: "Two parts, several sources.", clarifications: [{ question: "Which part?", answer: "Both" }],
  };
  let scoped: EngineRun;

  beforeAll(async () => {
    scoped = await runEngine({ binary, baseUrl: site.baseUrl, brief });
  });

  it("titles the question with the brief's title and carries the brief, tier included, in the record", () => {
    const questionDir = join(scoped.brainDir, "questions", readdirSync(join(scoped.brainDir, "questions"))[0]!);
    const question = QuestionSchema.parse(JSON.parse(readFileSync(join(questionDir, "question.json"), "utf8")));
    const record = RunRecordSchema.parse(JSON.parse(readFileSync(join(scoped.runDir, "run.json"), "utf8")));

    expect(question).toMatchObject({ title: brief.title, title_source: "scope", original_text: "ai act gpai", resolved_text: brief.question });
    expect(record.brief).toEqual(brief);
  });

  it("passes every integrity check, the title and language ones included", () => {
    const checked = checkRunDir(binary, scoped.runDir);

    expect(checked.exitCode, checked.stdout).toBe(0);
    expect(checked.json.results.filter((r: any) => r.id === "title" || r.id === "language").map((r: any) => r.status)).toEqual(["pass", "pass"]);
  });
});

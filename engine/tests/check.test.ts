import { describe, it, expect } from "vitest";
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { checkRun, loadRunDir, formatReport, summarizeRun, type CheckReport } from "../src/check.js";
import { PROTOCOL_VERSION } from "../src/emitter.js";
import { EvidenceStore } from "../src/evidence.js";
import { RecordFold } from "../src/record/build.js";
import { newQuestion, writeJsonAtomic } from "../src/record/store.js";

const PAGE = "The AI Act applies to general-purpose AI models from 2 August 2025. Providers must publish a training-content summary.";
const QUOTE = "applies to general-purpose AI models from 2 August 2025";

interface Run {
  runDir: string;
  events: any[];
  evidence: EvidenceStore;
}

function summaryJson(summary: unknown): string {
  return "```json\n" + JSON.stringify(summary) + "\n```";
}

function record(overrides: { mutate?: (r: Run) => void } = {}): Run {
  const runDir = mkdtempSync(join(tmpdir(), "check-run-"));
  const evidenceDir = join(runDir, "evidence");
  const evidence = new EvidenceStore({ dir: evidenceDir, now: () => 0 });
  const document = evidence.register({ url: "https://example.org/ai-act", title: "AI Act", text: PAGE });
  const citation = { ...evidence.resolveCitation({ id: "c1", source: document.source_id, quote: QUOTE }), id: "c1" };
  const synthesis = {
    angle_id: "synthesis", role: "synthesis", backend: "cli", provider: "claude-code", model: "haiku",
    session_id: "s", status: "complete", note: null,
    usage: { cost_usd: 0.1 },
    result: `The Act applies from August 2025.[^c1]\n\n${summaryJson({
      headline: "h", status: "complete", sourcesConsulted: 1,
      findings: [{ claim: "The Act applies from August 2025.", sources: ["https://example.org/ai-act"], confidence: "high", citations: ["c1"] }],
      citations: [citation],
    })}`,
    citations: [citation],
  };
  const events = [
    { type: "run_start", session_id: "q", protocol_version: PROTOCOL_VERSION, build: "abc1234", engine_version: "0.1.0", grounding: "captured" },
    { type: "phase", phase: "planning" },
    { type: "document", angle_id: "a1", document },
    { type: "topic_result", ...synthesis },
    { type: "phase", phase: "done" },
    {
      type: "run_result", status: "complete", grounding: "captured", total_cost_usd: 0.25,
      topics: [
        { angle_id: "a1", role: "research", status: "complete", usage: { cost_usd: 0.1 }, result: "r", citations: [] },
        synthesis,
      ],
      documents: evidence.all(), capture_failures: [], citation_orphans: [],
      validation: {
        status: "validated", holds: true, blocking: 0, spend_usd: 0.05, objections_admitted: 0,
        objections_resolved: 0, objections_outstanding: [], unsupported_citations: [],
        rounds: [{ round: 1, sweep: "run", critics: "run", claims_found: 1, claims_checked: 1,
          verdicts: [{ claim_id: "k1", claim: "x", verdict: "supported" }], objections: [],
          discarded_objections: 0, holds: true }],
      },
    },
  ];
  const result: Run = { runDir, events, evidence };
  overrides.mutate?.(result);
  return result;
}

const QUESTION = newQuestion("q1", "2026-10-09T10:00:00.000Z", "When does the AI Act apply to GPAI models?", "en",
  "When does the AI Act apply to GPAI models", "r1");

function folded(events: any[]) {
  const fold = new RecordFold({
    runId: "r1", questionId: "q1", kind: "initial", createdAt: QUESTION.created_at, question: QUESTION.original_text,
    language: "en", models: { planner: "m", research: "m", synthesis: "m", validator: "m" }, limits: {}, transcripts: false,
  });
  for (const event of events) fold.apply(event, "2026-10-09T10:01:00.000Z");
  return fold.snapshot();
}

function run(r: Run): CheckReport {
  return checkRun({
    events: r.events, evidenceDir: join(r.runDir, "evidence"), malformedLines: 0,
    record: folded(r.events), question: QUESTION,
  });
}

function storeRecord(r: Run): void {
  const runDir = join(r.runDir, "questions", "q1", "runs", "r1");
  writeJsonAtomic(join(r.runDir, "questions", "q1", "question.json"), QUESTION);
  writeJsonAtomic(join(runDir, "run.json"), folded(r.events));
}

function statusOf(report: CheckReport, id: string): string | undefined {
  return report.results.find((x) => x.id === id)?.status;
}

function failing(report: CheckReport): string[] {
  return report.results.filter((x) => x.status === "fail").map((x) => x.id);
}

const resultOf = (r: Run) => r.events.at(-1);
const synthesisOf = (r: Run) => resultOf(r).topics.at(-1);

describe("checkRun", () => {
  it("passes a coherent run", () => {
    const report = run(record());
    expect(failing(report)).toEqual([]);
    expect(report.ok).toBe(true);
    expect(report.failed).toBe(0);
  });

  it("fails a run stream with no build stamp", () => {
    const r = record();
    delete r.events[0].build;
    expect(failing(run(r))).toContain("stamp");
  });

  it("fails a run that speaks a protocol other than the engine's", () => {
    const r = record();
    r.events[0].protocol_version = PROTOCOL_VERSION - 1;
    expect(failing(run(r))).toContain("stamp");
  });

  it("fails a stream that does not begin with run_start and end with run_result", () => {
    const r = record();
    r.events.pop();
    expect(failing(run(r))).toContain("stream");
  });

  it("fails a stream with unreadable lines", () => {
    const r = record();
    const report = checkRun({ events: r.events, evidenceDir: join(r.runDir, "evidence"), malformedLines: 2 });
    expect(failing(report)).toContain("stream");
  });

  it("fails a footnote marker that names no citation", () => {
    const r = record();
    synthesisOf(r).result = synthesisOf(r).result.replace("[^c1]", "[^c9]");
    expect(failing(run(r))).toContain("markers");
  });

  it("fails a finding that leans on a citation the answer never declared", () => {
    const r = record();
    const summary = JSON.parse(synthesisOf(r).result.split("```json\n")[1]!.split("\n```")[0]!);
    summary.findings[0].citations = ["c1", "c7"];
    synthesisOf(r).result = `The Act applies from August 2025.[^c1]\n\n${summaryJson(summary)}`;
    expect(failing(run(r))).toContain("markers");
  });

  it("fails a citation whose source was never captured", () => {
    const r = record();
    const summary = JSON.parse(synthesisOf(r).result.split("```json\n")[1]!.split("\n```")[0]!);
    summary.citations[0].source_id = "s-missing";
    synthesisOf(r).result = `The Act applies from August 2025.[^c1]\n\n${summaryJson(summary)}`;
    expect(failing(run(r))).toContain("sources");
  });

  it("accepts a citation on a source whose capture failed, because the failure is on record", () => {
    const r = record();
    const failed = r.evidence.recordFetchFailure("https://blocked.example/x", "blocked", "403");
    const summary = JSON.parse(synthesisOf(r).result.split("```json\n")[1]!.split("\n```")[0]!);
    summary.citations.push({ id: "c2", source_id: failed.source_id, quote: "q", match: "unresolved" });
    synthesisOf(r).result = `The Act applies from August 2025.[^c1][^c2]\n\n${summaryJson(summary)}`;
    resultOf(r).documents = r.evidence.all();
    resultOf(r).capture_failures = r.evidence.captureFailures();
    expect(failing(run(r))).toEqual([]);
  });

  it("fails a citation resting on a source with neither a snapshot nor a recorded failure", () => {
    const r = record();
    const bare = r.evidence.registerSearchResult("https://seen.example/only-in-search", "seen");
    const summary = JSON.parse(synthesisOf(r).result.split("```json\n")[1]!.split("\n```")[0]!);
    summary.citations.push({ id: "c2", source_id: bare.source_id, quote: "q", match: "unresolved" });
    synthesisOf(r).result = `The Act applies from August 2025.[^c1][^c2]\n\n${summaryJson(summary)}`;
    resultOf(r).documents = r.evidence.all();
    expect(failing(run(r))).toContain("sources");
  });

  it("fails a resolved citation whose span lies outside its snapshot", () => {
    const r = record();
    const summary = JSON.parse(synthesisOf(r).result.split("```json\n")[1]!.split("\n```")[0]!);
    summary.citations[0].end = PAGE.length + 50;
    synthesisOf(r).result = `The Act applies from August 2025.[^c1]\n\n${summaryJson(summary)}`;
    expect(failing(run(r))).toContain("spans");
  });

  it("fails a resolved citation whose quote is not at the span it claims", () => {
    const r = record();
    const summary = JSON.parse(synthesisOf(r).result.split("```json\n")[1]!.split("\n```")[0]!);
    summary.citations[0].start = 0;
    summary.citations[0].end = 10;
    synthesisOf(r).result = `The Act applies from August 2025.[^c1]\n\n${summaryJson(summary)}`;
    expect(failing(run(r))).toContain("spans");
  });

  it("fails when a snapshot file is missing from the evidence directory", () => {
    const r = record();
    rmSync(join(r.runDir, "evidence", "sources"), { recursive: true });
    expect(failing(run(r))).toContain("snapshots");
  });

  it("fails when a snapshot's length no longer matches what the index recorded", () => {
    const r = record();
    const doc = r.evidence.all()[0]!;
    appendFileSync(join(r.runDir, "evidence", doc.snapshot_path!), " tampered");
    expect(failing(run(r))).toContain("snapshots");
  });

  it("fails when the run's document list and the evidence index disagree", () => {
    const r = record();
    resultOf(r).documents = [];
    expect(failing(run(r))).toContain("counts");
  });

  it("fails when the run's capture failures and the failure log disagree", () => {
    const r = record();
    r.evidence.recordFetchFailure("https://blocked.example/x", "blocked", "403");
    expect(failing(run(r))).toContain("counts");
  });

  it("fails a total cost smaller than the topics it is made of", () => {
    const r = record();
    resultOf(r).total_cost_usd = 0.01;
    expect(failing(run(r))).toContain("counts");
  });

  it("fails a validated round whose claims were neither judged nor reported unjudged", () => {
    const r = record();
    resultOf(r).validation.rounds[0].claims_found = 3;
    expect(failing(run(r))).toContain("verdicts");
  });

  it("accepts claims left unjudged when the round says so explicitly", () => {
    const r = record();
    const round = resultOf(r).validation.rounds[0];
    round.claims_found = 3;
    round.objections = [{ lens: "claim_sweep", statement: "2 claims were not judged", severity: "blocking", followup: "re-check" }];
    expect(failing(run(r))).toEqual([]);
  });

  it("fails a finished run with no validation at all", () => {
    const r = record();
    delete resultOf(r).validation;
    expect(failing(run(r))).toContain("verdicts");
  });

  it("fails grounding 'none' when nothing explains it", () => {
    const r = record();
    resultOf(r).grounding = "none";
    expect(failing(run(r))).toContain("grounding");
  });

  it("fails grounding 'captured' when not a single snapshot exists and no failure explains it", () => {
    const r = record();
    rmSync(join(r.runDir, "evidence"), { recursive: true });
    mkdirSync(join(r.runDir, "evidence"));
    resultOf(r).documents = [];
    expect(failing(run(r))).toContain("grounding");
  });

  it("fails a run that completed despite a refusal", () => {
    const r = record();
    resultOf(r).refusal = { kind: "not_logged_in", reason: "x" };
    expect(failing(run(r))).toContain("refusal");
  });

  it("does not demand evidence from a run that was refused before any research", () => {
    const r = record();
    rmSync(join(r.runDir, "evidence"), { recursive: true });
    const stopped = {
      type: "run_result", status: "inconclusive", grounding: "captured", total_cost_usd: 0, topics: [],
      documents: [], capture_failures: [], citation_orphans: [],
      refusal: { kind: "not_logged_in", reason: "x" }, note: "x",
    };
    r.events = [r.events[0], stopped];
    expect(failing(run(r))).toEqual([]);
  });

  it("says the span and snapshot checks could not run when the run kept no evidence directory", () => {
    const r = record();
    const report = checkRun({ events: r.events, evidenceDir: undefined, malformedLines: 0, record: folded(r.events), question: QUESTION });
    expect(statusOf(report, "snapshots")).toBe("warn");
    expect(statusOf(report, "spans")).toBe("warn");
    expect(report.ok).toBe(true);
  });

  it("ignores the checks a finished run attached to itself", () => {
    const r = record();
    const first = run(r);
    resultOf(r).checks = first;
    expect(run(r)).toEqual(first);
  });
});

describe("loadRunDir", () => {
  it("reads events.ndjson and the evidence directory of a run directory", () => {
    const r = record();
    writeFileSync(join(r.runDir, "events.ndjson"), r.events.map((e) => JSON.stringify(e)).join("\n") + "\n");
    writeJsonAtomic(join(r.runDir, "run.json"), folded(r.events));
    const loaded = loadRunDir(r.runDir);
    expect(loaded.events).toHaveLength(r.events.length);
    expect(loaded.evidenceDir).toBe(join(r.runDir, "evidence"));
    expect(loaded.malformedLines).toBe(0);
    expect(loaded.record?.id).toBe("r1");
    expect(failing(checkRun(loaded))).toEqual([]);
  });

  it("reads the question two levels above a run in the brain layout", () => {
    const r = record();
    storeRecord(r);
    const loaded = loadRunDir(join(r.runDir, "questions", "q1", "runs", "r1"));
    expect(loaded.question?.title).toBe("When does the AI Act apply to GPAI models");
  });

  it("fails a run directory the engine wrote no record into", () => {
    const r = record();
    writeFileSync(join(r.runDir, "events.ndjson"), r.events.map((e) => JSON.stringify(e)).join("\n") + "\n");
    const report = checkRun(loadRunDir(r.runDir));
    expect(failing(report)).toEqual(["record"]);
    expect(report.results.find((x) => x.id === "record")?.detail).toBe("the run directory holds no run.json");
  });

  it("warns, not fails, on a dangling marker the engine stripped and flagged", () => {
    const r = record({ mutate: (x) => { resultOf(x).stripped_markers = [{ angle_id: "a1", marker: "a1c17" }]; } });
    const report = run(r);
    expect(statusOf(report, "markers")).toBe("warn");
    expect(report.results.find((x) => x.id === "markers")?.detail).toContain("[^a1c17] in a1");
    expect(report.ok).toBe(true);
  });

  it("counts a line that is not JSON instead of dropping it silently", () => {
    const r = record();
    writeFileSync(join(r.runDir, "events.ndjson"), r.events.map((e) => JSON.stringify(e)).join("\n") + "\nnot json\n");
    const loaded = loadRunDir(r.runDir);
    expect(loaded.malformedLines).toBe(1);
    expect(failing(checkRun(loaded))).toContain("stream");
  });

  it("reports a run directory with no events.ndjson as a failed stream", () => {
    const dir = mkdtempSync(join(tmpdir(), "check-empty-"));
    const report = checkRun(loadRunDir(dir));
    expect(report.ok).toBe(false);
    expect(failing(report)).toContain("stream");
  });
});

describe("formatReport", () => {
  it("lists every check with its verdict and ends with a one-line total", () => {
    const text = formatReport(run(record()));
    expect(text).toMatch(/^PASS +stamp/m);
    expect(text.trimEnd().split("\n").at(-1)).toMatch(/^check: \d+ passed, 0 failed/);
  });
});

describe("summarizeRun", () => {
  it("reads the one-line summary off the record when there is one", () => {
    const r = record();
    const recorded = folded(r.events);
    const summary = summarizeRun({ events: r.events, evidenceDir: undefined, malformedLines: 0, record: recorded });
    expect(summary).toMatchObject({
      build: "abc1234", protocol: PROTOCOL_VERSION, status: "complete", grounding: "captured", total_cost_usd: 0.25,
      documents: 1, claims_checked: 1, validation: "validated", refusal: null, trust_level: recorded.stats.trust_level,
      sources_cited: recorded.stats.sources_cited, sources_read: recorded.stats.sources_read, stripped_markers: 0,
    });
  });

  it("falls back to the event stream when the run wrote no record", () => {
    const r = record();
    const summary = summarizeRun({ events: r.events, evidenceDir: undefined, malformedLines: 0 });
    expect(summary).toMatchObject({ build: "abc1234", status: "complete", documents: 1, trust_level: null });
  });
});

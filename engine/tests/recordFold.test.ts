import { describe, expect, it } from "vitest";
import { RecordFold } from "../src/record/build.js";
import { RunRecordSchema } from "../src/record/schema.js";
import { computeStats } from "../src/record/stats.js";
import { matchFixture } from "./fixtureSupport.js";
import { FOLD_CONTEXT, fixtureEvents, foldFixture } from "./recordSupport.js";

function event(type: string, fields: Record<string, unknown> = {}): any {
  return { type, ...fields };
}

const DOC_A = { source_id: "sa", url: "https://www.vendor-a.test/a", title: "A", content_type: "html", fetched_at: null,
  snapshot_path: "sources/sa.md", original_path: null, text_length: 40, byte_size: 40, page_offsets: [], capture: "ok", source_type: "vendor" };
const DOC_B = { ...DOC_A, source_id: "sb", url: "https://vendor-b.test/b", snapshot_path: "sources/sb.md" };
const DOC_GOV = { ...DOC_A, source_id: "sg", url: "https://eur-lex.europa.eu/x", snapshot_path: "sources/sg.md", source_type: "primary" };

function cite(id: string, source: string, match = "exact"): Record<string, unknown> {
  return { id, source_id: source, quote: `quote ${id}`, start: 0, end: 5, match };
}

function syntheticRun(answer: string, verdicts: any[], options: { grounding?: string; holds?: boolean } = {}): any[] {
  return [
    event("run_start", { protocol_version: 4, engine_version: "0.1.0", build: "b1", grounding: options.grounding ?? "captured" }),
    event("phase", { phase: "planning" }),
    event("result", { angle_id: "planning", total_cost_usd: 0.05 }),
    event("plan", { angles: [{ angle_id: "a1", title: "One", prompt: "p1" }] }),
    event("angle_status", { angle_id: "a1", status: "running" }),
    event("document", { angle_id: "a1", document: DOC_A }),
    event("document", { angle_id: "a1", document: DOC_B }),
    event("document", { angle_id: "a1", document: DOC_GOV }),
    event("topic_result", { angle_id: "a1", role: "research", status: "complete", backend: "cli", model: "m",
      session_id: "s1", note: null, usage: { cost_usd: 0.2 },
      result: "Angle prose.[^a1c1]\n\n```json\n{\"headline\":\"H1\",\"findings\":[{\"claim\":\"F\",\"confidence\":\"high\",\"sources\":[\"u\"],\"citations\":[\"a1c1\"]}]}\n```",
      citations: [cite("a1c1", "sa"), cite("a1c2", "sb"), cite("a1c3", "sg"), cite("a1c4", "sb", "unresolved")] }),
    event("angle_status", { angle_id: "synthesis", status: "running" }),
    event("topic_result", { angle_id: "synthesis", role: "synthesis", status: "complete", backend: "cli", model: "m",
      session_id: "s2", note: null, usage: { cost_usd: 0.1 },
      result: `${answer}\n\n## Validation\n\nfiled\n\n\`\`\`json\n{"headline":"The lead","findings":[],"conflicts":[{"claim":"C","positions":["x","y"]}],"gaps":["G"]}\n\`\`\``,
      citations: [] }),
    event("run_result", { status: "complete", grounding: options.grounding ?? "captured", total_cost_usd: 0.5,
      topics: [], documents: [DOC_A, DOC_B, DOC_GOV], capture_failures: [],
      validation: { status: "validated", holds: options.holds ?? true, blocking: 0, spend_usd: 0.15,
        objections_admitted: 0, objections_resolved: 0,
        objections_outstanding: [{ lens: "coverage", statement: "S", severity: "minor", followup: "find the thing now" }],
        unsupported_citations: [],
        rounds: [{ round: 1, sweep: options.grounding === "none" ? "skipped" : "run", critics: "run", claims_found: verdicts.length,
          claims_checked: verdicts.length, verdicts, objections: [], discarded_objections: 0, holds: true }] } }),
  ];
}

describe("RecordFold", () => {
  it("folds a recorded validated run into a record the schema accepts", () => {
    const record = foldFixture("run-validated-transcript.ndjson");
    expect(RunRecordSchema.safeParse(record).success).toBe(true);
    expect(record.tasks.map((t) => t.id)).toEqual(["a1", "a2", "synthesis", "x1", "synthesis.r2"]);
    expect(record.answer?.task_id).toBe("synthesis.r2");
    expect(record.status).toBe("complete");
    expect(record.pipeline.build).toBe("source");
    expect(record.tasks.find((t) => t.id === "x1")?.kind).toBe("objection");
  });

  it("matches the recorded record of the validated run", () => {
    matchFixture("record/validated.run.json", JSON.stringify(foldFixture("run-validated-transcript.ndjson"), null, 2) + "\n");
  });

  it("matches the recorded record of the multi-round mock run", () => {
    matchFixture("record/mock-run.run.json", JSON.stringify(foldFixture("mock-run.ndjson"), null, 2) + "\n");
  });

  it("takes the reconciliation as the answer of a reconciled dive", () => {
    const record = foldFixture("run-reconciled-transcript.ndjson");
    expect(record.answer?.task_id).toBe("reconciliation");
    expect(record.answer?.markdown.startsWith("CURRENTANSWER")).toBe(true);
  });

  it("is a valid running record before the run reports", () => {
    const events = fixtureEvents("run-validated-transcript.ndjson");
    const fold = new RecordFold(FOLD_CONTEXT);
    for (const e of events.slice(0, 12)) fold.apply(e, "2026-10-09T10:00:05.000Z");
    const record = fold.snapshot();
    expect(RunRecordSchema.safeParse(record).success).toBe(true);
    expect(record.status).toBe("running");
    expect(record.finished_at).toBeUndefined();
    expect(record.stats.duration_s).toBe(5);
  });

  it("strips the stream appendices from the answer and keeps the lead", () => {
    const record = foldFixture("x", syntheticRun("The answer.[^a1c1]", []));
    expect(record.answer).toEqual({ format: "markdown", task_id: "synthesis", headline: "The lead", markdown: "The answer.[^a1c1]" });
    expect(record.conflicts).toEqual([{ id: "cf1", statement: "C", positions: ["x", "y"], status: "open", task_id: "synthesis" }]);
    expect(record.gaps).toEqual([{ id: "g1", text: "G", task_id: "synthesis" }]);
    expect(record.open_items).toEqual({ conflicts: ["cf1"], objections: ["o1"], gaps: ["g1"], failed_tasks: [] });
  });

  it("calls a supported claim solid only on two independent sources or a primary one", () => {
    const answer = "One vendor says so.[^a1c1] Two vendors agree.[^a1c1][^a1c2] The regulator says so.[^a1c3] Nobody checked this.[^a1c4]";
    const supported = (claim: string) => ({ claim_id: "k", claim, verdict: "supported" });
    const record = foldFixture("x", syntheticRun(answer, [
      supported("One vendor says so."), supported("Two vendors agree."), supported("The regulator says so."),
    ]));
    expect(record.claims.map((c) => [c.text, c.strength, c.confidence, c.verdict.verdict])).toEqual([
      ["One vendor says so.", "shaky", "medium", "supported"],
      ["Two vendors agree.", "solid", "high", "supported"],
      ["The regulator says so.", "solid", "high", "supported"],
      ["Nobody checked this.", "shaky", "unverified", "unjudged"],
    ]);
  });

  it("carries a sweep's verdict and reason onto the claim", () => {
    const record = foldFixture("x", syntheticRun("Wrong figure.[^a1c1]", [
      { claim_id: "k1", claim: "Wrong figure.", verdict: "misquoted", severity: "blocking", reason: "says 5%" },
    ]));
    expect(record.claims[0]?.verdict).toEqual({ verdict: "misquoted", severity: "blocking", reason: "says 5%" });
    expect(record.claims[0]?.confidence).toBe("low");
  });

  it("counts sources once, by type, read and cited", () => {
    const record = foldFixture("x", syntheticRun("Two vendors agree.[^a1c1][^a1c2]", []));
    expect(record.stats.sources_read).toBe(3);
    expect(record.stats.sources_by_type).toEqual({ primary: 1, vendor: 2, seo: 0, academic: 0, news: 0 });
    expect(record.stats.sources_cited).toBe(2);
    expect(record.sources.filter((s) => s.cited).map((s) => s.id)).toEqual(["sa", "sb"]);
    expect(record.sources.find((s) => s.id === "sa")).toMatchObject({ host: "vendor-a.test", read_by: ["a1"] });
  });

  it("reads trust as unchecked when nothing was captured", () => {
    const record = foldFixture("x", syntheticRun("Claim.[^a1c1]", [], { grounding: "none" }));
    expect(record.stats.trust_level).toBe("unchecked");
  });

  it("reads trust as shaky when the answer does not hold", () => {
    const record = foldFixture("x", syntheticRun("Two vendors agree.[^a1c1][^a1c2]",
      [{ claim_id: "k1", claim: "Two vendors agree.", verdict: "supported" }], { holds: false }));
    expect(record.stats.trust_level).toBe("shaky");
  });

  it("reads trust as solid when every claim is solid and the answer holds", () => {
    const record = foldFixture("x", syntheticRun("Two vendors agree.[^a1c1][^a1c2]",
      [{ claim_id: "k1", claim: "Two vendors agree.", verdict: "supported" }]));
    expect(record.stats.trust_level).toBe("solid");
  });

  it("splits cost by role, with planning as what the tasks do not explain", () => {
    const record = foldFixture("x", syntheticRun("A.[^a1c1]", []));
    expect(record.cost).toEqual({ usd: 0.5, by_role: { plan: 0.05, research: 0.2, synthesis: 0.1, verify: 0, validate: 0.15 } });
    expect(record.tasks.find((t) => t.kind === "plan")?.cost_usd).toBe(0.05);
  });

  it("stores stats that recompute from the record", () => {
    const record = foldFixture("mock-run.ndjson");
    const { stats, checks, ...rest } = record;
    expect(computeStats(rest)).toEqual(stats);
  });

  it("names each task's transcript after the node its stream lines carry", () => {
    const record = foldFixture("x", syntheticRun("A.[^a1c1]", []));
    expect(record.tasks.find((t) => t.id === "a1")?.transcript).toBe("transcripts/a1.ndjson");
  });

  it("files the markers the engine stripped against the task that wrote them", () => {
    const events = syntheticRun("A.[^a1c1]", []);
    events.at(-1).stripped_markers = [{ angle_id: "a1", marker: "a1c17" }];
    expect(foldFixture("x", events).stripped_markers).toEqual([{ task_id: "a1", marker: "a1c17" }]);
  });
});

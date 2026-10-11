import { describe, expect, it } from "vitest";
import { RecordFold } from "../src/record/build.js";
import { RunRecordSchema } from "../src/record/schema.js";
import { computeStats } from "../src/record/stats.js";
import { FOLD_CONTEXT } from "./recordSupport.js";

const at = (seconds: number) => new Date(Date.parse("2026-10-09T10:00:00.000Z") + seconds * 1000).toISOString();

function finishedRun(result: Record<string, unknown>, context = {}): ReturnType<RecordFold["snapshot"]> {
  const fold = new RecordFold({ ...FOLD_CONTEXT, ...context });
  fold.apply({ type: "run_start", protocol_version: 5, engine_version: "0.1.0", build: "b1", grounding: "captured" }, at(0));
  fold.apply({ type: "phase", phase: "planning" }, at(0));
  fold.apply({ type: "phase", phase: "researching" }, at(5));
  fold.apply({ type: "phase", phase: "synthesizing" }, at(65));
  fold.apply({ type: "phase", phase: "grounding" }, at(120));
  fold.apply({ type: "phase", phase: "validating" }, at(125));
  fold.apply({ type: "phase", phase: "done" }, at(150));
  fold.apply({ type: "run_result", total_cost_usd: 0.1, topics: [], documents: [], capture_failures: [], ...result }, at(151));
  return fold.snapshot();
}

describe("a run the wall cut short", () => {
  it("is recorded as partial, with the limit that cut it", () => {
    const record = finishedRun({ status: "partial", wall_hit: "hard", note: "The 4:30 time limit cut this run short." });

    expect(record.status).toBe("partial");
    expect(record.status_note).toBe("The 4:30 time limit cut this run short.");
    expect(record.limits.wall_hit).toBe("hard");
    expect(record.stats.partial).toBe(true);
    expect(RunRecordSchema.safeParse(record).success).toBe(true);
  });

  it("marks a wind-down as the wall that was hit", () => {
    expect(finishedRun({ status: "partial", wall_hit: "wind_down" }).limits.wall_hit).toBe("wind_down");
  });

  it("is not partial when the run finished in time", () => {
    const record = finishedRun({ status: "complete", wall_hit: "none" });

    expect(record.status).toBe("complete");
    expect(record.stats.partial).toBe(false);
    expect(record.limits.wall_hit).toBe("none");
  });

  it("leaves a run from before tiers with no wall to report", () => {
    const record = finishedRun({ status: "complete" });
    expect(record.limits.wall_hit).toBeUndefined();
    expect(record.stats.partial).toBe(false);
  });

  it("keeps stats recomputable from the record", () => {
    const { stats, checks, ...rest } = finishedRun({ status: "partial", wall_hit: "hard" });
    expect(computeStats(rest)).toEqual(stats);
  });
});

describe("how long each stage took", () => {
  it("sums the time between phase changes into the user's four stages", () => {
    const record = finishedRun({ status: "complete" });

    expect(record.stats.stage_s).toEqual({ research: 65, draft: 55, check: 30, answer: 1 });
  });

  it("holds the last phase until the run finished", () => {
    const fold = new RecordFold(FOLD_CONTEXT);
    fold.apply({ type: "phase", phase: "researching" }, at(0));
    fold.apply({ type: "run_result", status: "inconclusive", topics: [], documents: [], capture_failures: [] }, at(40));

    expect(fold.snapshot().stats.stage_s).toEqual({ research: 40, draft: 0, check: 0, answer: 0 });
  });

  it("counts a second round's research against research again", () => {
    const fold = new RecordFold(FOLD_CONTEXT);
    fold.apply({ type: "phase", phase: "researching" }, at(0));
    fold.apply({ type: "phase", phase: "synthesizing" }, at(10));
    fold.apply({ type: "phase", phase: "validating" }, at(20));
    fold.apply({ type: "phase", phase: "researching" }, at(30));
    fold.apply({ type: "phase", phase: "done" }, at(50));
    fold.apply({ type: "run_result", status: "complete", topics: [], documents: [], capture_failures: [] }, at(50));

    expect(fold.snapshot().stats.stage_s).toMatchObject({ research: 30, draft: 10, check: 10 });
  });
});

describe("a run that belongs to a thread", () => {
  it("records its kind and the run it came from", () => {
    const record = finishedRun({ status: "complete" }, { kind: "rerun", parentRunId: "01K7A0000000000000000RUN00" });

    expect(record.kind).toBe("rerun");
    expect(record.parent_run_id).toBe("01K7A0000000000000000RUN00");
    expect(RunRecordSchema.safeParse(record).success).toBe(true);
  });

  it("has no parent for the first run of a question", () => {
    expect("parent_run_id" in finishedRun({ status: "complete" })).toBe(false);
  });
});

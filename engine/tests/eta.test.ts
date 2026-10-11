import { describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stageMedians } from "../src/eta.js";
import { TIER_RECIPES } from "../src/tiers.js";
import { Emitter } from "../src/emitter.js";
import { RunLiveness } from "../src/liveness.js";

function storeWith(runs: { tier: string; status: string; at: string; stage_s?: Record<string, number> }[]): string {
  const store = mkdtempSync(join(tmpdir(), "quorum-eta-"));
  runs.forEach((run, index) => {
    const dir = join(store, "questions", `Q${index}`, "runs", `R${index}`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(store, "questions", `Q${index}`, "question.json"), "{}");
    writeFileSync(join(dir, "run.json"), JSON.stringify({
      created_at: run.at, status: run.status, brief: { tier: run.tier }, stats: run.stage_s ? { stage_s: run.stage_s } : {},
    }));
  });
  return store;
}

const stages = (research: number, draft = 10, check = 10, answer = 1) => ({ research, draft, check, answer });
const FALLBACK = TIER_RECIPES.quick.stageEstimateSec;

describe("the typical duration of each stage, from past runs", () => {
  it("falls back to the tier's own estimate when the store has no history", () => {
    expect(stageMedians(mkdtempSync(join(tmpdir(), "quorum-eta-")), "quick", FALLBACK)).toEqual(FALLBACK);
  });

  it("is the median of the same tier's finished runs, stage by stage", () => {
    const store = storeWith([
      { tier: "quick", status: "complete", at: "2026-10-01T00:00:00Z", stage_s: stages(100, 20) },
      { tier: "quick", status: "complete", at: "2026-10-02T00:00:00Z", stage_s: stages(140, 40) },
      { tier: "quick", status: "complete", at: "2026-10-03T00:00:00Z", stage_s: stages(120, 30) },
    ]);
    expect(stageMedians(store, "quick", FALLBACK)).toEqual({ research: 120, draft: 30, check: 10, answer: 1 });
  });

  it("averages the middle two of an even count", () => {
    const store = storeWith([
      { tier: "quick", status: "complete", at: "2026-10-01T00:00:00Z", stage_s: stages(100) },
      { tier: "quick", status: "complete", at: "2026-10-02T00:00:00Z", stage_s: stages(140) },
    ]);
    expect(stageMedians(store, "quick", FALLBACK).research).toBe(120);
  });

  it("ignores another tier's runs, runs that did not finish, and records from before durations were kept", () => {
    const store = storeWith([
      { tier: "deep", status: "complete", at: "2026-10-01T00:00:00Z", stage_s: stages(900) },
      { tier: "quick", status: "halted", at: "2026-10-02T00:00:00Z", stage_s: stages(5) },
      { tier: "quick", status: "crashed", at: "2026-10-03T00:00:00Z", stage_s: stages(7) },
      { tier: "quick", status: "complete", at: "2026-10-04T00:00:00Z" },
    ]);
    expect(stageMedians(store, "quick", FALLBACK)).toEqual(FALLBACK);
  });

  it("looks only at the most recent runs, so it follows the engine as it changes", () => {
    const old = Array.from({ length: 9 }, (_, i) => ({ tier: "quick", status: "complete", at: `2026-09-0${i + 1}T00:00:00Z`, stage_s: stages(300) }));
    const recent = Array.from({ length: 9 }, (_, i) => ({ tier: "quick", status: "complete", at: `2026-10-0${i + 1}T00:00:00Z`, stage_s: stages(100) }));
    expect(stageMedians(storeWith([...old, ...recent]), "quick", FALLBACK).research).toBe(100);
  });
});

describe("the history the estimate is read from", () => {
  it("counts a run the wall cut short: its durations are real", () => {
    const store = storeWith([
      { tier: "quick", status: "partial", at: "2026-10-01T00:00:00Z", stage_s: stages(140) },
      { tier: "quick", status: "complete", at: "2026-10-02T00:00:00Z", stage_s: stages(100) },
    ]);
    expect(stageMedians(store, "quick", FALLBACK).research).toBe(120);
  });

  it("skips a duration that is not a finite number, rather than let it poison the median", () => {
    const store = storeWith([
      { tier: "quick", status: "complete", at: "2026-10-01T00:00:00Z", stage_s: { research: "soon", draft: null, check: 10, answer: 1 } as any },
      { tier: "quick", status: "complete", at: "2026-10-02T00:00:00Z", stage_s: stages(100, 20) },
    ]);
    const medians = stageMedians(store, "quick", FALLBACK);
    expect(medians).toEqual({ research: 100, draft: 20, check: 10, answer: 1 });
    expect(Object.values(medians).every(Number.isFinite)).toBe(true);
  });

  it("uses the fallback for a stage that no run measured", () => {
    const store = storeWith([{ tier: "quick", status: "complete", at: "2026-10-01T00:00:00Z", stage_s: { research: 90 } as any }]);
    expect(stageMedians(store, "quick", FALLBACK)).toEqual({ ...FALLBACK, research: 90 });
  });

  it("reads only the files touched most recently, so a long history never costs the run its time", () => {
    const store = storeWith([
      ...Array.from({ length: 5 }, (_, i) => ({ tier: "quick", status: "complete", at: `2026-09-0${i + 1}T00:00:00Z`, stage_s: stages(900) })),
      ...Array.from({ length: 3 }, (_, i) => ({ tier: "quick", status: "complete", at: `2026-10-0${i + 1}T00:00:00Z`, stage_s: stages(100) })),
    ]);
    for (let i = 0; i < 8; i += 1) {
      const when = new Date(Date.parse("2026-01-01T00:00:00Z") + (i < 5 ? 0 : 1000 * 3600) + i * 1000);
      utimesSync(join(store, "questions", `Q${i}`, "runs", `R${i}`, "run.json"), when, when);
    }
    expect(stageMedians(store, "quick", FALLBACK, { scanLimit: 3 }).research).toBe(100);
  });
});

describe("progress events with an estimate", () => {
  function live(clock: { now: number }) {
    const lines: any[] = [];
    const run = new RunLiveness({
      bus: new Emitter((line) => lines.push(JSON.parse(line))), pid: 1, sourcesRead: () => 0,
      now: () => clock.now, medians: { research: 100, draft: 50, check: 30, answer: 5 },
    });
    return { run, progress: () => lines.filter((l) => l.type === "run.progress") };
  }

  it("says how many seconds are left: what remains of the stage, then every stage after it", () => {
    const clock = { now: 1000 };
    const { run, progress } = live(clock);
    run.phase("researching");
    clock.now += 40_000;
    run.taskFinished();

    expect(progress().map((p) => p.eta_s)).toEqual([185, 145]);
  });

  it("restarts the stage's clock when the stage changes", () => {
    const clock = { now: 0 };
    const { run, progress } = live(clock);
    run.phase("researching");
    clock.now += 90_000;
    run.phase("synthesizing");

    expect(progress().at(-1)).toMatchObject({ stage: "draft", eta_s: 85 });
  });

  it("keeps a planning phase and a research phase in one stage clock", () => {
    const clock = { now: 0 };
    const { run, progress } = live(clock);
    run.phase("planning");
    clock.now += 20_000;
    run.phase("researching");

    expect(progress().at(-1)).toMatchObject({ stage: "research", eta_s: 165 });
  });
});

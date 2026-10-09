import { describe, it, expect, vi, afterEach } from "vitest";
import { Emitter } from "../src/emitter.js";
import { HEARTBEAT_INTERVAL_MS, RunLiveness, STAGE_COUNT, stageForPhase } from "../src/liveness.js";

afterEach(() => vi.useRealTimers());

describe("mapping the engine's phases onto the five user stages", () => {
  it("counts scope as the composer's first step and the run's phases as the other four", () => {
    expect(STAGE_COUNT).toBe(5);
    expect(stageForPhase("planning")).toEqual({ stage: "research", stage_index: 2 });
    expect(stageForPhase("researching")).toEqual({ stage: "research", stage_index: 2 });
    expect(stageForPhase("synthesizing")).toEqual({ stage: "draft", stage_index: 3 });
    expect(stageForPhase("grounding")).toEqual({ stage: "check", stage_index: 4 });
    expect(stageForPhase("validating")).toEqual({ stage: "check", stage_index: 4 });
    expect(stageForPhase("reconciling")).toEqual({ stage: "check", stage_index: 4 });
    expect(stageForPhase("done")).toEqual({ stage: "answer", stage_index: 5 });
  });

  it("has no stage for a phase it does not know", () => {
    expect(stageForPhase("awaiting_approval")).toBeUndefined();
  });
});

function liveness(overrides: { sourcesRead?: () => number } = {}) {
  const lines: any[] = [];
  const bus = new Emitter((line) => lines.push(JSON.parse(line)));
  const live = new RunLiveness({ bus, pid: 4242, sourcesRead: overrides.sourcesRead ?? (() => 0) });
  return { live, lines };
}

describe("progress events", () => {
  it("emits the stage, the counts and the sources read whenever the phase changes", () => {
    let sources = 0;
    const { live, lines } = liveness({ sourcesRead: () => sources });
    live.phase("planning");
    live.taskQueued();
    live.taskQueued();
    live.phase("researching");
    sources = 3;
    live.taskFinished();
    live.phase("synthesizing");

    const progress = lines.filter((l) => l.type === "run.progress");
    expect(progress.map((p) => p.stage)).toEqual(["research", "research", "research", "draft"]);
    expect(progress.at(-1)).toMatchObject({
      type: "run.progress", stage: "draft", stage_index: 3, stage_count: 5, tasks_done: 1, tasks_total: 2, sources_read: 3,
    });
  });

  it("emits the phase line the record folds, then the progress for it", () => {
    const { live, lines } = liveness();
    live.phase("validating");

    expect(lines.map((l) => l.type)).toEqual(["phase", "run.progress"]);
    expect(lines[0]).toEqual({ type: "phase", phase: "validating" });
  });

  it("emits a progress line when a task finishes, so a watcher sees the count move", () => {
    const { live, lines } = liveness();
    live.phase("researching");
    live.taskQueued();
    lines.length = 0;
    live.taskFinished();

    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatchObject({ type: "run.progress", tasks_done: 1, tasks_total: 1 });
  });

  it("carries no eta until the engine has durations from past runs to estimate from", () => {
    const { live, lines } = liveness();
    live.phase("researching");

    expect("eta_s" in lines.find((l) => l.type === "run.progress")).toBe(false);
  });
});

describe("heartbeat", () => {
  it("beats every five seconds with the engine's pid and restates the progress", () => {
    vi.useFakeTimers();
    const { live, lines } = liveness();
    live.phase("researching");
    lines.length = 0;
    live.start();
    vi.advanceTimersByTime(HEARTBEAT_INTERVAL_MS * 2);
    live.stop();

    expect(HEARTBEAT_INTERVAL_MS).toBe(5000);
    expect(lines.filter((l) => l.type === "heartbeat")).toEqual([
      { type: "heartbeat", pid: 4242 }, { type: "heartbeat", pid: 4242 },
    ]);
    expect(lines.filter((l) => l.type === "run.progress")).toHaveLength(2);
  });

  it("does not beat without a process to speak for, as in a run driven from a test", () => {
    vi.useFakeTimers();
    const lines: any[] = [];
    const live = new RunLiveness({ bus: new Emitter((line) => lines.push(JSON.parse(line))), sourcesRead: () => 0 });
    live.start();
    vi.advanceTimersByTime(HEARTBEAT_INTERVAL_MS * 3);

    expect(lines).toEqual([]);
  });

  it("stops beating once the run is over", () => {
    vi.useFakeTimers();
    const { live, lines } = liveness();
    live.start();
    live.stop();
    vi.advanceTimersByTime(HEARTBEAT_INTERVAL_MS * 3);

    expect(lines).toEqual([]);
  });
});

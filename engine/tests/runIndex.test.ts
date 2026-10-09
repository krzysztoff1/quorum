import { describe, expect, it } from "vitest";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { listRuns, STALE_HEARTBEAT_MS, VANISHED_HEARTBEAT_MS } from "../src/runIndex.js";
import { emptyStore, seedRun, STORE_NOW } from "./storeSupport.js";

const alive = (...pids: number[]) => (pid: number) => pids.includes(pid);
const isoAgo = (ms: number) => new Date(STORE_NOW - ms).toISOString();

function list(store: string, living: number[] = []) {
  return listRuns(store, { now: () => STORE_NOW, isAlive: alive(...living) });
}

describe("quorum-engine list", () => {
  it("has nothing to say about a store that does not exist yet", () => {
    expect(list("/no/such/quorum/store")).toEqual([]);
  });

  it("gives one index line per run, newest first, with the question's title", () => {
    const store = emptyStore();
    seedRun(store, { questionId: "Q1", runId: "R1", title: "First", createdAt: "2026-10-10T08:00:00.000Z", status: "complete" });
    seedRun(store, { questionId: "Q2", runId: "R2", title: "Second", createdAt: "2026-10-10T09:00:00.000Z", status: "inconclusive" });

    const lines = list(store);

    expect(lines.map((l) => [l.run_id, l.title, l.status])).toEqual([["R2", "Second", "inconclusive"], ["R1", "First", "complete"]]);
    expect(lines[0]).toMatchObject({ type: "run", question_id: "Q2", dir: expect.stringContaining(join("questions", "Q2", "runs", "R2")) });
  });

  it("reports a live run as running with its pid and last heartbeat", () => {
    const store = emptyStore();
    seedRun(store, { pid: 777, heartbeatAt: isoAgo(2_000) });

    expect(list(store, [777])[0]).toMatchObject({ status: "running", pid: 777, heartbeat_at: isoAgo(2_000) });
  });

  it("calls a run whose heartbeat went stale and whose process is gone crashed", () => {
    const store = emptyStore();
    seedRun(store, { pid: 777, heartbeatAt: isoAgo(STALE_HEARTBEAT_MS + 1_000) });

    expect(list(store, [])[0]).toMatchObject({ status: "crashed" });
  });

  it("keeps a run running when the process is alive even if one heartbeat was late", () => {
    const store = emptyStore();
    seedRun(store, { pid: 777, heartbeatAt: isoAgo(STALE_HEARTBEAT_MS + 1_000) });

    expect(list(store, [777])[0]).toMatchObject({ status: "running" });
  });

  it("keeps a run running when its process is gone but the heartbeat is fresh, since the finish is still being written", () => {
    const store = emptyStore();
    seedRun(store, { pid: 777, heartbeatAt: isoAgo(3_000) });

    expect(list(store, [])[0]).toMatchObject({ status: "running" });
  });

  it("does not trust a live pid when the heartbeat stopped long ago, because the number may belong to another process now", () => {
    const store = emptyStore();
    seedRun(store, { pid: 777, heartbeatAt: isoAgo(VANISHED_HEARTBEAT_MS + 1_000) });

    expect(list(store, [777])[0]).toMatchObject({ status: "crashed" });
  });

  it("falls back to the record's own update time for a run written before heartbeats existed", () => {
    const store = emptyStore();
    seedRun(store, { runId: "OLD", heartbeatAt: undefined, createdAt: isoAgo(3_600_000) });
    seedRun(store, { questionId: "Q2", runId: "NEW", createdAt: isoAgo(2_000) });

    const byRun = Object.fromEntries(list(store).map((l) => [l.run_id, l.status]));
    expect(byRun).toEqual({ OLD: "crashed", NEW: "running" });
  });

  it("writes the crash into the record so every reader agrees, and halts the tasks that never finished", () => {
    const store = emptyStore();
    const { runDir } = seedRun(store, { pid: 777, heartbeatAt: isoAgo(STALE_HEARTBEAT_MS + 1_000) });

    list(store);
    const record = JSON.parse(readFileSync(join(runDir, "run.json"), "utf8"));

    expect(record.status).toBe("crashed");
    expect(record.status_note).toMatch(/stopped without finishing/);
    expect(record.finished_at).toBe(new Date(STORE_NOW).toISOString());
    expect(record.tasks.every((t: any) => t.status !== "running")).toBe(true);
  });

  it("never touches a finished run", () => {
    const store = emptyStore();
    const { runDir } = seedRun(store, { status: "complete", pid: 1, heartbeatAt: isoAgo(86_400_000) });
    const before = readFileSync(join(runDir, "run.json"), "utf8");

    expect(list(store)[0]).toMatchObject({ status: "complete" });
    expect(readFileSync(join(runDir, "run.json"), "utf8")).toBe(before);
  });

  it("skips a directory whose record cannot be read, instead of failing the whole list", () => {
    const store = emptyStore();
    seedRun(store, { runId: "GOOD", status: "complete" });
    const broken = seedRun(store, { questionId: "Q2", runId: "BAD", status: "complete" });
    writeFileSync(join(broken.runDir, "run.json"), "{ not json");

    expect(list(store).map((l) => l.run_id)).toEqual(["GOOD"]);
  });
});

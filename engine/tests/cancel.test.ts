import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { cancelRun, type CancelDeps } from "../src/cancel.js";
import { emptyStore, seedRun, STORE_NOW } from "./storeSupport.js";

function deps(overrides: Partial<CancelDeps> = {}): CancelDeps & { signals: Array<[number, string]> } {
  const signals: Array<[number, string]> = [];
  return {
    now: () => STORE_NOW,
    isAlive: () => true,
    signal: (pid, name) => { signals.push([pid, name]); },
    signals,
    ...overrides,
  };
}

const fresh = new Date(STORE_NOW - 2_000).toISOString();

describe("quorum-engine cancel", () => {
  it("signals the run's whole process group, so the CLI children wind down with the engine", () => {
    const store = emptyStore();
    seedRun(store, { runId: "R1", pid: 4242, heartbeatAt: fresh });
    const d = deps();

    expect(cancelRun(store, "R1", d)).toEqual({ ok: true, run_id: "R1", signalled: "group" });
    expect(d.signals).toEqual([[-4242, "SIGTERM"]]);
  });

  it("signals the process alone when the engine is not a group leader, which is a run its caller attached to", () => {
    const store = emptyStore();
    seedRun(store, { runId: "R1", pid: 4242, heartbeatAt: fresh });
    const d = deps({
      signal: (pid, name) => {
        d.signals.push([pid, name]);
        if (pid < 0) throw Object.assign(new Error("no such process group"), { code: "ESRCH" });
      },
    });

    expect(cancelRun(store, "R1", d)).toEqual({ ok: true, run_id: "R1", signalled: "process" });
    expect(d.signals).toEqual([[-4242, "SIGTERM"], [4242, "SIGTERM"]]);
  });

  it("leaves the record to the engine's graceful wind-down while the process lives", () => {
    const store = emptyStore();
    const { runDir } = seedRun(store, { runId: "R1", pid: 4242, heartbeatAt: fresh });
    cancelRun(store, "R1", deps());

    expect(JSON.parse(readFileSync(join(runDir, "run.json"), "utf8")).status).toBe("running");
  });

  it("marks a run cancelled itself when the engine is already gone, so nothing shows running forever", () => {
    const store = emptyStore();
    const { runDir } = seedRun(store, { runId: "R1", pid: 4242, heartbeatAt: new Date(STORE_NOW - 3_600_000).toISOString() });
    const d = deps({ isAlive: () => false });

    expect(cancelRun(store, "R1", d)).toEqual({ ok: true, run_id: "R1", signalled: "none" });
    const record = JSON.parse(readFileSync(join(runDir, "run.json"), "utf8"));
    expect(record).toMatchObject({ status: "cancelled", finished_at: new Date(STORE_NOW).toISOString() });
    expect(record.status_note).toMatch(/cancelled/i);
    expect(d.signals).toEqual([]);
  });

  it("refuses to cancel a run that already finished, and says what it finished as", () => {
    const store = emptyStore();
    seedRun(store, { runId: "R1", status: "complete" });

    expect(cancelRun(store, "R1", deps())).toEqual({ ok: false, run_id: "R1", error: "the run already finished as complete" });
  });

  it("names a run it cannot find", () => {
    expect(cancelRun(emptyStore(), "NOPE", deps())).toEqual({ ok: false, run_id: "NOPE", error: "no run NOPE in this store" });
  });
});

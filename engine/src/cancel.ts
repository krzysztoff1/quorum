import { join } from "node:path";
import { RUN_FILE, writeJsonAtomic } from "./record/store.js";
import { findRun } from "./runStore.js";

export interface CancelDeps {
  now: () => number;
  isAlive: (pid: number) => boolean;
  signal: (pid: number, name: NodeJS.Signals) => void;
}

export type CancelResult =
  | { ok: true; run_id: string; signalled: "group" | "process" | "none" }
  | { ok: false; run_id: string; error: string };

export function cancelRun(storeDir: string, runId: string, deps: CancelDeps): CancelResult {
  const entry = findRun(storeDir, runId);
  if (!entry?.record) return { ok: false, run_id: runId, error: `no run ${runId} in this store` };
  const record = entry.record;
  if (record.status !== "running") {
    return { ok: false, run_id: runId, error: `the run already finished as ${record.status}` };
  }
  const pid: unknown = record.pipeline?.pid;
  if (Number.isInteger(pid) && deps.isAlive(pid as number)) {
    return { ok: true, run_id: runId, signalled: terminate(pid as number, deps) };
  }
  const at = new Date(deps.now()).toISOString();
  writeJsonAtomic(join(entry.runDir, RUN_FILE), {
    ...record,
    status: "cancelled",
    status_note: "The run was cancelled after its engine had already stopped.",
    updated_at: at,
    finished_at: at,
    tasks: (record.tasks ?? []).map((task: any) => (task.status === "running" ? { ...task, status: "halted" } : task)),
  });
  return { ok: true, run_id: runId, signalled: "none" };
}

function terminate(pid: number, deps: CancelDeps): "group" | "process" {
  try {
    deps.signal(-pid, "SIGTERM");
    return "group";
  } catch {
    deps.signal(pid, "SIGTERM");
    return "process";
  }
}

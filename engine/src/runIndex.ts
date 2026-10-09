import { join } from "node:path";
import { writeJsonAtomic, RUN_FILE } from "./record/store.js";
import { scanStore, type StoredEntry } from "./runStore.js";

export const STALE_HEARTBEAT_MS = 30_000;
export const VANISHED_HEARTBEAT_MS = 10 * 60_000;

export interface RunIndexLine {
  type: "run";
  question_id: string;
  run_id: string;
  dir: string;
  title: string;
  status: string;
  created_at: string;
  updated_at: string;
  finished_at?: string;
  pid?: number;
  heartbeat_at?: string;
  cost_usd: number;
}

export interface IndexDeps {
  now: () => number;
  isAlive: (pid: number) => boolean;
}

export function isCrashed(record: any, deps: IndexDeps): boolean {
  if (record?.status !== "running") return false;
  const lastSeen = Date.parse(record.pipeline?.heartbeat_at ?? record.updated_at ?? record.created_at);
  const age = deps.now() - (Number.isFinite(lastSeen) ? lastSeen : 0);
  if (age > VANISHED_HEARTBEAT_MS) return true;
  const pid: unknown = record.pipeline?.pid;
  const alive = Number.isInteger(pid) && deps.isAlive(pid as number);
  return age > STALE_HEARTBEAT_MS && !alive;
}

export function markCrashed(record: any, atIso: string, lastSeen: string | undefined): any {
  const since = lastSeen ? ` (no heartbeat since ${lastSeen})` : "";
  return {
    ...record,
    status: "crashed",
    status_note: `The engine stopped without finishing${since}.`,
    updated_at: atIso,
    finished_at: atIso,
    tasks: (record.tasks ?? []).map((task: any) => (task.status === "running" ? { ...task, status: "halted" } : task)),
  };
}

export function listRuns(storeDir: string, deps: IndexDeps): RunIndexLine[] {
  const atIso = new Date(deps.now()).toISOString();
  const lines: RunIndexLine[] = [];
  for (const entry of scanStore(storeDir)) {
    if (!entry.record) continue;
    let record = entry.record;
    if (isCrashed(record, deps)) {
      record = markCrashed(record, atIso, record.pipeline?.heartbeat_at);
      writeJsonAtomic(join(entry.runDir, RUN_FILE), record);
    }
    lines.push(indexLine(entry, record));
  }
  return lines.sort((a, b) => (a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : 0));
}

function indexLine(entry: StoredEntry, record: any): RunIndexLine {
  return {
    type: "run",
    question_id: entry.questionId,
    run_id: entry.runId,
    dir: entry.runDir,
    title: String(entry.question?.title ?? ""),
    status: String(record.status),
    created_at: String(record.created_at),
    updated_at: String(record.updated_at),
    ...(record.finished_at ? { finished_at: String(record.finished_at) } : {}),
    ...(Number.isInteger(record.pipeline?.pid) ? { pid: record.pipeline.pid } : {}),
    ...(record.pipeline?.heartbeat_at ? { heartbeat_at: String(record.pipeline.heartbeat_at) } : {}),
    cost_usd: Number(record.cost?.usd ?? 0),
  };
}

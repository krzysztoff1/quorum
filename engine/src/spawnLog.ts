import { appendFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { dirname, join } from "node:path";

export interface FiledRequest {
  request_id: string;
  angle_id: string;
  question: string;
  why: string;
  provoked_by: string;
  /// `dig` means the user raised it from a node on the canvas. It still passes every gate — depth, the
  /// count cap, dedup — but it needs no approval, because the person who would approve it asked for it.
  origin?: "spawn" | "dig";
}

export const SPAWN_LOG_NAME = "spawn-requests.jsonl";

/// A Claude Code angle raises its questions inside `mcp-serve`, which is a separate process and can hand
/// them over no other way — the same constraint that put captured evidence on disk. Append-only, one JSON
/// object per line, read back by the engine once the angle finishes.
export function fileSpawnRequest(dir: string, request: Omit<FiledRequest, "request_id">): FiledRequest {
  const filed: FiledRequest = { request_id: randomUUID(), ...request };
  const path = join(dir, SPAWN_LOG_NAME);
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, JSON.stringify(filed) + "\n", "utf8");
  return filed;
}

export function readSpawnRequests(dir: string): FiledRequest[] {
  const path = join(dir, SPAWN_LOG_NAME);
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => {
      try {
        return JSON.parse(line) as FiledRequest;
      } catch {
        return undefined;
      }
    })
    .filter((r): r is FiledRequest => Boolean(r?.request_id && r.angle_id && r.question));
}

/// Requests this run has not already ruled on. Several angles append to one file concurrently, so the
/// engine reads the whole log and filters rather than truncating it out from under a live writer.
export function unclaimedSpawnRequests(dir: string, claimed: Set<string>): FiledRequest[] {
  return readSpawnRequests(dir).filter((r) => !claimed.has(r.request_id));
}

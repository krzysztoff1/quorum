import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { writeJsonAtomic } from "./record/store.js";
import type { Refusal } from "./refusal.js";

export const RATE_LIMIT_FILE = "rate-limit.json";

const STATUSES = ["allowed", "allowed_warning", "rejected"] as const;

export interface RateLimitWindow {
  status: (typeof STATUSES)[number];
  window?: string;
  resets_at?: string;
  utilization?: number;
  observed_at: string;
}

export function windowFromMessage(message: any, observedAt: string): RateLimitWindow | undefined {
  const info = message?.rate_limit_info;
  if (message?.type !== "rate_limit_event" || !STATUSES.includes(info?.status)) return undefined;
  return {
    status: info.status,
    ...(typeof info.rateLimitType === "string" ? { window: info.rateLimitType } : {}),
    ...(Number.isFinite(info.resetsAt) ? { resets_at: new Date(info.resetsAt * 1000).toISOString() } : {}),
    ...(typeof info.utilization === "number" ? { utilization: info.utilization } : {}),
    observed_at: observedAt,
  };
}

export function isRateLimitedMessage(message: any): boolean {
  if (message?.type === "assistant") return message.error === "rate_limit";
  return message?.type === "rate_limit_event" && message.rate_limit_info?.status === "rejected";
}

export function rateLimitRefusal(window?: RateLimitWindow): Refusal {
  const which = window?.window ? `${window.window.replace(/_/g, " ")} ` : "";
  const until = window?.resets_at ? `; it resets at ${window.resets_at.slice(11, 16)} UTC` : "";
  return { kind: "rate_limited", reason: `Your Claude subscription's ${which}usage limit is reached${until}. A run now would stop partway, so none was started.` };
}

export function readRateLimit(storeDir: string): RateLimitWindow | undefined {
  const path = join(storeDir, RATE_LIMIT_FILE);
  if (!existsSync(path)) return undefined;
  try {
    const window = JSON.parse(readFileSync(path, "utf8"));
    return STATUSES.includes(window?.status) ? window : undefined;
  } catch {
    return undefined;
  }
}

export function writeRateLimit(storeDir: string, window: RateLimitWindow): void {
  writeJsonAtomic(join(storeDir, RATE_LIMIT_FILE), window);
}

export function exhaustedRefusal(window: RateLimitWindow | undefined, nowMs: number): Refusal | undefined {
  if (window?.status !== "rejected") return undefined;
  const resetsAt = window.resets_at ? Date.parse(window.resets_at) : undefined;
  return resetsAt !== undefined && resetsAt <= nowMs ? undefined : rateLimitRefusal(window);
}

export function rateLimitPreflight(storeDir: string, nowMs: number): Refusal | undefined {
  return exhaustedRefusal(readRateLimit(storeDir), nowMs);
}

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { writeJsonAtomic } from "./record/store.js";
import type { Refusal } from "./refusal.js";

export const RATE_LIMIT_FILE = "rate-limit.json";

const STATUSES = ["allowed", "allowed_warning", "rejected"] as const;
const BLOCKING_WINDOWS = new Set(["five_hour", "seven_day"]);
export const STALE_REJECTION_MS = 5 * 60 * 60 * 1000;

export interface RateLimitWindow {
  status: (typeof STATUSES)[number];
  window?: string;
  resets_at?: string;
  utilization?: number;
  overage_covers?: boolean;
  observed_at: string;
}

export function windowFromMessage(message: any, observedAt: string): RateLimitWindow | undefined {
  const info = message?.rate_limit_info;
  if (message?.type !== "rate_limit_event" || !STATUSES.includes(info?.status)) return undefined;
  const overageCovers = info.isUsingOverage === true && typeof info.overageStatus === "string" && info.overageStatus.startsWith("allowed");
  return {
    status: info.status,
    ...(typeof info.rateLimitType === "string" ? { window: info.rateLimitType } : {}),
    ...(Number.isFinite(info.resetsAt) ? { resets_at: new Date(info.resetsAt * 1000).toISOString() } : {}),
    ...(typeof info.utilization === "number" ? { utilization: info.utilization } : {}),
    ...(overageCovers ? { overage_covers: true } : {}),
    observed_at: observedAt,
  };
}

function blocks(window: RateLimitWindow): boolean {
  return window.status === "rejected" && !window.overage_covers && (window.window === undefined || BLOCKING_WINDOWS.has(window.window));
}

export function isRateLimitedMessage(message: any): boolean {
  if (message?.type === "assistant") return message.error === "rate_limit";
  const window = windowFromMessage(message, "");
  return window !== undefined && blocks(window);
}

export function rateLimitRefusal(window?: RateLimitWindow): Refusal {
  const which = window?.window ? `${window.window.replace(/_/g, " ")} ` : "";
  const until = window?.resets_at ? `; it resets at ${window.resets_at.slice(11, 16)} UTC` : "";
  return { kind: "rate_limited", reason: `Your Claude subscription's ${which}usage limit is reached${until}. A run now would stop partway, so none was started.` };
}

export function readRateLimits(storeDir: string): RateLimitWindow[] {
  const path = join(storeDir, RATE_LIMIT_FILE);
  if (!existsSync(path)) return [];
  try {
    const stored = JSON.parse(readFileSync(path, "utf8"));
    const windows: unknown[] = stored?.windows && typeof stored.windows === "object" ? Object.values(stored.windows) : [stored];
    return windows.filter((w): w is RateLimitWindow => STATUSES.includes((w as RateLimitWindow)?.status));
  } catch {
    return [];
  }
}

export function writeRateLimit(storeDir: string, window: RateLimitWindow): void {
  const windows = Object.fromEntries(readRateLimits(storeDir).map((w) => [w.window ?? "unknown", w]));
  const key = window.window ?? "unknown";
  const kept = windows[key];
  if (!kept || kept.observed_at <= window.observed_at) windows[key] = window;
  writeJsonAtomic(join(storeDir, RATE_LIMIT_FILE), { windows });
}

export function exhaustedRefusal(windows: RateLimitWindow[], nowMs: number): Refusal | undefined {
  const standing = windows.find((window) => {
    if (!blocks(window)) return false;
    if (window.resets_at) return Date.parse(window.resets_at) > nowMs;
    return nowMs - Date.parse(window.observed_at) < STALE_REJECTION_MS;
  });
  return standing ? rateLimitRefusal(standing) : undefined;
}

export function rateLimitPreflight(storeDir: string, nowMs: number): Refusal | undefined {
  return exhaustedRefusal(readRateLimits(storeDir), nowMs);
}

import { describe, expect, it } from "vitest";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EventEmitter } from "node:events";
import { fileURLToPath } from "node:url";
import {
  RATE_LIMIT_FILE, STALE_REJECTION_MS, isRateLimitedMessage, rateLimitPreflight, rateLimitRefusal, readRateLimits, windowFromMessage, writeRateLimit,
} from "../src/ratelimit.js";
import { runClaudeCode, type SpawnFn } from "../src/claudeCode.js";
import { Emitter } from "../src/emitter.js";

const RESETS_AT = 1_760_018_400;
const NOW = (RESETS_AT - 3600) * 1000;

const event = (info: Record<string, unknown>) => ({ type: "rate_limit_event", rate_limit_info: info });

describe("reading the CLI's rate-limit messages", () => {
  it("turns a rate_limit_event into the window it describes", () => {
    expect(windowFromMessage(event({ status: "allowed_warning", resetsAt: RESETS_AT, rateLimitType: "five_hour", utilization: 0.83 }), "2026-10-11T12:00:00.000Z"))
      .toEqual({ status: "allowed_warning", window: "five_hour", resets_at: new Date(RESETS_AT * 1000).toISOString(), utilization: 0.83, observed_at: "2026-10-11T12:00:00.000Z" });
  });

  it("reads nothing from a message that is not about rate limits, or whose info is malformed", () => {
    expect(windowFromMessage({ type: "assistant" }, "t")).toBeUndefined();
    expect(windowFromMessage(event({ status: "weird" }), "t")).toBeUndefined();
    expect(windowFromMessage({ type: "rate_limit_event" }, "t")).toBeUndefined();
  });

  it("knows when the limit was hit: a rejected event, or an assistant message with the rate_limit error", () => {
    expect(isRateLimitedMessage(event({ status: "rejected", resetsAt: RESETS_AT }))).toBe(true);
    expect(isRateLimitedMessage(event({ status: "allowed" }))).toBe(false);
    expect(isRateLimitedMessage(event({ status: "allowed_warning" }))).toBe(false);
    expect(isRateLimitedMessage({ type: "assistant", error: "rate_limit" })).toBe(true);
    expect(isRateLimitedMessage({ type: "assistant", error: "authentication_failed" })).toBe(false);
  });

  it("does not count a rejection of a window a run does not need, or one that extra usage covers", () => {
    expect(isRateLimitedMessage(event({ status: "rejected", rateLimitType: "seven_day_opus" }))).toBe(false);
    expect(isRateLimitedMessage(event({ status: "rejected", rateLimitType: "five_hour", isUsingOverage: true, overageStatus: "allowed_warning" }))).toBe(false);
    expect(isRateLimitedMessage(event({ status: "rejected", rateLimitType: "seven_day" }))).toBe(true);
  });
});

describe("the last window the engine saw", () => {
  it("is kept in the store, so doctor and the next run can read it", () => {
    const store = mkdtempSync(join(tmpdir(), "quorum-rl-"));
    const window = { status: "rejected" as const, window: "five_hour", resets_at: "2026-10-11T15:00:00.000Z", observed_at: "2026-10-11T12:00:00.000Z" };
    writeRateLimit(store, window);
    expect(readRateLimits(store)).toEqual([window]);
  });

  it("is absent when nothing was written, or the file cannot be read", () => {
    const store = mkdtempSync(join(tmpdir(), "quorum-rl-"));
    expect(readRateLimits(store)).toEqual([]);
    writeFileSync(join(store, RATE_LIMIT_FILE), "not json");
    expect(readRateLimits(store)).toEqual([]);
  });
});

describe("the rate-limit preflight", () => {
  const store = () => mkdtempSync(join(tmpdir(), "quorum-rl-"));
  const exhausted = { status: "rejected" as const, window: "five_hour", resets_at: new Date(RESETS_AT * 1000).toISOString(), observed_at: "x" };

  it("lets a run start when no window was ever seen", () => {
    expect(rateLimitPreflight(store(), NOW)).toBeUndefined();
  });

  it("refuses while the last window is exhausted and has not reset, saying which and until when", () => {
    const dir = store();
    writeRateLimit(dir, exhausted);
    const refusal = rateLimitPreflight(dir, NOW)!;
    expect(refusal.kind).toBe("rate_limited");
    expect(refusal.reason).toMatch(/five.hour/i);
    expect(refusal.reason).toContain(new Date(RESETS_AT * 1000).toISOString().slice(11, 16));
    expect(refusal.reason).toMatch(/resets/i);
  });

  it("lets a run start once the exhausted window has reset", () => {
    const dir = store();
    writeRateLimit(dir, exhausted);
    expect(rateLimitPreflight(dir, (RESETS_AT + 1) * 1000)).toBeUndefined();
  });

  it("does not refuse over a warning: the subscription still has room", () => {
    const dir = store();
    writeRateLimit(dir, { ...exhausted, status: "allowed_warning", utilization: 0.9 });
    expect(rateLimitPreflight(dir, NOW)).toBeUndefined();
  });

  it("refuses an exhausted window with no known reset while the sighting is fresh", () => {
    const dir = store();
    writeRateLimit(dir, { status: "rejected", window: "five_hour", observed_at: new Date(NOW - 60_000).toISOString() });
    expect(rateLimitPreflight(dir, NOW)?.kind).toBe("rate_limited");
  });

  it("stops believing a rejection with no known reset once the window it names must have rolled over", () => {
    const dir = store();
    writeRateLimit(dir, { status: "rejected", window: "five_hour", observed_at: new Date(NOW).toISOString() });
    expect(rateLimitPreflight(dir, NOW + STALE_REJECTION_MS - 1)?.kind).toBe("rate_limited");
    expect(rateLimitPreflight(dir, NOW + STALE_REJECTION_MS + 1)).toBeUndefined();
  });

  it("refuses over the weekly window too, but not over a window the tiers' models do not share", () => {
    const dir = store();
    writeRateLimit(dir, { ...exhausted, window: "seven_day_opus" });
    expect(rateLimitPreflight(dir, NOW)).toBeUndefined();
    writeRateLimit(dir, { ...exhausted, window: "seven_day" });
    expect(rateLimitPreflight(dir, NOW)?.reason).toMatch(/seven day/i);
  });

  it("does not refuse while extra usage is covering the overflow", () => {
    const dir = store();
    writeRateLimit(dir, { ...exhausted, overage_covers: true });
    expect(rateLimitPreflight(dir, NOW)).toBeUndefined();
  });

  it("refuses when any relevant window is out, even if another has room", () => {
    const dir = store();
    writeRateLimit(dir, { status: "allowed", window: "seven_day", utilization: 0.2, observed_at: "2026-10-11T11:00:00.000Z" });
    writeRateLimit(dir, exhausted);
    expect(rateLimitPreflight(dir, NOW)?.reason).toMatch(/five.hour/i);
  });
});

describe("keeping every window the CLI reports", () => {
  it("keeps one entry per window, so a report on one never erases another", () => {
    const dir = mkdtempSync(join(tmpdir(), "quorum-rl-"));
    writeRateLimit(dir, { status: "rejected", window: "five_hour", resets_at: "2026-10-11T15:00:00.000Z", observed_at: "2026-10-11T12:00:00.000Z" });
    writeRateLimit(dir, { status: "allowed", window: "seven_day", utilization: 0.3, observed_at: "2026-10-11T12:00:01.000Z" });
    expect(readRateLimits(dir).map((w) => [w.window, w.status]).sort()).toEqual([["five_hour", "rejected"], ["seven_day", "allowed"]]);
  });

  it("keeps the newest sighting of a window, however the writes arrive", () => {
    const dir = mkdtempSync(join(tmpdir(), "quorum-rl-"));
    writeRateLimit(dir, { status: "allowed", window: "five_hour", utilization: 0.5, observed_at: "2026-10-11T12:00:05.000Z" });
    writeRateLimit(dir, { status: "rejected", window: "five_hour", observed_at: "2026-10-11T12:00:01.000Z" });
    expect(readRateLimits(dir)).toEqual([expect.objectContaining({ status: "allowed", utilization: 0.5 })]);
    writeRateLimit(dir, { status: "rejected", window: "five_hour", observed_at: "2026-10-11T12:00:09.000Z" });
    expect(readRateLimits(dir)).toEqual([expect.objectContaining({ status: "rejected" })]);
  });

  it("still reads the single-window file an earlier build wrote", () => {
    const dir = mkdtempSync(join(tmpdir(), "quorum-rl-"));
    writeFileSync(join(dir, RATE_LIMIT_FILE), JSON.stringify({ status: "rejected", window: "five_hour", observed_at: "2026-10-11T12:00:00.000Z" }));
    expect(readRateLimits(dir)).toEqual([expect.objectContaining({ status: "rejected", window: "five_hour" })]);
  });
});

describe("a Claude CLI that has hit its limit", () => {
  const stream = readFileSync(fileURLToPath(new URL("../fixtures/cli/rate-limited.ndjson", import.meta.url)), "utf8").split("\n").filter(Boolean);

  function spawnOf(lines: string[]): SpawnFn {
    return (() => {
      const stdout = new EventEmitter() as EventEmitter & { setEncoding: (e: string) => void };
      stdout.setEncoding = () => {};
      const child = new EventEmitter() as EventEmitter & { stdout: unknown; stderr: unknown; kill: () => void };
      child.stdout = stdout;
      child.stderr = new EventEmitter();
      child.kill = () => {};
      queueMicrotask(() => { for (const l of lines) stdout.emit("data", l + "\n"); child.emit("close"); });
      return child;
    }) as unknown as SpawnFn;
  }

  const base = { prompt: "q", systemPrompt: "", role: "research" as const, effort: "low", maxBudgetUsd: 1, maxTurns: 3, timeoutMs: 10_000, env: { QUORUM_CLAUDE_BIN: "/fake/claude" }, now: () => NOW };

  it("refuses with the window it hit instead of returning an empty answer", async () => {
    const seen: unknown[] = [];
    const outcome = await runClaudeCode({ ...base, emitter: new Emitter(() => {}), spawn: spawnOf(stream), onRateLimit: (w) => seen.push(w) });

    expect(outcome.status).toBe("error");
    expect(outcome.refusal).toMatchObject({ kind: "rate_limited" });
    expect(outcome.refusal!.reason).toMatch(/five.hour/i);
    expect(seen).toEqual([expect.objectContaining({ status: "rejected", window: "five_hour" })]);
  });

  it("keeps a result the CLI actually finished, even though a window was rejected on the way", async () => {
    const finished = [
      `{"type":"system","subtype":"init","session_id":"s","model":"m"}`,
      JSON.stringify(event({ status: "rejected", resetsAt: RESETS_AT, rateLimitType: "five_hour" })),
      `{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.3,"session_id":"s","result":"Done.\\n\\n\`\`\`json\\n{\\"headline\\":\\"h\\",\\"status\\":\\"complete\\",\\"findings\\":[]}\\n\`\`\`"}`,
    ];
    const outcome = await runClaudeCode({ ...base, emitter: new Emitter(() => {}), spawn: spawnOf(finished) });

    expect(outcome.status).toBe("complete");
    expect(outcome.refusal).toBeUndefined();
    expect(outcome.usage.cost_usd).toBe(0.3);
  });

  it("ignores a rejection that extra usage covers", async () => {
    const covered = [
      `{"type":"system","subtype":"init","session_id":"s","model":"m"}`,
      JSON.stringify(event({ status: "rejected", resetsAt: RESETS_AT, rateLimitType: "five_hour", isUsingOverage: true, overageStatus: "allowed" })),
      `{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.3,"session_id":"s","result":"Done.\\n\\n\`\`\`json\\n{\\"headline\\":\\"h\\",\\"status\\":\\"complete\\",\\"findings\\":[]}\\n\`\`\`"}`,
    ];
    const outcome = await runClaudeCode({ ...base, emitter: new Emitter(() => {}), spawn: spawnOf(covered) });
    expect(outcome.status).toBe("complete");
  });

  it("reports a window that still has room and carries on", async () => {
    const ok = [
      `{"type":"system","subtype":"init","session_id":"s","model":"m"}`,
      JSON.stringify(event({ status: "allowed", resetsAt: RESETS_AT, rateLimitType: "five_hour", utilization: 0.4 })),
      `{"type":"result","subtype":"success","total_cost_usd":0.1,"session_id":"s","result":"Done.\\n\\n\`\`\`json\\n{\\"headline\\":\\"h\\",\\"status\\":\\"complete\\",\\"findings\\":[]}\\n\`\`\`"}`,
    ];
    const seen: any[] = [];
    const outcome = await runClaudeCode({ ...base, emitter: new Emitter(() => {}), spawn: spawnOf(ok), onRateLimit: (w) => seen.push(w) });

    expect(outcome.status).toBe("complete");
    expect(outcome.refusal).toBeUndefined();
    expect(seen).toEqual([expect.objectContaining({ status: "allowed", utilization: 0.4 })]);
  });

  it("words the refusal the same way the preflight does", () => {
    expect(rateLimitRefusal({ status: "rejected", window: "five_hour", resets_at: new Date(RESETS_AT * 1000).toISOString(), observed_at: "x" }).kind).toBe("rate_limited");
  });
});

describe("a run against an exhausted subscription", () => {
  const RESET = new Date(Date.now() + 3_600_000).toISOString();

  function exhaustedStore(): string {
    const store = mkdtempSync(join(tmpdir(), "quorum-rl-run-"));
    writeRateLimit(store, { status: "rejected", window: "five_hour", resets_at: RESET, observed_at: new Date().toISOString() });
    return store;
  }

  it("is refused before any model is called, and the record says why", async () => {
    const { runRun } = await import("../src/run.js");
    const store = exhaustedStore();
    const calls: string[] = [];
    const lines: string[] = [];
    const outcome = await runRun({ question: "q", tier: "quick", brainDir: store }, {}, {
      sink: (line) => lines.push(line), sessionId: "qrun-limited",
      runTopic: async (cfg) => { calls.push(cfg.role); throw new Error("no model may be called"); },
    });
    const result = JSON.parse(lines.at(-1)!);

    expect(calls).toEqual([]);
    expect(outcome.refusal).toMatchObject({ kind: "rate_limited" });
    expect(result).toMatchObject({ type: "run_result", status: "inconclusive", refusal: { kind: "rate_limited" } });
    expect(result.note).toMatch(/usage limit/i);
  });

  it("is refused by run --detach with the reason, and nothing is spawned", async () => {
    const { startDetached } = await import("../src/detach.js");
    const store = exhaustedStore();
    const spawned: string[] = [];
    const result = await startDetached({ question: "q" }, store, {}, {
      spawn: ((command: string) => { spawned.push(command); throw new Error("no spawn"); }) as any,
      self: (args) => ({ command: "engine", args }), newId: () => "ID", sleep: async () => {}, now: () => Date.now(), timeoutMs: 100,
    });

    expect(result).toMatchObject({ ok: false, error: expect.stringMatching(/usage limit/i) });
    expect(spawned).toEqual([]);
  });
});

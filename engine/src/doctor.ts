import { execFile } from "node:child_process";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { resolveClaudeBin } from "./claudeCode.js";
import { pendingMigrations } from "./migrate.js";
import type { Env } from "./providers.js";

export interface DoctorCheck {
  id: string;
  ok: boolean;
  detail: string;
  fix: string | null;
}

export interface DoctorReport {
  ok: boolean;
  checks: DoctorCheck[];
}

export interface DoctorDeps {
  storeDir: string;
  resolveClaude: () => string;
  runClaude: (bin: string, args: string[]) => Promise<{ status: number | null; stdout: string }>;
  probeFetch: () => Promise<{ ok: boolean; detail: string }>;
  probeStore: (dir: string) => string | undefined;
  pendingMigrations: (dir: string) => number;
}

const DEFAULT_FETCH_PROBE_URL = "https://example.com/";
const FETCH_PROBE_TIMEOUT_MS = 5000;
const CLAUDE_PROBE_TIMEOUT_MS = 15000;

const pass = (id: string, detail: string): DoctorCheck => ({ id, ok: true, detail, fix: null });
const fail = (id: string, detail: string, fix: string): DoctorCheck => ({ id, ok: false, detail, fix });

export async function runDoctor(deps: DoctorDeps): Promise<DoctorReport> {
  const claude = await checkClaude(deps);
  const checks = [
    ...claude,
    await checkFetch(deps),
    checkStore(deps),
    checkMigrations(deps),
    pass("rate_limit", "not tracked yet: the rate-limit window is read once runs record it"),
  ];
  return { ok: checks.every((check) => check.ok), checks };
}

async function checkClaude(deps: DoctorDeps): Promise<DoctorCheck[]> {
  let bin: string;
  try {
    bin = deps.resolveClaude();
  } catch {
    return [
      fail("claude_cli", "the claude CLI was not found", "Install Claude Code (claude.com/claude-code), or set QUORUM_CLAUDE_BIN to its path."),
      fail("claude_login", "not checked, because the claude CLI was not found", "Install Claude Code first."),
    ];
  }
  const version = await deps.runClaude(bin, ["--version"]).catch(() => undefined);
  const cli = pass("claude_cli", `${bin} ${version?.stdout.trim().split("\n")[0] ?? "(version unknown)"}`.trim());
  const auth = await deps.runClaude(bin, ["auth", "status"]).catch(() => undefined);
  return [cli, loginCheck(auth)];
}

function loginCheck(auth: { status: number | null; stdout: string } | undefined): DoctorCheck {
  let loggedIn: unknown;
  try {
    loggedIn = JSON.parse(auth?.stdout ?? "").loggedIn;
  } catch {
    loggedIn = undefined;
  }
  if (loggedIn === true) return pass("claude_login", "signed in");
  if (loggedIn === false) return fail("claude_login", "the claude CLI is not signed in", "Run `claude` once and sign in, then try again.");
  return pass("claude_login", "sign-in could not be confirmed; a run fails fast if it is not signed in");
}

async function checkFetch(deps: DoctorDeps): Promise<DoctorCheck> {
  const probe = await deps.probeFetch();
  return probe.ok ? pass("fetch", probe.detail) : fail("fetch", probe.detail, "Check the network connection: a run cannot read a source without it.");
}

function checkStore(deps: DoctorDeps): DoctorCheck {
  const problem = deps.probeStore(deps.storeDir);
  return problem === undefined
    ? pass("store", `${deps.storeDir} is writable`)
    : fail("store", `${deps.storeDir} is not writable: ${problem}`, "Choose a brain folder you can write to.");
}

function checkMigrations(deps: DoctorDeps): DoctorCheck {
  const waiting = deps.pendingMigrations(deps.storeDir);
  if (waiting === 0) return pass("migrate", "every record is current");
  return fail("migrate", `${waiting} records need migrating`, `quorum-engine migrate --store ${deps.storeDir}`);
}

export function formatDoctor(report: DoctorReport): string {
  const lines: string[] = [];
  for (const check of report.checks) {
    lines.push(`${check.ok ? "ok  " : "FAIL"} ${check.id} ${check.detail}`);
    if (check.fix && !check.ok) lines.push(`      fix: ${check.fix}`);
  }
  return lines.join("\n") + "\n";
}

export function defaultDoctorDeps(env: Env, storeDir: string): DoctorDeps {
  return {
    storeDir,
    resolveClaude: () => resolveClaudeBin(env),
    runClaude: (bin, args) => new Promise((resolve, reject) => {
      execFile(bin, args, { timeout: CLAUDE_PROBE_TIMEOUT_MS, env: env as NodeJS.ProcessEnv }, (error, stdout) => {
        const status = typeof (error as { code?: unknown } | null)?.code === "number" ? (error as { code: number }).code : error ? null : 0;
        if (error && status === null) reject(error);
        else resolve({ status, stdout: String(stdout) });
      });
    }),
    probeFetch: async () => {
      const url = env.QUORUM_DOCTOR_FETCH_URL ?? DEFAULT_FETCH_PROBE_URL;
      try {
        const response = await fetch(url, { method: "HEAD", signal: AbortSignal.timeout(FETCH_PROBE_TIMEOUT_MS) });
        return { ok: response.status < 500, detail: `${new URL(url).host} answered ${response.status}` };
      } catch (error) {
        return { ok: false, detail: error instanceof Error ? error.message : String(error) };
      }
    },
    probeStore: (dir) => {
      try {
        mkdirSync(dir, { recursive: true });
        const probe = join(dir, `.doctor-${process.pid}`);
        writeFileSync(probe, "");
        rmSync(probe);
        return undefined;
      } catch (error) {
        return error instanceof Error ? error.message : String(error);
      }
    },
    pendingMigrations: (dir) => pendingMigrations(dir),
  };
}

import { spawn, spawnSync } from "node:child_process";
import { createServer, type Server } from "node:http";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ENGINE_DIR = fileURLToPath(new URL("../", import.meta.url));
const SITE_DIR = join(ENGINE_DIR, "fixtures", "e2e", "site");
export const FAKE_CLAUDE = join(ENGINE_DIR, "fixtures", "e2e", "fake-claude.ts");
export const E2E_BUILD = "e2e-test";

export interface FixtureSite {
  baseUrl: string;
  close: () => Promise<void>;
}

export async function serveFixtureSite(): Promise<FixtureSite> {
  const server: Server = createServer((request, response) => {
    const name = (request.url ?? "/").split("?")[0]!.replace(/^\//, "");
    const path = join(SITE_DIR, name);
    if (name === "members-only.html") {
      response.writeHead(403, { "content-type": "text/html" }).end("<p>Members only</p>");
    } else if (name && existsSync(path)) {
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(readFileSync(path));
    } else {
      response.writeHead(404).end();
    }
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as { port: number };
  return { baseUrl: `http://127.0.0.1:${port}`, close: () => new Promise((resolve) => server.close(() => resolve())) };
}

export function engineBinary(): string {
  if (process.env.QUORUM_E2E_BIN) return process.env.QUORUM_E2E_BIN;
  const out = join(mkdtempSync(join(tmpdir(), "quorum-e2e-bin-")), "quorum-engine");
  const built = spawnSync("bun", [
    "build", "src/index.ts", "--compile", "--outfile", out, "--define", `QUORUM_ENGINE_BUILD="${E2E_BUILD}"`,
  ], { cwd: ENGINE_DIR, encoding: "utf8" });
  if (built.status !== 0) throw new Error(`bun build --compile failed:\n${built.stderr}`);
  return out;
}

export interface EngineRun {
  exitCode: number | null;
  events: any[];
  stderr: string;
  runDir: string;
  brainDir: string;
}

export interface RunOptions {
  binary: string;
  baseUrl: string;
  scenario?: string;
  question?: string;
}

const CLAUDE_HAIKU = "claude-code/claude-haiku-4-5";

export function runEngine(options: RunOptions): Promise<EngineRun> {
  const brainDir = mkdtempSync(join(tmpdir(), "quorum-e2e-brain-"));
  const env = e2eEnv(options.scenario ?? "happy", options.baseUrl);
  const config = { ...runConfig(brainDir), ...(options.question ? { question: options.question } : {}) };

  return new Promise((resolve, reject) => {
    const child = spawn(options.binary, ["run"], { env: env as NodeJS.ProcessEnv, stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (exitCode) => {
      const events = stdout.split("\n").filter(Boolean).map((line) => JSON.parse(line));
      resolve({ exitCode, events, stderr, runDir: String(events[0]?.run_dir ?? ""), brainDir });
    });
    child.stdin.end(JSON.stringify(config));
  });
}

export function exportRunDir(binary: string, runDir: string): { exitCode: number | null; stdout: string; stderr: string } {
  const exported = spawnSync(binary, ["export", "--md", runDir], { encoding: "utf8" });
  return { exitCode: exported.status, stdout: exported.stdout, stderr: exported.stderr };
}

export function checkRunDir(binary: string, runDir: string): { exitCode: number | null; stdout: string; json: any } {
  const text = spawnSync(binary, ["check", runDir], { encoding: "utf8" });
  const json = spawnSync(binary, ["check", runDir, "--json"], { encoding: "utf8" });
  return { exitCode: text.status, stdout: text.stdout, json: json.stdout ? JSON.parse(json.stdout) : undefined };
}

export interface DetachedRun {
  created: any;
  exitCode: number | null;
  stdout: string;
  stderr: string;
  brainDir: string;
  runDir: string;
  pid: number;
}

export function e2eEnv(scenario = "happy", baseUrl = "", extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  const env: Record<string, string | undefined> = {
    ...process.env,
    QUORUM_CLAUDE_BIN: FAKE_CLAUDE,
    QUORUM_E2E_BASE_URL: baseUrl,
    QUORUM_FAKE_SCENARIO: scenario,
    ...extra,
  };
  for (const key of ["QUORUM_TAVILY_KEY", "QUORUM_BRAVE_KEY", "ANTHROPIC_API_KEY", "QUORUM_ANTHROPIC_KEY"]) delete env[key];
  return env as NodeJS.ProcessEnv;
}

export function runConfig(brainDir: string): Record<string, unknown> {
  return {
    question: "What do the EU AI Act's obligations for general-purpose AI models require, and from when?",
    angleCount: 2, angleModel: CLAUDE_HAIKU, synthesisModel: CLAUDE_HAIKU, validatorModel: CLAUDE_HAIKU,
    effort: "low", perTopicBudgetUSD: 0.5, runBudgetUSD: 2, perTopicTimeoutSec: 60, maxTurns: 6, rounds: 1, brainDir,
  };
}

export function startDetachedRun(options: { binary: string; baseUrl: string; delayMs?: number; replay?: string }): Promise<DetachedRun> {
  const brainDir = mkdtempSync(join(tmpdir(), "quorum-e2e-detach-"));
  const env = e2eEnv("happy", options.baseUrl, { QUORUM_FAKE_DELAY_MS: String(options.delayMs ?? 0) });
  return new Promise((resolve, reject) => {
    const replayArgs = options.replay ? ["--replay", options.replay, "--replay-delay-ms", "5"] : [];
    const child = spawn(options.binary, ["run", "--detach", "--store", brainDir, ...replayArgs], { env, stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (exitCode) => {
      const created = stdout.split("\n").filter(Boolean).map((line) => JSON.parse(line))[0];
      resolve({ created, exitCode, stdout, stderr, brainDir, runDir: String(created?.dir ?? ""), pid: Number(created?.pid ?? 0) });
    });
    child.stdin.end(JSON.stringify(runConfig(brainDir)));
  });
}

export function startAttachedRun(options: { binary: string; baseUrl: string; delayMs?: number }): {
  brainDir: string;
  events: any[];
  firstEvent: Promise<any>;
  done: Promise<{ exitCode: number | null; stderr: string }>;
} {
  const brainDir = mkdtempSync(join(tmpdir(), "quorum-e2e-attached-"));
  const env = e2eEnv("happy", options.baseUrl, { QUORUM_FAKE_DELAY_MS: String(options.delayMs ?? 0) });
  const child = spawn(options.binary, ["run", "--store", brainDir], { env, stdio: ["pipe", "pipe", "pipe"] });
  const events: any[] = [];
  let buffer = "";
  let stderr = "";
  let announce: (event: any) => void = () => {};
  const firstEvent = new Promise<any>((resolve) => { announce = resolve; });
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    let newline = buffer.indexOf("\n");
    while (newline >= 0) {
      const event = JSON.parse(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
      events.push(event);
      if (events.length === 1) announce(event);
      newline = buffer.indexOf("\n");
    }
  });
  child.stderr.on("data", (chunk) => (stderr += chunk));
  const done = new Promise<{ exitCode: number | null; stderr: string }>((resolve) => {
    child.on("close", (exitCode) => resolve({ exitCode, stderr }));
  });
  child.stdin.end(JSON.stringify(runConfig(brainDir)));
  return { brainDir, events, firstEvent, done };
}

export function engineJson(binary: string, args: string[], input?: unknown, env: NodeJS.ProcessEnv = e2eEnv()): { exitCode: number | null; json: any; stdout: string; stderr: string } {
  const result = spawnSync(binary, args, { env, encoding: "utf8", ...(input === undefined ? {} : { input: JSON.stringify(input) }) });
  const lines = result.stdout.split("\n").filter(Boolean);
  const parsed = lines.map((line) => { try { return JSON.parse(line); } catch { return undefined; } });
  return { exitCode: result.status, json: lines.length > 1 ? parsed : parsed[0], stdout: result.stdout, stderr: result.stderr };
}

export function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

export function processGroupOf(pid: number): number {
  const out = spawnSync("ps", ["-o", "pgid=", "-p", String(pid)], { encoding: "utf8" });
  return Number(out.stdout.trim());
}

export async function waitFor<T>(what: string, probe: () => T | undefined | false, timeoutMs = 60_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = probe();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`timed out waiting for ${what}`);
}

export function readRecord(runDir: string): any {
  try {
    return JSON.parse(readFileSync(join(runDir, "run.json"), "utf8"));
  } catch {
    return undefined;
  }
}

export function readEvents(runDir: string): any[] {
  try {
    return readFileSync(join(runDir, "events.ndjson"), "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
  } catch {
    return [];
  }
}

export function engineJsonAsync(binary: string, args: string[], env: NodeJS.ProcessEnv = e2eEnv()): Promise<{ exitCode: number | null; json: any; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, { env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (exitCode) => {
      const first = stdout.split("\n").find(Boolean);
      resolve({ exitCode, json: first ? JSON.parse(first) : undefined, stdout, stderr });
    });
  });
}

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
}

export interface RunOptions {
  binary: string;
  baseUrl: string;
  scenario?: string;
  question?: string;
}

const CLAUDE_HAIKU = "claude-code/claude-haiku-4-5";

export function runEngine(options: RunOptions): Promise<EngineRun> {
  const runDir = mkdtempSync(join(tmpdir(), "quorum-e2e-run-"));
  const env: Record<string, string | undefined> = {
    ...process.env,
    QUORUM_CLAUDE_BIN: FAKE_CLAUDE,
    QUORUM_E2E_BASE_URL: options.baseUrl,
    QUORUM_FAKE_SCENARIO: options.scenario ?? "happy",
  };
  for (const key of ["QUORUM_TAVILY_KEY", "QUORUM_BRAVE_KEY", "ANTHROPIC_API_KEY", "QUORUM_ANTHROPIC_KEY"]) delete env[key];

  const config = {
    question: "What do the EU AI Act's obligations for general-purpose AI models require, and from when?",
    angleCount: 2,
    angleModel: CLAUDE_HAIKU,
    synthesisModel: CLAUDE_HAIKU,
    validatorModel: CLAUDE_HAIKU,
    effort: "low",
    perTopicBudgetUSD: 0.5,
    runBudgetUSD: 2,
    perTopicTimeoutSec: 60,
    maxTurns: 6,
    rounds: 1,
    spawnMode: "off",
    runDir,
    evidenceDir: join(runDir, "evidence"),
    ...(options.question ? { question: options.question } : {}),
  };

  return new Promise((resolve, reject) => {
    const child = spawn(options.binary, ["run"], { env: env as NodeJS.ProcessEnv, stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (exitCode) => {
      const events = stdout.split("\n").filter(Boolean).map((line) => JSON.parse(line));
      resolve({ exitCode, events, stderr, runDir });
    });
    child.stdin.write(JSON.stringify(config) + "\n");
  });
}

export function checkRunDir(binary: string, runDir: string): { exitCode: number | null; stdout: string; json: any } {
  const text = spawnSync(binary, ["check", runDir], { encoding: "utf8" });
  const json = spawnSync(binary, ["check", runDir, "--json"], { encoding: "utf8" });
  return { exitCode: text.status, stdout: text.stdout, json: json.stdout ? JSON.parse(json.stdout) : undefined };
}

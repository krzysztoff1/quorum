import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";
import { closeSync, existsSync, mkdirSync, openSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { PROTOCOL_VERSION } from "./emitter.js";
import { ulid } from "./record/ids.js";
import { brainLayout, RUN_FILE } from "./record/store.js";
import type { RunConfig } from "./run.js";
import { selfCommand } from "./self.js";
import type { Env } from "./providers.js";

export const STDERR_LOG = "engine.stderr.log";
const START_TIMEOUT_MS = 15_000;
const POLL_MS = 50;

export interface DetachDeps {
  spawn: typeof nodeSpawn;
  self: (args: string[]) => { command: string; args: string[] };
  newId: () => string;
  sleep: (ms: number) => Promise<void>;
  now: () => number;
  timeoutMs: number;
}

export interface RunCreated {
  type: "run.created";
  protocol_version: number;
  question_id: string;
  run_id: string;
  dir: string;
  pid: number;
}

export type DetachResult = { ok: true; created: RunCreated } | { ok: false; error: string };

export function defaultDetachDeps(): DetachDeps {
  return {
    spawn: nodeSpawn,
    self: (args) => selfCommand(args),
    newId: () => ulid(),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    now: Date.now,
    timeoutMs: START_TIMEOUT_MS,
  };
}

export async function startDetached(config: RunConfig, storeDir: string, env: Env, deps: DetachDeps,
                                    extraArgs: string[] = []): Promise<DetachResult> {
  const questionId = deps.newId();
  const runId = deps.newId();
  const layout = brainLayout(storeDir, questionId, runId);
  mkdirSync(layout.runDir, { recursive: true });
  const stderrLog = join(layout.runDir, STDERR_LOG);
  const stderrFd = openSync(stderrLog, "a");
  let child: ChildProcess;
  try {
    const self = deps.self(["run", "--store", storeDir, ...extraArgs]);
    child = deps.spawn(self.command, self.args, {
      detached: true,
      env: env as NodeJS.ProcessEnv,
      stdio: ["pipe", "ignore", stderrFd],
    });
  } finally {
    closeSync(stderrFd);
  }
  let exited: string | undefined;
  child.on("exit", (code, signal) => { exited = `exit ${code ?? signal}`; });
  child.on("error", (error) => { exited = error.message; });
  child.stdin!.end(JSON.stringify({ ...config, brainDir: storeDir, questionId, runId }));

  const recordPath = join(layout.runDir, RUN_FILE);
  const deadline = deps.now() + deps.timeoutMs;
  while (!existsSync(recordPath)) {
    if (exited !== undefined) return { ok: false, error: `the engine stopped before it started the run (${exited}): ${tail(stderrLog)}` };
    if (deps.now() >= deadline) return { ok: false, error: `the engine did not start the run within ${deps.timeoutMs / 1000}s: ${tail(stderrLog)}` };
    await deps.sleep(POLL_MS);
  }
  child.unref();
  return {
    ok: true,
    created: {
      type: "run.created", protocol_version: PROTOCOL_VERSION, question_id: questionId, run_id: runId,
      dir: layout.runDir, pid: child.pid ?? 0,
    },
  };
}

function tail(path: string): string {
  try {
    return readFileSync(path, "utf8").trim().slice(-600) || "no output";
  } catch {
    return "no output";
  }
}

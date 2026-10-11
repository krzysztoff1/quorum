#!/usr/bin/env bun
import { parseArgs } from "./args.js";
import { runEngine } from "./engine.js";
import { runMcpServe } from "./mcp.js";
import { runRun, type RunConfig } from "./run.js";
import { Emitter, versionLine } from "./emitter.js";
import { runReplay } from "./replay.js";
import { checkRun, formatReport, loadRunDir, summarizeRun } from "./check.js";
import { exportMarkdown } from "./record/export.js";
import { readStoredRun } from "./record/store.js";
import { writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { readJsonFrom } from "./stdinJson.js";
import { defaultDetachDeps, startDetached } from "./detach.js";
import { keepAwake } from "./awake.js";
import { cancelRun } from "./cancel.js";
import { listRuns } from "./runIndex.js";
import { migrateStore } from "./migrate.js";
import { claudeScopeDeps, scopeQuestion, type ScopeInput } from "./scope.js";
import { defaultDoctorDeps, formatDoctor, runDoctor } from "./doctor.js";

const DEFAULT_REPLAY_DELAY_MS = 140;
const REFUSED_EXIT_CODE = 3;

const parsed = parseArgs(process.argv.slice(2));
const storeDir = parsed.store ?? join(homedir(), "Quorum");

const isAlive = (pid: number): boolean => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as { code?: string }).code === "EPERM";
  }
};

if (parsed.command === "version") {
  process.stdout.write(versionLine());
} else if (parsed.command === "check") {
  if (!parsed.runDir) {
    process.stderr.write("usage: quorum-engine check <run-dir> [--json]\n");
    process.exitCode = 2;
  } else {
    const input = loadRunDir(parsed.runDir);
    const report = checkRun(input);
    process.stdout.write(parsed.json ? JSON.stringify({ ...report, run: summarizeRun(input) }) + "\n" : formatReport(report));
    if (!report.ok) process.exitCode = 1;
  }
} else if (parsed.command === "export") {
  const stored = parsed.runDir && parsed.markdown ? readStoredRun(parsed.runDir) : undefined;
  if (!stored) {
    process.stderr.write("usage: quorum-engine export --md <run-dir> [--out <file.md>]\n");
    process.exitCode = 2;
  } else if (!stored.record) {
    process.stderr.write(`${stored.problem ?? `no run.json in ${parsed.runDir}`}\n`);
    process.exitCode = 1;
  } else {
    const markdown = exportMarkdown(stored.record, stored.question);
    if (parsed.out) writeFileSync(parsed.out, markdown);
    else process.stdout.write(markdown);
  }
} else if (parsed.command === "mcp-serve") {
  await runMcpServe(process.env);
} else if (parsed.command === "doctor") {
  const report = await runDoctor(defaultDoctorDeps(process.env, storeDir));
  process.stdout.write(parsed.json ? JSON.stringify(report) + "\n" : formatDoctor(report));
  if (!report.ok) process.exitCode = 1;
} else if (parsed.command === "scope") {
  try {
    process.stdout.write(JSON.stringify(await scopeQuestion(await readJsonFrom<ScopeInput>(process.stdin), claudeScopeDeps(process.env))) + "\n");
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
} else if (parsed.command === "list") {
  for (const line of listRuns(storeDir, { now: Date.now, isAlive })) process.stdout.write(JSON.stringify(line) + "\n");
} else if (parsed.command === "cancel") {
  if (!parsed.runId) {
    process.stderr.write("usage: quorum-engine cancel RUN_ID [--store DIR]\n");
    process.exitCode = 2;
  } else {
    const result = cancelRun(storeDir, parsed.runId, { now: Date.now, isAlive, signal: (pid, name) => process.kill(pid, name) });
    process.stdout.write(JSON.stringify(result) + "\n");
    if (!result.ok) process.exitCode = 1;
  }
} else if (parsed.command === "migrate") {
  const report = migrateStore(storeDir);
  process.stdout.write(JSON.stringify(report) + "\n");
  if (report.unreadable.length > 0) process.exitCode = 1;
} else if (parsed.command === "run") {
  const config = await readJsonFrom<RunConfig>(process.stdin);
  const store = parsed.store ?? config.brainDir;
  if (parsed.detach) {
    if (!store) {
      process.stderr.write("run --detach needs --store DIR or a brainDir in the config\n");
      process.exitCode = 2;
    } else {
      const replayArgs = parsed.replay
        ? ["--replay", parsed.replay, "--replay-delay-ms", String(parsed.replayDelayMs ?? DEFAULT_REPLAY_DELAY_MS)]
        : [];
      const started = await startDetached(config, store, process.env, defaultDetachDeps(), replayArgs);
      if (started.ok) process.stdout.write(JSON.stringify(started.created) + "\n");
      else {
        process.stdout.write(JSON.stringify({ type: "error", error: started.error }) + "\n");
        process.exitCode = 1;
      }
    }
  } else {
    const controller = new AbortController();
    const onSignal = () => controller.abort();
    process.on("SIGTERM", onSignal);
    process.on("SIGINT", onSignal);
    if (parsed.replay) {
      await runReplay({
        fixturePath: parsed.replay,
        evidenceDir: config.evidenceDir,
        ...(store ? { brainDir: store, question: config.question } : {}),
        ...(config.questionId && config.runId ? { ids: { questionId: config.questionId, runId: config.runId } } : {}),
        pid: process.pid,
        delayMs: parsed.replayDelayMs ?? DEFAULT_REPLAY_DELAY_MS,
        sink: (line) => process.stdout.write(line),
        signal: controller.signal,
      });
    } else {
      keepAwake(process.pid);
      const outcome = await runRun({ ...config, ...(store ? { brainDir: store } : {}) }, process.env, {
        sink: (line) => process.stdout.write(line),
        abortController: controller,
        pid: process.pid,
      });
      if (outcome.refusal) process.exitCode = REFUSED_EXIT_CODE;
    }
    process.off("SIGTERM", onSignal);
    process.off("SIGINT", onSignal);
  }
  process.stdin.destroy();
} else {
  await runEngine(parsed, process.env, { emitter: new Emitter() });
}

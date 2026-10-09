#!/usr/bin/env bun
import { parseArgs } from "./args.js";
import { runEngine } from "./engine.js";
import { runMcpServe } from "./mcp.js";
import { runRun, type RunConfig } from "./run.js";
import { readJsonFrom } from "./stdinJson.js";
import { Emitter, versionLine } from "./emitter.js";
import { runReplay } from "./replay.js";
import { checkRun, formatReport, loadRunDir, summarizeRun } from "./check.js";
import { exportMarkdown } from "./record/export.js";
import { readStoredRun } from "./record/store.js";
import { writeFileSync } from "node:fs";

const DEFAULT_REPLAY_DELAY_MS = 140;
const REFUSED_EXIT_CODE = 3;

const parsed = parseArgs(process.argv.slice(2));

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
} else if (parsed.command === "run") {
  const config = await readJsonFrom<RunConfig>(process.stdin);
  const controller = new AbortController();
  const onSignal = () => controller.abort();
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  if (parsed.replay) {
    await runReplay({
      fixturePath: parsed.replay,
      evidenceDir: config.evidenceDir,
      ...(config.brainDir ? { brainDir: config.brainDir, question: config.question } : {}),
      delayMs: parsed.replayDelayMs ?? DEFAULT_REPLAY_DELAY_MS,
      sink: (line) => process.stdout.write(line),
      signal: controller.signal,
    });
  } else {
    const outcome = await runRun(config, process.env, {
      sink: (line) => process.stdout.write(line),
      abortController: controller,
    });
    if (outcome.refusal) process.exitCode = REFUSED_EXIT_CODE;
  }
  process.off("SIGTERM", onSignal);
  process.off("SIGINT", onSignal);
  process.stdin.destroy();
} else {
  await runEngine(parsed, process.env, { emitter: new Emitter() });
}

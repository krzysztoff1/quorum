#!/usr/bin/env bun
import { parseArgs } from "./args.js";
import { runEngine } from "./engine.js";
import { runMcpServe } from "./mcp.js";
import { runRun, type RunConfig } from "./run.js";
import { ControlQueue, parseControlLine, takeLeadingJson } from "./approvals.js";
import { Emitter, versionLine } from "./emitter.js";
import { runReplay } from "./replay.js";
import { checkRun, formatReport, loadRunDir } from "./check.js";

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
    process.stdout.write(parsed.json ? JSON.stringify({ ...report, run: summarizeRun(input.events) }) + "\n" : formatReport(report));
    if (!report.ok) process.exitCode = 1;
  }
} else if (parsed.command === "mcp-serve") {
  await runMcpServe(process.env);
} else if (parsed.command === "run") {
  const controls = new ControlQueue();
  const config = await readConfigThenControls(controls);
  const controller = new AbortController();
  const onSignal = () => controller.abort();
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  if (parsed.replay) {
    await runReplay({
      fixturePath: parsed.replay,
      evidenceDir: config.evidenceDir,
      delayMs: parsed.replayDelayMs ?? DEFAULT_REPLAY_DELAY_MS,
      sink: (line) => process.stdout.write(line),
      signal: controller.signal,
    });
  } else {
    const outcome = await runRun(config, process.env, {
      sink: (line) => process.stdout.write(line),
      abortController: controller,
      controls,
    });
    if (outcome.refusal) process.exitCode = REFUSED_EXIT_CODE;
  }
  process.off("SIGTERM", onSignal);
  process.off("SIGINT", onSignal);
  process.stdin.destroy();
} else {
  await runEngine(parsed, process.env, { emitter: new Emitter() });
}

function summarizeRun(events: any[]): Record<string, unknown> {
  const start = events.find((e) => e?.type === "run_start");
  const result = events.findLast((e) => e?.type === "run_result");
  return {
    build: start?.build ?? null,
    protocol: start?.protocol_version ?? null,
    status: result?.status ?? null,
    grounding: result?.grounding ?? null,
    total_cost_usd: result?.total_cost_usd ?? null,
    documents: result?.documents?.length ?? 0,
    snapshots: (result?.documents ?? []).filter((d: any) => d?.snapshot_path).length,
    claims_checked: (result?.validation?.rounds ?? []).reduce((sum: number, r: any) => sum + (r?.claims_checked ?? 0), 0),
    validation: result?.validation?.status ?? null,
    refusal: result?.refusal?.kind ?? null,
    note: result?.note ?? null,
  };
}

/// stdin carries the config first and then stays open for the run: `ask` mode needs a way for the app to
function readConfigThenControls(controls: ControlQueue): Promise<RunConfig> {
  return new Promise((resolve, reject) => {
    let buffer = "";
    let config: RunConfig | undefined;

    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk: string) => {
      buffer += chunk;
      if (!config) {
        const split = takeLeadingJson(buffer);
        if (!split) return;
        config = split.value as RunConfig;
        buffer = split.rest;
        resolve(config);
      }
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        const control = parseControlLine(buffer.slice(0, newline));
        buffer = buffer.slice(newline + 1);
        if (control) controls.push(control);
        newline = buffer.indexOf("\n");
      }
    });
    process.stdin.on("end", () => {
      controls.close();
      if (!config) reject(new Error("stdin closed before the run config arrived"));
    });
    process.stdin.on("error", reject);
  });
}

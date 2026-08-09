#!/usr/bin/env bun
import { parseArgs } from "./args.js";
import { runEngine } from "./engine.js";
import { runMcpServe } from "./mcp.js";
import { runRun, type RunConfig } from "./run.js";
import { ControlQueue, parseControlLine, takeLeadingJson } from "./approvals.js";
import { Emitter } from "./emitter.js";

const parsed = parseArgs(process.argv.slice(2));

if (parsed.command === "mcp-serve") {
  await runMcpServe(process.env);
} else if (parsed.command === "run") {
  const controls = new ControlQueue();
  const config = await readConfigThenControls(controls);
  const controller = new AbortController();
  const onSignal = () => controller.abort();
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  await runRun(config, process.env, {
    sink: (line) => process.stdout.write(line),
    abortController: controller,
    controls,
  });
  process.off("SIGTERM", onSignal);
  process.off("SIGINT", onSignal);
} else {
  await runEngine(parsed, process.env, { emitter: new Emitter() });
}

/// stdin carries the config first and then stays open for the run: `ask` mode needs a way for the app to
/// answer a pending question while the run is still going, and the canvas needs one to prune or retry.
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

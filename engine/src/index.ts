#!/usr/bin/env bun
import { parseArgs } from "./args.js";
import { runEngine } from "./engine.js";
import { runMcpServe } from "./mcp.js";
import { runRun, type RunConfig } from "./run.js";
import { Emitter } from "./emitter.js";

const parsed = parseArgs(process.argv.slice(2));

if (parsed.command === "mcp-serve") {
  await runMcpServe(process.env);
} else if (parsed.command === "run") {
  const config = JSON.parse(await readStdin()) as RunConfig;
  const controller = new AbortController();
  const onSignal = () => controller.abort();
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  await runRun(config, process.env, {
    sink: (line) => process.stdout.write(line),
    abortController: controller,
  });
  process.off("SIGTERM", onSignal);
  process.off("SIGINT", onSignal);
} else {
  await runEngine(parsed, process.env, { emitter: new Emitter() });
}

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

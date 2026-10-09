import { cpSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import type { Sink } from "./emitter.js";

export interface ReplayOptions {
  fixturePath: string;
  evidenceDir?: string;
  delayMs: number;
  sink: Sink;
  signal?: AbortSignal;
  sleep?: (ms: number) => Promise<void>;
}

const DEFAULT_SLEEP = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function sourcesDirOf(fixturePath: string): string {
  return join(dirname(fixturePath), basename(fixturePath).replace(/\.ndjson$/, "") + ".sources");
}

function recordedLines(fixturePath: string): string[] {
  if (!existsSync(fixturePath)) throw new Error(`replay fixture not found: ${fixturePath}`);
  return readFileSync(fixturePath, "utf8").split("\n").filter((line) => line.trim().length > 0);
}

function layRecordedSources(fixturePath: string, evidenceDir: string | undefined): void {
  const recorded = sourcesDirOf(fixturePath);
  if (!evidenceDir || !existsSync(recorded)) return;
  const destination = join(evidenceDir, "sources");
  mkdirSync(destination, { recursive: true });
  cpSync(recorded, destination, { recursive: true, force: false, errorOnExist: false });
}

export async function runReplay(options: ReplayOptions): Promise<void> {
  const lines = recordedLines(options.fixturePath);
  layRecordedSources(options.fixturePath, options.evidenceDir);
  const sleep = options.sleep ?? DEFAULT_SLEEP;
  for (const line of lines) {
    if (options.signal?.aborted) return;
    options.sink(line + "\n");
    await sleep(options.delayMs);
  }
}

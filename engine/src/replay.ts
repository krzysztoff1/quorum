import { cpSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { checkRun } from "./check.js";
import type { Sink } from "./emitter.js";
import { openRecording } from "./record/store.js";
import { RunLog } from "./runLog.js";

export interface ReplayOptions {
  fixturePath: string;
  evidenceDir?: string;
  delayMs: number;
  sink: Sink;
  signal?: AbortSignal;
  sleep?: (ms: number) => Promise<void>;
  brainDir?: string;
  question?: string;
  now?: () => number;
  newId?: () => string;
}

const DEFAULT_SLEEP = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const REPLAY_MODEL = "replay";

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
  const sleep = options.sleep ?? DEFAULT_SLEEP;
  if (!options.brainDir) {
    layRecordedSources(options.fixturePath, options.evidenceDir);
    for (const line of lines) {
      if (options.signal?.aborted) return;
      options.sink(line + "\n");
      await sleep(options.delayMs);
    }
    return;
  }

  const now = options.now ?? Date.now;
  const recording = openRecording({
    question: options.question ?? "",
    brainDir: options.brainDir,
    models: { planner: REPLAY_MODEL, research: REPLAY_MODEL, synthesis: REPLAY_MODEL, validator: REPLAY_MODEL },
    limits: {},
    now,
    ...(options.newId ? { newId: options.newId } : {}),
  });
  const runDir = recording.runDir!;
  const evidenceDir = join(runDir, "evidence");
  layRecordedSources(options.fixturePath, evidenceDir);
  const log = new RunLog(runDir);
  const sink = log.tee(recording.recorder.tee(options.sink));
  for (const line of lines) {
    if (options.signal?.aborted) {
      recording.recorder.abandon("cancelled", "The replay was stopped before the run reported.");
      return;
    }
    sink(JSON.stringify(replayed(JSON.parse(line), recording, log, evidenceDir, now)) + "\n");
    await sleep(options.delayMs);
  }
  recording.recorder.finish();
}

function replayed(event: any, recording: ReturnType<typeof openRecording>, log: RunLog, evidenceDir: string,
                  now: () => number): any {
  if (event?.type === "run_start") return { ...event, ...recording.startFields };
  if (event?.type !== "run_result") return event;
  const fold = recording.recorder.fold;
  const { checks, ...result } = event;
  fold.apply(result, new Date(now()).toISOString());
  return {
    ...result,
    checks: checkRun({
      events: [...log.events(), result], evidenceDir, malformedLines: 0,
      record: fold.snapshot(), question: recording.question,
    }),
  };
}

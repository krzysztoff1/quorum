import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { QUESTION_SCHEMA, type Question, type RunRecord } from "../src/record/schema.js";
import { foldFixture } from "./recordSupport.js";

export const STORE_NOW = Date.parse("2026-10-10T12:00:00.000Z");

export function emptyStore(): string {
  return mkdtempSync(join(tmpdir(), "quorum-store-"));
}

export interface SeededRun {
  questionId: string;
  runId: string;
  runDir: string;
  record: RunRecord;
}

export interface Seed {
  questionId?: string;
  runId?: string;
  title?: string;
  createdAt?: string;
  status?: RunRecord["status"];
  pid?: number;
  heartbeatAt?: string;
  recordSchema?: string;
}

export function seedRun(storeDir: string, seed: Seed = {}): SeededRun {
  const questionId = seed.questionId ?? "01QUESTION000000000000000A";
  const runId = seed.runId ?? "01RUN0000000000000000000A";
  const base = foldFixture("run-validated-transcript.ndjson");
  const createdAt = seed.createdAt ?? "2026-10-10T11:00:00.000Z";
  const record: RunRecord = {
    ...base,
    id: runId,
    question_id: questionId,
    created_at: createdAt,
    updated_at: seed.heartbeatAt ?? createdAt,
    status: seed.status ?? "running",
    ...(seed.status && seed.status !== "running" ? { finished_at: createdAt } : {}),
    pipeline: {
      ...base.pipeline,
      ...(seed.pid === undefined ? {} : { pid: seed.pid }),
      ...(seed.heartbeatAt === undefined ? {} : { heartbeat_at: seed.heartbeatAt }),
    },
  };
  if (seed.status === "running" || seed.status === undefined) delete (record as { finished_at?: string }).finished_at;
  const question: Question = {
    schema: QUESTION_SCHEMA, id: questionId, created_at: createdAt, original_text: "q", resolved_text: "q",
    language: "en", title: seed.title ?? "A seeded question", title_source: "question", run_ids: [runId],
  };
  const questionDir = join(storeDir, "questions", questionId);
  const runDir = join(questionDir, "runs", runId);
  mkdirSync(runDir, { recursive: true });
  const written = seed.recordSchema ? { ...record, schema: seed.recordSchema } : record;
  writeFileSync(join(runDir, "run.json"), JSON.stringify(written, null, 2));
  writeFileSync(join(questionDir, "question.json"), JSON.stringify(question, null, 2));
  return { questionId, runId, runDir, record };
}

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { Sink } from "../emitter.js";
import { RecordFold } from "./build.js";
import { answerFileName, exportMarkdown } from "./export.js";
import { ulid } from "./ids.js";
import { titleFromQuestion } from "./title.js";
import { QUESTION_SCHEMA, type Brief, type Question, type RunRecord } from "./schema.js";

export const RUN_FILE = "run.json";
export const QUESTION_FILE = "question.json";
export const ANSWERS_DIR = "answers";

export interface RecordLayout {
  runDir: string;
  questionDir?: string;
  brainDir?: string;
}

const QUIET_TYPES = new Set(["stream_event", "assistant", "user", "system", "result", "usage", "error", "run.progress"]);

export function brainLayout(brainDir: string, questionId: string, runId: string): RecordLayout {
  const questionDir = join(brainDir, "questions", questionId);
  return { brainDir, questionDir, runDir: join(questionDir, "runs", runId) };
}

export function newQuestion(id: string, createdAt: string, brief: Brief, runId: string): Question {
  const fromQuestion = titleFromQuestion(brief.question);
  const title = brief.title ?? fromQuestion;
  return {
    schema: QUESTION_SCHEMA, id, created_at: createdAt, original_text: brief.asked ?? brief.question, resolved_text: brief.question,
    language: brief.language, title, title_source: title === fromQuestion ? "question" : "scope", run_ids: [runId],
  };
}

export function writeJsonAtomic(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.tmp-${process.pid}`;
  writeFileSync(temporary, JSON.stringify(value, null, 2) + "\n");
  renameSync(temporary, path);
}

export interface StoredRun {
  record: RunRecord | undefined;
  question: Question | undefined;
  problem: string | undefined;
}

export function readStoredRun(runDir: string): StoredRun {
  const runPath = join(runDir, RUN_FILE);
  const questionPath = join(runDir, "..", "..", QUESTION_FILE);
  let record: RunRecord | undefined;
  let question: Question | undefined;
  let problem: string | undefined;
  if (existsSync(runPath)) {
    try {
      record = JSON.parse(readFileSync(runPath, "utf8"));
    } catch (error) {
      problem = `run.json cannot be read: ${error instanceof Error ? error.message : String(error)}`;
    }
  }
  if (existsSync(questionPath)) {
    try {
      question = JSON.parse(readFileSync(questionPath, "utf8"));
    } catch (error) {
      problem ??= `question.json cannot be read: ${error instanceof Error ? error.message : String(error)}`;
    }
  }
  return { record, question, problem };
}

export class RunRecorder {
  constructor(
    readonly fold: RecordFold,
    readonly question: Question,
    private readonly layout: RecordLayout | undefined,
    private readonly clock: () => string,
  ) {}

  start(): void {
    if (this.layout?.questionDir) writeJsonAtomic(join(this.layout.questionDir, QUESTION_FILE), this.question);
  }

  tee(downstream: Sink): Sink {
    return (line) => {
      this.observe(line);
      downstream(line);
    };
  }

  crash(note: string): void {
    this.fold.crash(this.clock(), note);
    this.write();
  }

  abandon(status: "cancelled" | "crashed", note: string): void {
    this.fold.abandon(status, this.clock(), note);
    this.write();
  }

  finish(): string | undefined {
    const record = this.write();
    if (!this.layout?.brainDir) return undefined;
    const path = join(this.layout.brainDir, ANSWERS_DIR, answerFileName(this.question));
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, exportMarkdown(record, this.question));
    return path;
  }

  private observe(line: string): void {
    let event: any;
    try {
      event = JSON.parse(line);
    } catch {
      return;
    }
    this.fold.apply(event, this.clock());
    if (!QUIET_TYPES.has(event?.type)) this.write();
  }

  private write(): RunRecord {
    const record = this.fold.snapshot();
    if (this.layout) writeJsonAtomic(join(this.layout.runDir, RUN_FILE), record);
    return record;
  }
}

export interface RecordingInput {
  brief: Brief;
  brainDir?: string;
  runDir?: string;
  models: RunRecord["pipeline"]["models"];
  limits: RunRecord["limits"];
  now: () => number;
  newId?: () => string;
  ids?: { questionId: string; runId: string };
}

export interface Recording {
  layout: RecordLayout | undefined;
  runDir: string | undefined;
  question: Question;
  recorder: RunRecorder;
  startFields: Record<string, string>;
}

export function openRecording(input: RecordingInput): Recording {
  const at = () => new Date(input.now()).toISOString();
  const newId = input.newId ?? (() => ulid(input.now()));
  const questionId = input.ids?.questionId ?? newId();
  const runId = input.ids?.runId ?? newId();
  const layout: RecordLayout | undefined = input.brainDir
    ? brainLayout(input.brainDir, questionId, runId)
    : input.runDir ? { runDir: input.runDir } : undefined;
  const question = newQuestion(questionId, at(), input.brief, runId);
  const fold = new RecordFold({
    runId, questionId, kind: "initial", createdAt: question.created_at, brief: input.brief,
    models: input.models, limits: input.limits, transcripts: Boolean(layout),
  });
  const recorder = new RunRecorder(fold, question, layout, at);
  recorder.start();
  return {
    layout,
    runDir: layout?.runDir,
    question,
    recorder,
    startFields: layout ? { run_id: runId, question_id: questionId, run_dir: layout.runDir } : {},
  };
}

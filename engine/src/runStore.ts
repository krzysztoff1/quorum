import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { QUESTION_FILE, RUN_FILE } from "./record/store.js";

export interface StoredEntry {
  questionId: string;
  runId: string;
  questionDir: string;
  runDir: string;
  record: any;
  question: any;
  recordProblem: string | undefined;
  questionProblem: string | undefined;
}

export function scanStore(storeDir: string): StoredEntry[] {
  const questionsDir = join(storeDir, "questions");
  if (!existsSync(questionsDir)) return [];
  const entries: StoredEntry[] = [];
  for (const questionId of readdirSync(questionsDir)) {
    const questionDir = join(questionsDir, questionId);
    const runsDir = join(questionDir, "runs");
    if (!existsSync(runsDir)) continue;
    const question = readJson(join(questionDir, QUESTION_FILE));
    for (const runId of readdirSync(runsDir)) {
      const runDir = join(runsDir, runId);
      const record = readJson(join(runDir, RUN_FILE));
      entries.push({
        questionId, runId, questionDir, runDir,
        record: record.value, question: question.value,
        recordProblem: record.problem, questionProblem: question.problem,
      });
    }
  }
  return entries;
}

export function findRun(storeDir: string, runId: string): StoredEntry | undefined {
  return scanStore(storeDir).find((entry) => entry.runId === runId);
}

function readJson(path: string): { value: any; problem: string | undefined } {
  if (!existsSync(path)) return { value: undefined, problem: `${path} is missing` };
  try {
    return { value: JSON.parse(readFileSync(path, "utf8")), problem: undefined };
  } catch (error) {
    return { value: undefined, problem: `${path} cannot be read: ${error instanceof Error ? error.message : String(error)}` };
  }
}

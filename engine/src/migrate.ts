import { join } from "node:path";
import { QUESTION_FILE, RUN_FILE, writeJsonAtomic } from "./record/store.js";
import { QUESTION_SCHEMA, RECORD_SCHEMA } from "./record/schema.js";
import { scanStore } from "./runStore.js";

export interface Migration {
  to: string;
  upgrade: (record: any) => any;
}

export type Migrations = Record<string, Migration>;

export const MIGRATIONS: Migrations = {};

export interface MigrationReport {
  scanned: number;
  current: number;
  upgraded: Array<{ kind: "run" | "question"; id: string; from: string; to: string }>;
  unknown: Array<{ kind: "run" | "question"; id: string; schema: string }>;
  unreadable: Array<{ path: string; problem: string }>;
}

const CURRENT = new Set([RECORD_SCHEMA, QUESTION_SCHEMA]);

type Outcome = { state: "current" } | { state: "upgraded"; from: string; to: string; record: any } | { state: "unknown"; schema: string };

function upgradeToCurrent(record: any, migrations: Migrations): Outcome {
  const from = String(record?.schema);
  if (CURRENT.has(from)) return { state: "current" };
  let working = record;
  let schema = from;
  while (!CURRENT.has(schema)) {
    const step = migrations[schema];
    if (!step) return { state: "unknown", schema: from };
    working = { ...step.upgrade(working), schema: step.to };
    schema = step.to;
  }
  return { state: "upgraded", from, to: schema, record: working };
}

export function migrateStore(storeDir: string, migrations: Migrations = MIGRATIONS): MigrationReport {
  const report: MigrationReport = { scanned: 0, current: 0, upgraded: [], unknown: [], unreadable: [] };
  const questionsSeen = new Set<string>();
  for (const entry of scanStore(storeDir)) {
    const files = [
      { kind: "run" as const, id: entry.runId, path: join(entry.runDir, RUN_FILE), value: entry.record, problem: entry.recordProblem },
      { kind: "question" as const, id: entry.questionId, path: join(entry.questionDir, QUESTION_FILE), value: entry.question, problem: entry.questionProblem },
    ];
    for (const file of files) {
      if (file.kind === "question") {
        if (questionsSeen.has(file.id)) continue;
        questionsSeen.add(file.id);
      }
      if (!file.value) {
        report.unreadable.push({ path: file.path, problem: file.problem ?? `${file.path} is missing` });
        continue;
      }
      report.scanned += 1;
      const outcome = upgradeToCurrent(file.value, migrations);
      if (outcome.state === "current") report.current += 1;
      else if (outcome.state === "unknown") report.unknown.push({ kind: file.kind, id: file.id, schema: outcome.schema });
      else {
        writeJsonAtomic(file.path, outcome.record);
        report.upgraded.push({ kind: file.kind, id: file.id, from: outcome.from, to: outcome.to });
      }
    }
  }
  return report;
}

export function pendingMigrations(storeDir: string, migrations: Migrations = MIGRATIONS): number {
  let waiting = 0;
  const questionsSeen = new Set<string>();
  for (const entry of scanStore(storeDir)) {
    const values = questionsSeen.has(entry.questionId) ? [entry.record] : [entry.record, entry.question];
    questionsSeen.add(entry.questionId);
    for (const value of values) {
      if (value && upgradeToCurrent(value, migrations).state === "upgraded") waiting += 1;
    }
  }
  return waiting;
}

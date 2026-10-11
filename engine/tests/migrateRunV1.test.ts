import { describe, expect, it } from "vitest";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { MIGRATIONS, migrateStore, pendingMigrations } from "../src/migrate.js";
import { RECORD_SCHEMA, RunRecordSchema, type RunRecord } from "../src/record/schema.js";
import { emptyStore } from "./storeSupport.js";

const LEGACY = JSON.parse(readFileSync(new URL("../fixtures/legacy/run-v1.run.json", import.meta.url), "utf8"));

const SCOPED_BRIEF = {
  question: "Does prompt caching pay for a chat product?",
  language: "en",
  asked: "does prompt caching pay for chat",
  title: "Does prompt caching pay for a chat product?",
  tier: "deep",
  suggested_tier: "quick",
  tier_reason: "a cost question with several unknowns",
  clarifications: [{ question: "Which provider?", options: ["Anthropic"], answer: "Anthropic" }],
};

function writeLegacyStore(record: object): { store: string; runPath: string } {
  const store = emptyStore();
  const questionDir = join(store, "questions", "Q1");
  const runDir = join(questionDir, "runs", "R1");
  mkdirSync(runDir, { recursive: true });
  writeFileSync(join(runDir, "run.json"), JSON.stringify(record));
  writeFileSync(join(questionDir, "question.json"), JSON.stringify({
    schema: "quorum.question/1", id: "Q1", created_at: "2026-10-09T10:00:00.000Z", original_text: "q", resolved_text: "q",
    language: "en", title: "A title", title_source: "question", run_ids: ["R1"],
  }));
  return { store, runPath: join(runDir, "run.json") };
}

describe("a quorum.run/1 record migrates to quorum.run/2 instead of vanishing", () => {
  it("is registered, and counted as waiting", () => {
    expect(MIGRATIONS["quorum.run/1"]?.to).toBe(RECORD_SCHEMA);
    expect(pendingMigrations(writeLegacyStore(LEGACY).store)).toBe(1);
  });

  it("rebuilds the answer as a spec from its markdown, drops format, and parses as the current record", () => {
    const { store, runPath } = writeLegacyStore(LEGACY);

    const report = migrateStore(store);

    expect(report.upgraded).toEqual([{ kind: "run", id: "R1", from: "quorum.run/1", to: RECORD_SCHEMA }]);
    const migrated = JSON.parse(readFileSync(runPath, "utf8"));
    expect(RunRecordSchema.safeParse(migrated).success).toBe(true);
    expect(migrated.schema).toBe(RECORD_SCHEMA);
    expect(migrated.answer).not.toHaveProperty("format");
    expect(migrated.answer).toMatchObject({ catalog: "qvs/1", origin: "prose", task_id: LEGACY.answer.task_id, headline: LEGACY.answer.headline });
    expect(migrated.answer.markdown).toContain("Body for synthesis.[^a1c1]");
    expect(migrated.answer.spec.elements.answer.props.lead).toContain("Body for synthesis.");
    expect(migrated.stats).toMatchObject({ visuals: 0, datums: 0, datums_unverified: 0, claims: LEGACY.stats.claims });
  });

  it("gives each claim the element it was written in", () => {
    const { store, runPath } = writeLegacyStore(LEGACY);
    migrateStore(store);
    const migrated = JSON.parse(readFileSync(runPath, "utf8")) as RunRecord;
    for (const claim of migrated.claims) expect(migrated.answer!.spec.elements).toHaveProperty(claim.element_id!);
  });

  it("carries the scoping brief and the rest of the record across untouched", () => {
    const { store, runPath } = writeLegacyStore({ ...LEGACY, brief: SCOPED_BRIEF });
    migrateStore(store);
    const migrated = JSON.parse(readFileSync(runPath, "utf8"));
    expect(migrated.brief).toEqual(SCOPED_BRIEF);
    expect(migrated.citations).toEqual(LEGACY.citations);
    expect(migrated.tasks).toEqual(LEGACY.tasks);
    expect(migrated.checks).toEqual(LEGACY.checks);
  });

  it("migrates a run that never produced an answer", () => {
    const { answer: _answer, ...unanswered } = LEGACY;
    const { store, runPath } = writeLegacyStore({ ...unanswered, claims: [], status: "inconclusive" });
    migrateStore(store);
    const migrated = JSON.parse(readFileSync(runPath, "utf8"));
    expect(RunRecordSchema.safeParse(migrated).success).toBe(true);
    expect(migrated).not.toHaveProperty("answer");
    expect(migrated.stats).toMatchObject({ visuals: 0, datums: 0, datums_unverified: 0 });
  });
});

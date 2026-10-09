import { describe, expect, it } from "vitest";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { migrateStore, pendingMigrations, type Migrations } from "../src/migrate.js";
import { QUESTION_SCHEMA, RECORD_SCHEMA } from "../src/record/schema.js";
import { emptyStore, seedRun } from "./storeSupport.js";

const OLD = "quorum.run/0";
const upgradeFromZero: Migrations = {
  [OLD]: { to: RECORD_SCHEMA, upgrade: (record) => ({ ...record, stats_note: "migrated from /0" }) },
};

describe("quorum-engine migrate", () => {
  it("has nothing to do for a store that is already current, and does not rewrite it", () => {
    const store = emptyStore();
    const { runDir } = seedRun(store, { status: "complete" });
    const before = readFileSync(join(runDir, "run.json"), "utf8");

    expect(migrateStore(store, {})).toEqual({ scanned: 2, current: 2, upgraded: [], unknown: [], unreadable: [] });
    expect(readFileSync(join(runDir, "run.json"), "utf8")).toBe(before);
  });

  it("upgrades a record written under an older schema in place and says what it did", () => {
    const store = emptyStore();
    const { runDir, runId } = seedRun(store, { status: "complete", recordSchema: OLD });

    const report = migrateStore(store, upgradeFromZero);

    expect(report.upgraded).toEqual([{ kind: "run", id: runId, from: OLD, to: RECORD_SCHEMA }]);
    const record = JSON.parse(readFileSync(join(runDir, "run.json"), "utf8"));
    expect(record).toMatchObject({ schema: RECORD_SCHEMA, stats_note: "migrated from /0" });
  });

  it("chains migrations until the record is current", () => {
    const store = emptyStore();
    const { runDir } = seedRun(store, { status: "complete", recordSchema: "quorum.run/minus-one" });
    const chain: Migrations = {
      "quorum.run/minus-one": { to: OLD, upgrade: (record) => ({ ...record, hops: ["minus-one"] }) },
      [OLD]: { to: RECORD_SCHEMA, upgrade: (record) => ({ ...record, hops: [...record.hops, "zero"] }) },
    };

    migrateStore(store, chain);

    expect(JSON.parse(readFileSync(join(runDir, "run.json"), "utf8")).hops).toEqual(["minus-one", "zero"]);
  });

  it("leaves a record from a newer engine alone and reports it, rather than guessing at its shape", () => {
    const store = emptyStore();
    const { runDir, runId } = seedRun(store, { status: "complete", recordSchema: "quorum.run/9" });
    const before = readFileSync(join(runDir, "run.json"), "utf8");

    const report = migrateStore(store, upgradeFromZero);

    expect(report.unknown).toEqual([{ kind: "run", id: runId, schema: "quorum.run/9" }]);
    expect(readFileSync(join(runDir, "run.json"), "utf8")).toBe(before);
  });

  it("reports a record that cannot be read instead of aborting the rest", () => {
    const store = emptyStore();
    const { runDir } = seedRun(store, { status: "complete" });
    writeFileSync(join(runDir, "run.json"), "{ nope");
    seedRun(store, { questionId: "Q2", runId: "R2", status: "complete", recordSchema: OLD });

    const report = migrateStore(store, upgradeFromZero);

    expect(report.unreadable).toHaveLength(1);
    expect(report.upgraded).toHaveLength(1);
  });

  it("upgrades question records through the same table", () => {
    const store = emptyStore();
    const seeded = seedRun(store, { status: "complete" });
    const questionPath = join(seeded.runDir, "..", "..", "question.json");
    const question = JSON.parse(readFileSync(questionPath, "utf8"));
    writeFileSync(questionPath, JSON.stringify({ ...question, schema: "quorum.question/0" }));
    const table: Migrations = {
      "quorum.question/0": { to: QUESTION_SCHEMA, upgrade: (record) => ({ ...record, title_source: "question" }) },
    };

    expect(migrateStore(store, table).upgraded).toEqual([
      { kind: "question", id: seeded.questionId, from: "quorum.question/0", to: QUESTION_SCHEMA },
    ]);
  });

  it("counts what is waiting without touching it", () => {
    const store = emptyStore();
    seedRun(store, { status: "complete", recordSchema: OLD });
    seedRun(store, { questionId: "Q2", runId: "R2", status: "complete" });

    expect(pendingMigrations(store, upgradeFromZero)).toBe(1);
  });
});

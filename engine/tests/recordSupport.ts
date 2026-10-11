import { readFileSync } from "node:fs";
import { join } from "node:path";
import { briefFromQuestion } from "../src/record/brief.js";
import { RecordFold, type RecordContext } from "../src/record/build.js";
import type { RunRecord } from "../src/record/schema.js";
import { FIXTURES_DIR } from "./fixtureSupport.js";

export const FOLD_CONTEXT: RecordContext = {
  runId: "01K7A0000000000000000RUN01",
  questionId: "01K7A0000000000000000QST01",
  kind: "initial",
  createdAt: "2026-10-09T10:00:00.000Z",
  brief: briefFromQuestion("Does prompt caching pay for a chat product?"),
  models: { planner: "claude-code/claude-haiku-4-5", research: "claude-code/claude-haiku-4-5",
            synthesis: "claude-code/claude-haiku-4-5", validator: "claude-code/claude-haiku-4-5" },
  limits: { cap_usd: 20, deadline_s: 1800 },
  transcripts: true,
};

const FINISHED_AT = "2026-10-09T10:04:30.000Z";

export function foldFixture(name: string, events = fixtureEvents(name)): RunRecord {
  const fold = new RecordFold(FOLD_CONTEXT);
  for (const event of events) fold.apply(event, FINISHED_AT);
  return fold.snapshot();
}

export function fixtureEvents(name: string): any[] {
  return readFileSync(join(FIXTURES_DIR, name), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
}


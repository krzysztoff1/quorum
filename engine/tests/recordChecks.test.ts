import { describe, expect, it } from "vitest";
import { checkRecord } from "../src/record/checks.js";
import type { Question, RunRecord } from "../src/record/schema.js";
import { foldFixture } from "./recordSupport.js";

const QUESTION: Question = {
  schema: "quorum.question/1", id: "q", created_at: "2026-10-09T10:00:00.000Z",
  original_text: "Does prompt caching pay?", resolved_text: "Does prompt caching pay?", language: "en",
  title: "Does prompt caching pay", title_source: "question", run_ids: ["r"],
};

function statusOf(record: RunRecord, id: string, question: Question | null = QUESTION): string | undefined {
  return checkRecord({ record, question: question ?? undefined }).find((c) => c.id === id)?.status;
}

function detailOf(record: RunRecord, id: string, question: Question | null = QUESTION): string {
  return checkRecord({ record, question: question ?? undefined }).find((c) => c.id === id)?.detail ?? "";
}

describe("checkRecord", () => {
  const record = foldFixture("mock-run.ndjson");

  it("passes a record the engine wrote", () => {
    const failures = checkRecord({ record, question: QUESTION }).filter((c) => c.status === "fail");
    expect(failures).toEqual([]);
  });

  it("fails a record the schema rejects", () => {
    expect(statusOf({ ...record, status: "finished" as any }, "schema")).toBe("fail");
  });

  it("fails stored stats that no longer recompute from the record", () => {
    expect(statusOf({ ...record, stats: { ...record.stats, sources_cited: 99 } }, "stats")).toBe("fail");
    expect(detailOf({ ...record, stats: { ...record.stats, sources_cited: 99 } }, "stats")).toContain("sources_cited");
  });

  it("fails a source flagged cited that the answer never cites", () => {
    const sources = record.sources.map((s, i) => (i === 0 ? { ...s, cited: !s.cited } : s));
    expect(statusOf({ ...record, sources }, "stats")).toBe("fail");
  });

  it("fails an answer marker that names no citation", () => {
    const answer = { ...record.answer!, markdown: record.answer!.markdown + " Extra.[^a1c17]" };
    expect(statusOf({ ...record, answer }, "references")).toBe("fail");
    expect(detailOf({ ...record, answer }, "references")).toContain("[^a1c17]");
  });

  it("fails a citation whose source the record does not hold", () => {
    const citations = record.citations.map((c, i) => (i === 0 ? { ...c, source_id: "s-missing" } : c));
    expect(statusOf({ ...record, citations }, "references")).toBe("fail");
  });

  it("warns, rather than fails, when the engine stripped a dangling marker", () => {
    const stripped = { ...record, stripped_markers: [{ task_id: "a1", marker: "a1c17" }] };
    expect(statusOf(stripped, "references")).toBe("warn");
    expect(detailOf(stripped, "references")).toContain("[^a1c17] stripped from a1");
  });

  it("fails a complete run with no answer", () => {
    const { answer, ...rest } = record;
    expect(statusOf({ ...rest, status: "complete" }, "answer")).toBe("fail");
  });

  it("fails a question titled after a clarifier", () => {
    expect(statusOf(record, "title", { ...QUESTION, title: "Could you clarify what you mean?" })).toBe("fail");
  });

  it("warns when there is no question file to check the title against", () => {
    expect(statusOf(record, "title", null)).toBe("warn");
  });

  it("warns when the answer is not in the question's language", () => {
    const polish = { ...record, brief: { ...record.brief, language: "pl" } };
    expect(statusOf(polish, "language")).toBe("warn");
    expect(statusOf(record, "language")).toBe("pass");
  });

  it("warns when the run went over its cap or its deadline", () => {
    expect(statusOf({ ...record, limits: { cap_usd: 1 } }, "limits")).toBe("warn");
    expect(statusOf({ ...record, limits: { cap_usd: 100, deadline_s: 10 } }, "limits")).toBe("warn");
    expect(statusOf({ ...record, limits: { cap_usd: 100, deadline_s: 1000 } }, "limits")).toBe("pass");
  });
});

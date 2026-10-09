import { describe, expect, it } from "vitest";
import { checkRecord } from "../src/record/checks.js";
import type { Question, RunRecord } from "../src/record/schema.js";
import { foldFixture } from "./recordSupport.js";
import { settleAnswer } from "../src/answer/index.js";
import { citedSourceIds, computeStats } from "../src/record/stats.js";
import { adsChart, answer, CITATIONS, claim } from "./answerSupport.js";

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

  it("fails a title scoping wrote after a clarifier", () => {
    expect(statusOf(record, "title", { ...QUESTION, title: "Could you clarify what you mean?", title_source: "scope" })).toBe("fail");
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
  it("passes a question titled from a question that politely asks", () => {
    expect(statusOf(record, "title", { ...QUESTION, title: "Can you compare Postgres and MySQL for OLTP" })).toBe("pass");
  });

  it("does not demand a captured source behind a quote nobody could locate", () => {
    const citations = [...record.citations, { id: "zz1", source_id: "https://never.fetched/page", quote: "q", match: "unresolved" as const, task_id: "a1" }];
    expect(statusOf({ ...record, citations }, "references")).toBe("pass");
  });
});

describe("the answer spec's invariants", () => {
  const base = foldFixture("mock-run.ndjson");
  const charted = withChartAnswer(base);
  const status = (record: RunRecord) => checkRecord({ record, question: QUESTION }).find((c) => c.id === "spec");

  it("passes a spec the engine settled", () => {
    expect(status(charted)).toMatchObject({ status: "pass" });
    expect(status(charted)!.detail).toContain("1 visual");
  });

  it("fails a visual with no display or no fallback text", () => {
    const answer = { ...charted.answer!, display: {}, fallback_md: {} };
    expect(status({ ...charted, answer })!.status).toBe("fail");
    expect(status({ ...charted, answer })!.detail).toContain("g1_1 has no display");
  });

  it("fails a datum whose trust claims more than its quote shows", () => {
    const answer = structuredClone(charted.answer!);
    (answer.spec.elements.g1_1 as any).props.bars[2].value.trust = { tier: "supported", trace: "quoted", confidence: "high" };
    expect(status({ ...charted, answer })!.detail).toContain("trace");
  });

  it("fails a fourth visual", () => {
    const answer = structuredClone(charted.answer!);
    const elements = answer.spec.elements as any;
    for (const n of [2, 3, 4]) {
      elements[`extra${n}`] = elements.g1_1;
      elements[`group${n}`] = { type: "Group", props: { title: "x" }, children: [`extra${n}`] };
      elements.answer.children.push(`group${n}`);
    }
    expect(status({ ...charted, answer })!.status).toBe("fail");
  });

  it("fails a datum citing a quote the record does not hold", () => {
    const answer = structuredClone(charted.answer!);
    (answer.spec.elements.g1_1 as any).props.bars[0].value.cite = ["zz9"];
    expect(checkRecord({ record: { ...charted, answer }, question: QUESTION }).find((c) => c.id === "references")!.detail).toContain("zz9");
  });
});

function withChartAnswer(record: RunRecord): RunRecord {
  const sourceId = record.sources[0]!.id;
  const citations = [
    ...record.citations,
    ...CITATIONS.map((c) => ({ ...c, source_id: sourceId, task_id: record.answer!.task_id })),
  ] as RunRecord["citations"];
  const draft = draftFromSpec(answer({ g1: [claim("Ads[^a1c4]."), adsChart()] }));
  const settled = settleAnswer(draft, { citations, sources: [{ id: sourceId, source_type: "primary" }], grounding: "captured" });
  const answerRecord = { ...record.answer!, ...settled, catalog: "qvs/1" as const };
  const draftRecord = { ...record, citations, answer: answerRecord, claims: [] };
  const sources = draftRecord.sources.map((s) => ({ ...s, cited: citedSourceIds(draftRecord).has(s.id) }));
  const { stats, checks, ...rest } = { ...draftRecord, sources };
  return { ...rest, stats: computeStats(rest), checks };
}

function draftFromSpec(spec: ReturnType<typeof answer>) {
  return { spec, origin: "spec" as const, actions: [], dropped: [], stripped: [], issues: [] };
}

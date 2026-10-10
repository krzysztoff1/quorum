import { describe, expect, it } from "vitest";
import { checkRecord } from "../src/record/checks.js";
import type { Question, RunRecord } from "../src/record/schema.js";
import { foldFixture } from "./recordSupport.js";

const QUESTION: Question = {
  schema: "quorum.question/1", id: "q", created_at: "2026-10-09T10:00:00.000Z",
  original_text: "Does prompt caching pay?", resolved_text: "Does prompt caching pay?", language: "en",
  title: "Does prompt caching pay for a chat product", title_source: "question", run_ids: ["r"],
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
    expect(statusOf(polish, "language", { ...QUESTION, language: "pl" })).toBe("warn");
    expect(statusOf(record, "language")).toBe("pass");
  });

  describe("title and language, from scoping", () => {
    const polish = {
      ...record,
      brief: { ...record.brief, asked: "fuzja", question: "Czy fuzja jądrowa osiągnęła próg opłacalności energetycznej?",
               title: "Fuzja jądrowa: próg opłacalności", language: "pl", tier: "quick" as const },
    };
    const polishQuestion: Question = {
      ...QUESTION, original_text: "fuzja", resolved_text: polish.brief.question, language: "pl",
      title: "Fuzja jądrowa: próg opłacalności", title_source: "scope",
    };

    it("passes a title that is the brief's title, in the brief's language", () => {
      expect(statusOf({ ...polish, answer: undefined } as RunRecord, "title", polishQuestion)).toBe("pass");
      expect(statusOf({ ...polish, answer: undefined } as RunRecord, "language", polishQuestion)).toBe("pass");
    });

    it("fails a question titled with anything but the brief's title", () => {
      const retitled = { ...polishQuestion, title: "Zanim zacznę, chciałbym doprecyzować" };
      expect(statusOf(polish, "title", retitled)).toBe("fail");
      expect(detailOf(polish, "title", retitled)).toContain("Fuzja jądrowa: próg opłacalności");
      expect(statusOf(polish, "title", { ...polishQuestion, title: "Nuclear fusion break-even" })).toBe("fail");
    });

    it("fails a question whose language is not the brief's language", () => {
      expect(statusOf(polish, "language", { ...polishQuestion, language: "en" })).toBe("fail");
    });

    it("warns when the title reads as another language than the brief's", () => {
      const english = { ...polish, brief: { ...polish.brief, title: "What are the requirements for health data in the apps" } };
      const q = { ...polishQuestion, title: english.brief.title };
      expect(statusOf({ ...english, answer: undefined } as RunRecord, "language", q)).toBe("warn");
    });

    it("warns for a Polish brief whose answer came back English", () => {
      expect(statusOf(polish, "language", polishQuestion)).toBe("warn");
    });
  });

  it("warns when the run went over its cap or its deadline", () => {
    expect(statusOf({ ...record, limits: { cap_usd: 1 } }, "limits")).toBe("warn");
    expect(statusOf({ ...record, limits: { cap_usd: 100, deadline_s: 10 } }, "limits")).toBe("warn");
    expect(statusOf({ ...record, limits: { cap_usd: 100, deadline_s: 1000 } }, "limits")).toBe("pass");
  });
  it("passes a question titled from a question that politely asks", () => {
    const polite = { ...record, brief: { ...record.brief, title: "Can you compare Postgres and MySQL for OLTP" } };
    expect(statusOf(polite, "title", { ...QUESTION, title: "Can you compare Postgres and MySQL for OLTP" })).toBe("pass");
  });

  it("does not demand a captured source behind a quote nobody could locate", () => {
    const citations = [...record.citations, { id: "zz1", source_id: "https://never.fetched/page", quote: "q", match: "unresolved" as const, task_id: "a1" }];
    expect(statusOf({ ...record, citations }, "references")).toBe("pass");
  });
});

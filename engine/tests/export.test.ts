import { describe, expect, it } from "vitest";
import { exportMarkdown, answerFileName } from "../src/record/export.js";
import type { Question, RunRecord } from "../src/record/schema.js";
import { foldFixture } from "./recordSupport.js";
import { matchFixture } from "./fixtureSupport.js";

const QUESTION: Question = {
  schema: "quorum.question/1",
  id: "01K7A0000000000000000QST01",
  created_at: "2026-10-09T10:00:00.000Z",
  original_text: "Does prompt caching pay for a chat product?",
  resolved_text: "Does prompt caching pay for a chat product?",
  language: "en",
  title: "Does prompt caching pay for a chat product",
  title_source: "question",
  run_ids: ["01K7A0000000000000000RUN01"],
};

const MARKER = /\[\^([A-Za-z0-9_-]{1,32})\](?!:)/g;
const DEFINITION = /^\[\^([A-Za-z0-9_-]{1,32})\]:/gm;

function markersAndDefinitions(markdown: string): { markers: Set<string>; definitions: string[] } {
  return {
    markers: new Set([...markdown.matchAll(MARKER)].map((m) => m[1]!)),
    definitions: [...markdown.matchAll(DEFINITION)].map((m) => m[1]!),
  };
}

describe("exportMarkdown", () => {
  it("matches the recorded export of the multi-round mock run", () => {
    matchFixture("record/mock-run.md", exportMarkdown(foldFixture("mock-run.ndjson"), QUESTION));
  });

  it("defines every footnote marker it uses, exactly once, and nothing it does not use", () => {
    const markdown = exportMarkdown(foldFixture("mock-run.ndjson"), QUESTION);
    const { markers, definitions } = markersAndDefinitions(markdown);
    expect(markers.size).toBeGreaterThan(5);
    expect(new Set(definitions)).toEqual(markers);
    expect(definitions.length).toBe(new Set(definitions).size);
  });

  it("opens with frontmatter taken from the question, the brief and the stats", () => {
    const record = foldFixture("mock-run.ndjson");
    const markdown = exportMarkdown(record, QUESTION);
    expect(markdown.startsWith("---\n")).toBe(true);
    const frontmatter = markdown.slice(4, markdown.indexOf("\n---\n", 4));
    expect(frontmatter).toContain('title: "Does prompt caching pay for a chat product"');
    expect(frontmatter).toContain(`trust: ${record.stats.trust_level}`);
    expect(frontmatter).toContain(`sources_cited: ${record.stats.sources_cited}`);
    expect(frontmatter).toContain(`sources_read: ${record.stats.sources_read}`);
    expect(frontmatter).toContain("date: 2026-10-09");
    expect(frontmatter).toContain(`run: ${record.id}`);
  });

  it("lists the open items: conflicts with both sides, standing objections, gaps and failed tasks", () => {
    const markdown = exportMarkdown(foldFixture("mock-run.ndjson"), QUESTION);
    expect(markdown).toContain("## Open items");
    expect(markdown).toMatch(/### Conflicts\n\n- \*\*.+\*\* — .+ · .+/);
    expect(markdown).toContain("### Objections still standing");
    expect(markdown).toContain("### Gaps");
    expect(markdown).toContain("### Tasks that did not finish");
  });

  it("strips a marker that names no citation rather than leaving it undefined", () => {
    const record = foldFixture("mock-run.ndjson");
    const dangling: RunRecord = { ...record, answer: { ...record.answer!, markdown: "A claim.[^zz9] Another.[^a1c1]" } };
    const { markers, definitions } = markersAndDefinitions(exportMarkdown(dangling, QUESTION));
    expect(markers).toEqual(new Set(["a1c1"]));
    expect(definitions).toEqual(["a1c1"]);
  });

  it("says plainly when nothing could be checked", () => {
    const record = foldFixture("mock-run.ndjson");
    const unchecked: RunRecord = { ...record, pipeline: { ...record.pipeline, grounding: "none" } };
    expect(exportMarkdown(unchecked, QUESTION)).toContain("No evidence was captured for this run");
  });

  it("falls back to the brief when the question file is missing", () => {
    const markdown = exportMarkdown(foldFixture("mock-run.ndjson"), undefined);
    expect(markdown).toContain('title: "Does prompt caching pay for a chat product"');
  });

  it("still exports a run that wrote no answer", () => {
    const record = foldFixture("mock-run.ndjson");
    const { answer, ...withoutAnswer } = record;
    expect(exportMarkdown({ ...withoutAnswer, status: "inconclusive", status_note: "Planning failed." }, QUESTION))
      .toContain("> No answer was written: Planning failed.");
  });
});

describe("answerFileName", () => {
  it("is the title as a slug with the question id's tail, so two titles never collide", () => {
    expect(answerFileName(QUESTION)).toBe("does-prompt-caching-pay-for-a-chat-product-qst01.md");
  });

  it("keeps letters outside ASCII", () => {
    expect(answerFileName({ ...QUESTION, title: "Wymagania RODO dla danych o zdrowiu" }))
      .toBe("wymagania-rodo-dla-danych-o-zdrowiu-qst01.md");
  });
});

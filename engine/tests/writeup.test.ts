import { describe, expect, it } from "vitest";
import { normalizeWriteup } from "../src/record/writeup.js";

function report(preamble: string): string {
  return `${preamble}\n\n## Wynik\n\nTreść raportu.\n\n\`\`\`json\n{"headline":"h","status":"complete","findings":[]}\n\`\`\``;
}

describe("normalizeWriteup", () => {
  it("drops the fenced machine summary", () => {
    expect(normalizeWriteup("Body.[^c1]\n\n```json\n{\"headline\":\"h\"}\n```")).toBe("Body.[^c1]");
  });

  it("drops the leading process narration of the validated run's second angle", () => {
    const final = [
      "I have enough depth now (~13 sources fetched/searched with substantive content). Let me write the final report.",
      "",
      "# Personalization ROI & Monetization in Food Tech",
      "",
      "## Measurable business outcomes",
      "",
      "Delivery Hero reported an 85% jump in conversions.[^c1]",
      "",
      "```json",
      '{"headline":"Personalization drives 5-15% revenue lift","status":"complete","findings":[]}',
      "```",
    ].join("\n");

    const writeup = normalizeWriteup(final);

    expect(writeup).not.toContain("Let me write the final report");
    expect(writeup.startsWith("## Personalization ROI & Monetization in Food Tech")).toBe(true);
    expect(writeup.match(/^# /gm)).toBeNull();
    expect(writeup).toContain("Delivery Hero reported an 85% jump in conversions.[^c1]");
  });

  it("drops every narration variant seen in real runs, in both languages", () => {
    const preambles = [
      "I have enough depth now (~13 sources fetched/searched with substantive content). Let me write the final report.",
      "I have enough now to write a solid, cross-checked report. Let me compile it.",
      "Now I have comprehensive data on all three areas. Let me write the final report.",
      "Excellent! I have everything I need.",
      "Good — the sources agree. Writing it up now.",
      "Mam już wystarczająco dużo źródeł. Teraz napiszę raport.",
      "Teraz napiszę końcowy raport.",
    ];
    for (const preamble of preambles) expect(normalizeWriteup(report(preamble)).startsWith("## Wynik")).toBe(true);
  });

  it("keeps answers that merely open with an interjection word", () => {
    for (const answer of [
      "Great Britain leads the market on regulation.",
      "Good personalization starts with hard allergy filters.",
      "Mamy trzy dominujące architektury rekomendacji.",
    ]) {
      expect(normalizeWriteup(report(answer)).startsWith(answer)).toBe(true);
    }
  });

  it("keeps a narration-shaped paragraph that carries a citation", () => {
    const text = "Now I have the figure: 85% of users convert.[^c1]\n\n## More\n\nBody.";
    expect(normalizeWriteup(text).startsWith("Now I have the figure")).toBe(true);
  });

  it("keeps a body that is nothing but narration rather than emptying it", () => {
    expect(normalizeWriteup("Let me write the final report.\n\n```json\n{\"headline\":\"h\",\"findings\":[]}\n```"))
      .toBe("Let me write the final report.");
  });

  it("strips the appendices the engine adds for the stream", () => {
    const text = [
      "The answer.[^a1c1]",
      "",
      "## Citation check",
      "",
      "⚠️ 1 citation(s) could not be traced",
      "",
      "> ⚠️ **Unvalidated — no evidence was captured for this run.** Its sources were read through built-in web search.",
      "",
      "## Sources",
      "",
      "1. [Doc](https://ex.test) — ✓ verified",
      "",
      "[^a1c1]: [Doc](https://ex.test) — “quote”",
      "",
      "## Validation",
      "",
      "✓ Validated",
      "",
      "```json",
      "{}",
      "```",
    ].join("\n");
    expect(normalizeWriteup(text)).toBe("The answer.[^a1c1]");
  });

  it("strips the unvalidated notice when it directly follows the body", () => {
    const text = "The answer.\n\n> ⚠️ **Unvalidated — no evidence was captured for this run.** Its sources were read.\n\n```json\n{}\n```";
    expect(normalizeWriteup(text)).toBe("The answer.");
  });

  it("leaves a hash comment inside fenced code alone", () => {
    const text = "# Title\n\n```python\n# comment\n```\n\nBody.";
    expect(normalizeWriteup(text)).toBe("## Title\n\n```python\n# comment\n```\n\nBody.");
  });
  it("keeps a heading of the model's own that merely starts like an appendix", () => {
    const text = "Intro.\n\n## Validation approach\n\nHow we checked.\n\n## Sources of disagreement\n\nThey differ.\n\n## Sources\n\n1. x";
    expect(normalizeWriteup(text)).toBe("Intro.\n\n## Validation approach\n\nHow we checked.\n\n## Sources of disagreement\n\nThey differ.");
  });
});

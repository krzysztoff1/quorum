import { describe, expect, it } from "vitest";
import { draftAnswer, draftMarkdown, settleAnswer, specFromProse, untracedObjections } from "../src/answer/index.js";
import { ResolvedSpecSchema } from "../src/answer/catalog.js";
import { readingOrder } from "../src/answer/datums.js";
import { adsChart, answer, CITATIONS, claim, liftChart } from "./answerSupport.js";

const SOURCED = CITATIONS.map((c, i) => ({ ...c, source_id: `s${i + 1}` }));
const SOURCES = SOURCED.map((c) => ({ id: c.source_id, source_type: "primary" }));

function jsonl(spec: ReturnType<typeof answer>): string {
  return [
    JSON.stringify({ op: "add", path: "/v", value: 1 }),
    JSON.stringify({ op: "add", path: "/root", value: spec.root }),
    ...readingOrder(spec).map((key) => JSON.stringify({ op: "add", path: `/elements/${key}`, value: spec.elements[key] })),
  ].join("\n") + "\n";
}

function reply(spec: ReturnType<typeof answer>): string {
  return "```qvs\n" + jsonl(spec) + "```\n\n```json\n{\"headline\":\"Small in grocery\"}\n```";
}

describe("the writer's reply becomes one answer spec", () => {
  it("compiles the qvs block the writer wrote", async () => {
    const spec = answer({ g1: [claim("Grocery gets 1–2%[^a1c2]."), liftChart()] });
    const draft = await draftAnswer(reply(spec), SOURCED);
    expect(draft.origin).toBe("spec");
    expect(draft.spec).toEqual(spec);
  });

  it("keeps every complete element of a truncated reply", async () => {
    const spec = answer({ g1: [claim("Grocery gets 1–2%[^a1c2]."), claim("Retail gets more[^a1c1].")] });
    const text = jsonl(spec);
    const draft = await draftAnswer("```qvs\n" + text.slice(0, text.length - 25), SOURCED);
    expect(draft.origin).toBe("spec");
    expect(Object.keys(draft.spec.elements)).toEqual(["answer", "g1", "g1_0"]);
    expect(draft.actions.map((a) => a.action)).toContain("drop_ref");
  });

  it("builds the spec from prose when the writer wrote no spec, keeping every cited sentence", async () => {
    const prose = "Lift is small in grocery[^a1c2].\n\n## Retail\n\nRetail gets 5–15%[^a1c1].\n\n- Ads topped $1B[^a1c3].\n\n## Sources\n\n1. x\n\n```json\n{}\n```";
    const draft = await draftAnswer(prose, SOURCED);
    expect(draft.origin).toBe("prose");
    expect(draftMarkdown(draft)).toBe("Lift is small in grocery[^a1c2].\n\n## Retail\n\nRetail gets 5–15%[^a1c1].\n\nAds topped $1B[^a1c3].");
  });

  it("falls back to the prose around a spec whose root cannot be rendered", async () => {
    const spec = answer({ g1: [claim("A[^a1c1].")] });
    delete spec.elements.answer!.props.lead;
    const draft = await draftAnswer("Lead from prose[^a1c1].\n\n" + reply(spec), SOURCED);
    expect(draft.origin).toBe("prose");
    expect(draft.spec.elements[draft.spec.root]!.props.lead).toBe("Lead from prose[^a1c1].");
  });

  it("files a blocking claim-sweep objection for each number its quote does not hold", async () => {
    const draft = await draftAnswer(reply(answer({ g1: [claim("Ads[^a1c4]."), adsChart()] })), SOURCED);
    expect(untracedObjections(draft, SOURCED)).toEqual([{
      lens: "claim_sweep", severity: "blocking",
      statement: "the figure DoorDash = $1B is not in its cited quote (a1c5)",
      followup: "find a primary source that states the figure for DoorDash: Ad revenue",
    }]);
  });

  it("settles the draft into the record's answer: resolved spec, display, fallback, check", async () => {
    const draft = await draftAnswer(reply(answer({ g1: [claim("Ads[^a1c4]."), adsChart()] })), SOURCED);
    const settled = settleAnswer(draft, { citations: SOURCED, sources: SOURCES, grounding: "captured" });
    expect(ResolvedSpecSchema.safeParse(settled.spec).success).toBe(true);
    expect(settled.display).toEqual({ g1_1: "chart" });
    expect(settled.check.ok).toBe(true);
    expect(settled.check.issues.map((i) => i.rule)).toEqual(["number_not_in_quote"]);
    expect(settled.markdown).toContain("$1B ⚠ not in quote");
  });
});

describe("prose into a spec", () => {
  it("keeps a hard-wrapped paragraph as one claim and splits a list into one claim per item", () => {
    const spec = specFromProse("Lead[^a1c1].\n\n## Why\n\nOne sentence that\nwraps here[^a1c2].\n\n- First item[^a1c1]\n  continues[^a1c3].\n- Second item[^a1c2].");
    const texts = spec.elements.g1!.children!.map((k) => spec.elements[k]!.props.text);
    expect(texts).toEqual(["One sentence that wraps here[^a1c2].", "First item[^a1c1] continues[^a1c3].", "Second item[^a1c2]."]);
  });

  it("makes the first paragraph the lead and every heading a group", () => {
    const spec = specFromProse("Lead[^a1c1].\n\nLoose[^a1c2].\n\n### Deeper\n\nInside[^a1c3].");
    expect(spec.elements.answer!.props.lead).toBe("Lead[^a1c1].");
    expect(spec.elements.answer!.children!.map((g) => spec.elements[g]!.props.title)).toEqual(["", "Deeper"]);
  });
});

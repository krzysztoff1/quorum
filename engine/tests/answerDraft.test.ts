import { describe, expect, it } from "vitest";
import { draftAnswer, draftMarkdown, settleAnswer, specFindings, specFromProse, untracedObjections } from "../src/answer/index.js";
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

  it("finds a number in a table cell whose column key holds a slash or a tilde", async () => {
    const table = {
      type: "EvidenceTable",
      props: {
        columns: [{ key: "label", label: "" }, { key: "ads/yr~x", label: "Ads" }],
        rows: [{ label: "DoorDash", "ads/yr~x": { v: 1, unit: "usd", scale: "B", basis: "reported", cite: ["a1c5"] } }],
        caption: "Ads[^a1c5].",
      },
    };
    const draft = await draftAnswer(reply(answer({ g1: [claim("Ads[^a1c4]."), table as any] })), SOURCED);
    expect(untracedObjections(draft, SOURCED).map((o) => o.statement)).toEqual([
      "the figure DoorDash = $1B is not in its cited quote (a1c5)",
    ]);
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

describe("findings come from the answer's claims", () => {
  it("lists each Claim with its markers, its sources and its confidence", async () => {
    const draft = await draftAnswer(reply(answer({ g1: [claim("Grocery gets 1–2%[^a1c2]."), claim("Unread[^a1c6].", "low")] })), SOURCED);
    expect(specFindings(draft.spec, SOURCED, (id) => `https://ex.test/${id}`)).toEqual([
      { claim: "Grocery gets 1–2%.", confidence: "high", citations: ["a1c2"], sources: ["https://ex.test/s2"] },
      { claim: "Unread.", confidence: "low", citations: ["a1c6"], sources: [] },
    ]);
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

describe("prose that opens with a heading or holds a table still makes a renderable answer", () => {
  const context = { citations: SOURCED, sources: SOURCES, grounding: "captured" as const };

  it("promotes the first claim to the lead when a heading comes first", () => {
    const spec = specFromProse("## Findings\n\nGrocery gets 1–2%[^a1c2].\n\nRetail gets more[^a1c1].");
    expect(spec.elements.answer!.props.lead).toBe("Grocery gets 1–2%[^a1c2].");
    const groups = spec.elements.answer!.children!;
    expect(groups.map((g) => spec.elements[g]!.props.title)).toEqual(["Findings"]);
    expect(spec.elements[groups[0]!]!.children!.map((k) => spec.elements[k]!.props.text)).toEqual(["Retail gets more[^a1c1]."]);
  });

  it("drops the group that promotion emptied", () => {
    const spec = specFromProse("## Findings\n\nOnly one[^a1c2].\n\n## More\n\nSecond[^a1c1].");
    expect(spec.elements.answer!.props.lead).toBe("Only one[^a1c2].");
    expect(spec.elements.answer!.children!.map((g) => spec.elements[g]!.props.title)).toEqual(["More"]);
  });

  it("drops the only group too when promotion empties it, so a lone claim still settles", () => {
    const spec = specFromProse("## Findings\n\nOnly one[^a1c2].");
    expect(spec.elements.answer!.props.lead).toBe("Only one[^a1c2].");
    expect(spec.elements.answer!.children).toEqual([]);
    const settled = settleAnswer({ spec, origin: "prose", actions: [], dropped: [], stripped: [], issues: [] }, context);
    expect(settled.check.issues.filter((i) => i.severity === "error")).toEqual([]);
  });

  it("keeps a cited markdown table as one claim per row", () => {
    const spec = specFromProse(
      "Lead[^a1c1].\n\n| | Ad revenue | Sources |\n|---|---:|---|\n| Uber | $2B | [^a1c4] |\n| Instacart | $1B | [^a1c3] |",
    );
    const claims = spec.elements.g1!.children!.map((k) => spec.elements[k]!.props.text);
    expect(claims).toEqual(["Uber: Ad revenue $2B[^a1c4]", "Instacart: Ad revenue $1B[^a1c3]"]);
  });

  it("settles to an answer whose check passes", async () => {
    const draft = await draftAnswer("## Findings\n\nGrocery gets 1–2%[^a1c2].\n\n| | Ads | Sources |\n|---|---|---|\n| Uber | $2B | [^a1c4] |", SOURCED);
    const settled = settleAnswer(draft, context);
    expect(settled.check.ok).toBe(true);
    expect(settled.markdown).toContain("Uber: Ads $2B[^a1c4]");
  });
});

describe("a malformed element keeps its content for repair", () => {
  const lines = (elements: Record<string, unknown>) => "```qvs\n" + [
    JSON.stringify({ op: "add", path: "/v", value: 1 }),
    JSON.stringify({ op: "add", path: "/root", value: "answer" }),
    ...Object.entries(elements).map(([key, value]) => JSON.stringify({ op: "add", path: `/elements/${key}`, value })),
  ].join("\n") + "\n```";

  it("keeps a claim's text when its confidence is not one the catalog knows", async () => {
    const draft = await draftAnswer(lines({
      answer: { type: "Answer", props: { lead: "Lead[^a1c1]." }, children: ["g1"] },
      g1: { type: "Group", props: { title: "T" }, children: ["c1"] },
      c1: { type: "Claim", props: { text: "Grocery gets 1–2%[^a1c2].", confidence: "very high" } },
    }), SOURCED);
    expect(draft.spec.elements.c1!.props.text).toBe("Grocery gets 1–2%[^a1c2].");
  });

  it("keeps every group when the answer's verdict is not one the catalog knows", async () => {
    const draft = await draftAnswer(lines({
      answer: { type: "Answer", props: { lead: "Lead[^a1c1].", verdict: "mixed" }, children: ["g1"] },
      g1: { type: "Group", props: { title: "T" }, children: ["c1"] },
      c1: { type: "Claim", props: { text: "Kept[^a1c2].", confidence: "high" } },
    }), SOURCED);
    expect(draft.origin).toBe("spec");
    expect(draft.spec.elements.c1!.props.text).toBe("Kept[^a1c2].");
    expect(draft.spec.elements.answer!.props).toEqual({ lead: "Lead[^a1c1]." });
  });

  it("coerces a stat's numeric string instead of dropping the stat", async () => {
    const draft = await draftAnswer(lines({
      answer: { type: "Answer", props: { lead: "Lead[^a1c1]." }, children: ["g1"] },
      g1: { type: "Group", props: { title: "T" }, children: ["c1", "s1"] },
      c1: { type: "Claim", props: { text: "A[^a1c2].", confidence: "high" } },
      s1: { type: "Stat", props: { value: { lo: "1", hi: 2, unit: "pct", basis: "reported", cite: ["a1c2"] }, label: "lift", caption: "Small[^a1c2]." } },
    }), SOURCED);
    expect(draft.spec.elements.s1!.props.value.lo).toBe(1);
  });
});

describe("structures that used to crash or loop", () => {
  it("survives a group with no children beside a loose claim", async () => {
    const spec: any = answer({ g1: [claim("A[^a1c1].")] });
    spec.elements.loose = claim("B[^a1c2].");
    spec.elements.answer.children = ["loose", "g1", "g2"];
    spec.elements.g2 = { type: "Group", props: { title: "Empty", extra: 1 } };
    const draft = await draftAnswer(reply(spec), SOURCED);
    expect(draft.spec.elements.loose!.props.text).toBe("B[^a1c2].");
  });

  it("does not loop or overflow when a group holds the answer", async () => {
    const spec: any = answer({ g1: [claim("A[^a1c1]."), { type: "SourceMix", props: { scope: "answer", by: "type" } } as any] });
    spec.elements.g1.children.push("answer");
    const draft = await draftAnswer(reply(spec), SOURCED);
    expect(draft.actions.length).toBeLessThan(10);
    expect(() => settleAnswer(draft, { citations: SOURCED, sources: SOURCES, grounding: "captured" })).not.toThrow();
  });
});

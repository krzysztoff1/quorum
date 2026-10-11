import { describe, expect, it } from "vitest";
import { resolveSpec, type ResolveInput } from "../src/answer/resolve.js";
import { answerMarkdown, fallbackMarkdown } from "../src/answer/markdown.js";
import { datumUnits } from "../src/answer/datums.js";
import { ResolvedSpecSchema } from "../src/answer/catalog.js";
import { adsChart, answer, bar, CITATIONS, claim, liftChart } from "./answerSupport.js";

const SOURCED = CITATIONS.map((c, i) => ({ ...c, source_id: `s${i + 1}` }));
const INPUT: ResolveInput = {
  citations: SOURCED,
  sources: [
    { id: "s1", source_type: "primary" }, { id: "s2", source_type: "primary" }, { id: "s3", source_type: "vendor" },
    { id: "s4", source_type: "news" }, { id: "s5", source_type: "seo" }, { id: "s6", source_type: "seo" },
  ],
  grounding: "captured",
};

describe("the engine decides every datum's trust; the model never writes it", () => {
  const resolved = resolveSpec(answer({ g1: [claim("Grocery gets 1–2%[^a1c2]."), liftChart()], g2: [claim("Ads[^a1c4]."), adsChart()] }), INPUT);
  const bars = resolved.spec.elements.g2_1!.props.bars;
  const rows = resolved.spec.elements.g1_1!.props.rows;

  it("rates a reported number found in its exact quote high", () => {
    expect(rows[1].value.trust).toEqual({ tier: "supported", trace: "quoted", confidence: "high" });
  });

  it("rates a close-match quote medium", () => {
    expect(bars[1].value.trust).toEqual({ tier: "close", trace: "quoted", confidence: "medium" });
  });

  it("shows a number missing from its quote as unverified instead of dropping it", () => {
    expect(bars[2].label).toBe("DoorDash");
    expect(bars[2].value.trust).toEqual({ tier: "supported", trace: "untraced", confidence: "unverified" });
    expect(resolved.issues).toContainEqual(expect.objectContaining({ element_id: "g2_1", rule: "number_not_in_quote" }));
  });

  it("rates an estimate low and a derived number medium", () => {
    const spec = answer({ g1: [claim("A[^a1c1]."), adsChart([
      bar("Uber", "a1c4", 2), bar("Instacart", "a1c3", 1.2, { basis: "estimate" }), bar("Sum", "a1c4", 3, { basis: "derived" }),
    ])] });
    const trusts = resolveSpec(spec, INPUT).spec.elements.g1_1!.props.bars.map((b: any) => b.value.trust.confidence);
    expect(trusts).toEqual(["high", "low", "medium"]);
  });

  it("floors a datum whose quote was never located to unverified", () => {
    const spec = answer({ g1: [claim("A[^a1c1]."), adsChart([bar("Uber", "a1c6", 2), bar("Instacart", "a1c3", 1), bar("DoorDash", "a1c4", 2)])] });
    expect(resolveSpec(spec, INPUT).spec.elements.g1_1!.props.bars[0].value.trust).toEqual({ tier: "unresolved", trace: "untraced", confidence: "unverified" });
  });

  it("lets the claim sweep's verdict on a datum mark it unsupported", () => {
    const spec = answer({ g1: [claim("A[^a1c1]."), liftChart()] });
    const unit = datumUnits(spec, SOURCED).find((u) => u.claim.startsWith("Retail"))!;
    const swept = resolveSpec(spec, { ...INPUT, verdicts: [{ claim_id: unit.id, claim: unit.claim, verdict: "unsupported" }] });
    expect(swept.spec.elements.g1_1!.props.rows[0].value.trust).toEqual({ tier: "unsupported", trace: "quoted", confidence: "unverified" });
  });

  it("floors a claim with no located quote to unverified", () => {
    const spec = answer({ g1: [claim("Unread[^a1c6].", "high"), claim("Read[^a1c1].", "high")] });
    const claims = resolveSpec(spec, INPUT).spec.elements;
    expect([claims.g1_0!.props.confidence, claims.g1_1!.props.confidence]).toEqual(["unverified", "high"]);
  });

  it("marks bars of different periods or scopes as not like-for-like", () => {
    const spec = answer({ g1: [claim("A[^a1c1]."), adsChart([bar("Uber", "a1c4", 2, { as_of: "2026-Q1" }), bar("Instacart", "a1c3", 1), bar("DoorDash", "a1c4", 2)])] });
    expect(resolveSpec(spec, INPUT).spec.elements.g1_1!.props.mixed_basis).toEqual({ as_of: true, scope: false });
  });

  it("counts a SourceMix by source type, strongest first", () => {
    const spec = answer({ g1: [claim("A[^a1c1][^a1c2][^a1c3][^a1c5]."), { type: "SourceMix", props: { scope: "answer", by: "type" } }] });
    const mix = resolveSpec(spec, INPUT).spec.elements.g1_1!.props;
    expect(mix.counts).toEqual([{ key: "primary", n: 2 }, { key: "vendor", n: 1 }, { key: "seo", n: 1 }]);
    expect(mix.total).toBe(4);
  });

  it("decides the display: a chart whose data are mostly unverified is shown as a table", () => {
    const shaky = adsChart([bar("Uber", "a1c4", 9), bar("Instacart", "a1c3", 9), bar("DoorDash", "a1c4", 2)]);
    const both = resolveSpec(answer({ g1: [claim("A[^a1c1]."), shaky], g2: [claim("B[^a1c1]."), liftChart()] }), INPUT);
    expect(both.display).toEqual({ g1_1: "table", g2_1: "chart" });
  });

  it("produces a record-valid resolved spec", () => {
    expect(ResolvedSpecSchema.safeParse(resolved.spec).success).toBe(true);
  });

  it("counts every tier on each side of a conflict", () => {
    const split = {
      type: "ConflictSplit",
      props: {
        question: "How big is the lift?",
        sides: [
          { label: "Benchmarks", headline: { lo: 1, hi: 2, unit: "pct", basis: "reported", cite: ["a1c2"] }, summary: "Small[^a1c2][^a1c1].", source_type: "primary" },
          { label: "Vendors", headline: "large", summary: "Large[^a1c3][^a1c6].", source_type: "vendor" },
        ],
        caption: "They disagree[^a1c2].",
      },
    };
    const sides = resolveSpec(answer({ g1: [claim("A[^a1c1]."), split as any] }), INPUT).spec.elements.g1_1!.props.sides;
    expect(sides.map((s: any) => s.tier_mix)).toEqual([
      { supported: 2, close: 0, unsupported: 0, unresolved: 0 },
      { supported: 0, close: 1, unsupported: 0, unresolved: 1 },
    ]);
  });
});

describe("the engine writes the text every reader without a renderer gets", () => {
  const resolved = resolveSpec(answer({ g1: [claim("Grocery gets 1–2%[^a1c2]."), liftChart()] }), INPUT);

  it("renders a visual as its caption and a table of cited values", () => {
    expect(resolved.fallback_md.g1_1).toBe([
      "**Revenue lift**",
      "",
      "Grocery sits below retail[^a1c1][^a1c2].",
      "",
      "| | Revenue lift | Sources |",
      "|---|---:|---|",
      "| Retail | 5–15% | [^a1c1] |",
      "| Grocery | 1–2% | [^a1c2] |",
    ].join("\n"));
  });

  it("flags an unverified number in the table", () => {
    const shaky = resolveSpec(answer({ g1: [claim("A[^a1c1]."), adsChart()] }), INPUT);
    expect(shaky.fallback_md.g1_1).toContain("| DoorDash | $1B ⚠ not in quote | 2025 | [^a1c5] |");
  });

  it("reads the whole answer as markdown: lead, sections, claims, then each visual's fallback", () => {
    expect(answerMarkdown(resolved.spec, resolved.fallback_md)).toBe([
      "Lift is small in grocery[^a1c2].",
      "",
      "## About g1",
      "",
      "Grocery gets 1–2%[^a1c2].",
      "",
      resolved.fallback_md.g1_1,
    ].join("\n"));
  });

  it("projects the same prose before and after resolution, so the sweep's verdicts still match", () => {
    const draft = answer({ g1: [claim("Grocery gets 1–2%[^a1c2]."), liftChart()] });
    const prose = (text: string) => text.split("\n").filter((l) => l && !l.startsWith("|"));
    expect(prose(answerMarkdown(draft, fallbackMarkdown(draft)))).toEqual(prose(answerMarkdown(resolved.spec, resolved.fallback_md)));
  });
});

describe("a stat's fallback", () => {
  it("is a table whose header has a column for every cell", () => {
    const stat = { type: "Stat", props: { value: { lo: 1, hi: 2, unit: "pct", basis: "reported", cite: ["a1c2"] }, label: "listings", caption: "Most[^a1c2]." } };
    const resolved = resolveSpec(answer({ g1: [claim("A[^a1c1]."), stat as any] }), INPUT);
    expect(resolved.fallback_md.g1_1).toContain("| | Value | Sources |\n|---|---|---|\n| listings | 1–2% | [^a1c2] |");
  });
});

describe("each datum is a claim for the sweep", () => {
  it("reads as label = value, with the caption as context, and only when a quote was located", () => {
    const units = datumUnits(answer({ g1: [claim("A[^a1c1]."), adsChart([bar("Uber", "a1c4", 2), bar("Instacart", "a1c6", 1), bar("DoorDash", "a1c5", 1)])] }), SOURCED);
    expect(units.map((u) => [u.id, u.claim, u.citations.map((c) => c.id)])).toEqual([
      ["d1", "Uber: $2B (2025)", ["a1c4"]],
      ["d3", "DoorDash: $1B (2025)", ["a1c5"]],
    ]);
    expect(units[0]!.context).toBe("Ad revenue — All three report ad businesses.");
  });
});

describe("a claim's confidence is capped by its weakest located quote", () => {
  it.each([
    ["Supported[^a1c1].", "high", "high"],
    ["Close only[^a1c3].", "high", "medium"],
    ["One read, one not[^a1c1][^a1c6].", "high", "low"],
    ["Nothing read[^a1c6].", "high", "unverified"],
    ["Model was modest[^a1c1].", "low", "low"],
  ])("%s proposed %s settles as %s", (text, proposed, settled) => {
    const resolved = resolveSpec(answer({ g1: [claim(text, proposed)] }), INPUT);
    expect(resolved.spec.elements.g1_0!.props.confidence).toBe(settled);
  });
});

describe("the answer's language decides what a billion is", () => {
  const polish = [{ id: "a1c1", source_id: "s1", quote: "wartość rynku w Krakowie wynosi 3 bln", match: "exact" as const }];
  const spec = () => answer({ g1: [claim("Rynek[^a1c1]."), adsChart([bar("Rynek", "a1c1", 3000), bar("Inny", "a1c1", 3), bar("Trzeci", "a1c1", 3)])] });
  const trace = (language?: string) => resolveSpec(spec(), { ...INPUT, citations: polish, language }).spec.elements.g1_1!.props.bars.map((b: any) => b.value.trust.trace);

  it("reads bln as a trillion when the answer is Polish, and as a billion when it is not", () => {
    expect(trace("pl")).toEqual(["quoted", "untraced", "untraced"]);
    expect(trace("en")).toEqual(["untraced", "quoted", "quoted"]);
  });
});


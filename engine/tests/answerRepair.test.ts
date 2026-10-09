import { describe, expect, it } from "vitest";
import { repairSpec } from "../src/answer/repair.js";
import { validateSpec } from "../src/answer/validate.js";
import { adsChart, answer, bar, CITATIONS, claim, liftChart } from "./answerSupport.js";

const ok = (spec: any) => validateSpec(spec, CITATIONS).ok;

describe("a bad visual is repaired, then turned into a table, then dropped; the text always survives", () => {
  it("leaves a valid answer alone", async () => {
    const spec = answer({ g1: [claim("Grocery gets 1–2%[^a1c2]."), liftChart()] });
    const repaired = await repairSpec(spec, CITATIONS);
    expect(repaired.actions).toEqual([]);
    expect(repaired.spec).toEqual(spec);
  });

  it("turns a two-bar chart into a table without asking the model", async () => {
    const spec = answer({ g1: [claim("Ads matter[^a1c4]."), adsChart([bar("Uber", "a1c4", 2), bar("Instacart", "a1c3", 1)])] });
    const repaired = await repairSpec(spec, CITATIONS);
    expect(repaired.spec.elements.g1_1!.type).toBe("EvidenceTable");
    expect(repaired.spec.elements.g1_1!.props.rows).toHaveLength(2);
    expect(repaired.actions.map((a) => a.action)).toEqual(["downgrade"]);
    expect(ok(repaired.spec)).toBe(true);
  });

  it("moves a second visual in a group to a new group", async () => {
    const spec = answer({ g1: [claim("Ads matter[^a1c4]."), liftChart(), adsChart()] });
    const repaired = await repairSpec(spec, CITATIONS);
    const groups = repaired.spec.elements.answer!.children!;
    expect(groups).toHaveLength(2);
    expect(repaired.spec.elements[groups[1]!]!.children).toEqual(["g1_2"]);
    expect(ok(repaired.spec)).toBe(true);
  });

  it("turns visuals over the answer's budget of three into their cited captions", async () => {
    const spec = answer({
      g1: [claim("A[^a1c1]."), liftChart()], g2: [claim("B[^a1c4]."), adsChart()],
      g3: [claim("C[^a1c1]."), liftChart()], g4: [claim("D[^a1c4]."), adsChart()],
    });
    const repaired = await repairSpec(spec, CITATIONS);
    expect(repaired.spec.elements.g4_1).toEqual(claim("All three report ad businesses[^a1c3][^a1c4].", "medium"));
    expect(repaired.actions.map((a) => a.action)).toContain("to_prose");
    expect(ok(repaired.spec)).toBe(true);
  });

  it("draws nothing but prose in an inconclusive answer", async () => {
    const spec = answer({ g1: [claim("A[^a1c1]."), liftChart()] }, {}, { verdict: "inconclusive" });
    const repaired = await repairSpec(spec, CITATIONS);
    expect(repaired.spec.elements.g1_1!.type).toBe("Claim");
  });

  it("asks the model once, with only the offending element, and takes its fix", async () => {
    const mixed = adsChart([bar("Uber", "a1c4", 2), bar("Instacart", "a1c3", 1), { ...bar("DoorDash", "a1c5", 1), value: { ...bar("DoorDash", "a1c5", 1).value, unit: "count" } }]);
    const spec = answer({ g1: [claim("Ads matter[^a1c4]."), mixed] });
    const prompts: string[] = [];
    const repaired = await repairSpec(spec, CITATIONS, {
      retry: async (prompt) => {
        prompts.push(prompt);
        return JSON.stringify({ op: "add", path: "/elements/g1_1", value: adsChart() }) + "\n";
      },
    });
    expect(prompts).toHaveLength(1);
    expect(prompts[0]).toContain("unit_mixed");
    expect(prompts[0]).toContain("### BarCompare");
    expect(prompts[0]).not.toContain("Ads matter");
    expect(repaired.spec.elements.g1_1).toEqual(adsChart());
    expect(repaired.actions.map((a) => a.stage)).toEqual(["model"]);
  });

  it("turns a chart the model could not fix into a table of the same cited data", async () => {
    const noAsOf = adsChart([bar("Uber", "a1c4", 2), bar("Instacart", "a1c3", 1), bar("DoorDash", "a1c5", 1, { as_of: undefined })]);
    const spec = answer({ g1: [claim("Ads matter[^a1c4]."), noAsOf] });
    const repaired = await repairSpec(spec, CITATIONS, { retry: async () => undefined });
    const table = repaired.spec.elements.g1_1!;
    expect(table.type).toBe("EvidenceTable");
    expect(table.props.rows.map((r: any) => r.label)).toEqual(["Uber", "Instacart", "DoorDash"]);
    expect(table.props.caption).toBe("All three report ad businesses[^a1c3][^a1c4].");
    expect(repaired.actions.at(-1)).toMatchObject({ stage: "fallback", action: "to_table", element_id: "g1_1" });
    expect(ok(repaired.spec)).toBe(true);
  });

  it("never keeps an invented citation: the row goes, and the visual if nothing is left", async () => {
    const invented = adsChart([bar("Uber", "a9c9", 2), bar("Instacart", "a9c8", 1), bar("DoorDash", "a9c7", 1)]);
    const spec = answer({ g1: [claim("Ads matter[^a1c4]."), invented] });
    const repaired = await repairSpec(spec, CITATIONS);
    expect(repaired.spec.elements.g1_1).toEqual(claim("All three report ad businesses[^a1c3][^a1c4].", "medium"));
    expect(repaired.dropped).toEqual([{ element_id: "g1_1", type: "BarCompare", reason: expect.stringContaining("cite_unknown") }]);
  });

  it("drops an unknown component and keeps nothing of it but its cited caption", async () => {
    const spec = answer({ g1: [claim("A[^a1c1]."), { type: "PieChart", props: { caption: "Pie[^a1c1]." } } as any] });
    const repaired = await repairSpec(spec, CITATIONS);
    expect(repaired.spec.elements.g1_1).toEqual(claim("Pie[^a1c1].", "medium"));
    expect(repaired.dropped[0]).toMatchObject({ element_id: "g1_1", type: "PieChart" });
  });

  it("keeps a sentence whose marker was invented, without the marker", async () => {
    const spec = answer({ g1: [claim("Grocery gets 1–2%[^a1c2][^zz9]."), claim("Unsourced[^zz8].")] });
    const repaired = await repairSpec(spec, CITATIONS);
    expect(repaired.spec.elements.g1_0!.props.text).toBe("Grocery gets 1–2%[^a1c2].");
    expect(repaired.spec.elements.g1_1!.props.text).toBe("Unsourced.");
    expect(repaired.stripped).toEqual(["zz9", "zz8"]);
  });

  it("coerces a numeric string and drops an unknown key", async () => {
    const chart: any = liftChart();
    chart.props.rows[0].value.lo = "5";
    chart.props.colour = "red";
    const repaired = await repairSpec(answer({ g1: [claim("A[^a1c1]."), chart] }), CITATIONS);
    expect(repaired.spec.elements.g1_1).toEqual(liftChart());
  });

  it("puts claims written straight under the answer into a group", async () => {
    const spec = answer({ g1: [claim("A[^a1c1].")] });
    spec.elements.loose = claim("B[^a1c2].");
    spec.elements.answer!.children!.unshift("loose");
    const repaired = await repairSpec(spec, CITATIONS);
    expect(ok(repaired.spec)).toBe(true);
    expect(repaired.spec.elements.g1!.children).toEqual(["loose", "g1_0"]);
  });

  it("never lets the repair call delete a sentence: an uncited claim is kept, and offered the valid ids", async () => {
    const spec = answer({ g1: [claim("Cited[^a1c1]."), claim("Uncited sentence.")] });
    const prompts: string[] = [];
    const repaired = await repairSpec(spec, CITATIONS, {
      retry: async (prompt) => {
        prompts.push(prompt);
        return JSON.stringify({ op: "remove", path: "/elements/g1_1" }) + "\n";
      },
    });
    expect(prompts[0]).toContain("Valid citation ids: a1c1, a1c2, a1c3, a1c4, a1c5");
    expect(repaired.spec.elements.g1_1!.props.text).toBe("Uncited sentence.");
    expect(repaired.actions).toContainEqual(expect.objectContaining({ stage: "model", action: "kept_prose", element_id: "g1_1" }));
  });

  it("cannot render an answer with no lead", async () => {
    const spec = answer({ g1: [claim("A[^a1c1].")] });
    delete spec.elements.answer!.props.lead;
    expect((await repairSpec(spec, CITATIONS)).renderable).toBe(false);
  });
});

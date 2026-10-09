import { describe, expect, it } from "vitest";
import { compileJsonl, extractSpecBlock, SpecStream } from "../src/answer/compile.js";

const datum = (cite: string, v: number) => ({ v, unit: "pct", basis: "reported", cite: [cite] });
const lines = [
  { op: "add", path: "/v", value: 1 },
  { op: "add", path: "/root", value: "answer" },
  { op: "add", path: "/elements/answer", value: { type: "Answer", props: { lead: "Lift is small[^a1c1]." }, children: ["g1"] } },
  { op: "add", path: "/elements/g1", value: { type: "Group", props: { title: "Small in grocery" }, children: ["c1"] } },
  { op: "add", path: "/elements/c1", value: { type: "Claim", props: { text: "Grocery gets 1–2%[^a1c1].", confidence: "high" } } },
  { op: "add", path: "/elements/g1/children/-", value: "bars" },
  { op: "add", path: "/elements/bars", value: { type: "BarCompare", props: { measure: "Lift", bars: [{ label: "A", value: { ...datum("a1c1", 1), as_of: "2024" } }], caption: "A leads[^a1c1]." } } },
  { op: "add", path: "/elements/bars/props/bars/-", value: { label: "B", value: { ...datum("a1c2", 2), as_of: "2024" } } },
].map((l) => JSON.stringify(l)).join("\n") + "\n";

describe("the answer arrives as append-only JSONL, one complete element per line", () => {
  it("compiles every add into one flat spec", () => {
    const { spec, issues } = compileJsonl(lines);
    expect(issues).toEqual([]);
    expect(spec.root).toBe("answer");
    expect(spec.elements.g1!.children).toEqual(["c1", "bars"]);
    expect(spec.elements.bars!.props.bars).toHaveLength(2);
  });

  it("builds the same spec however the text is chunked", () => {
    const whole = compileJsonl(lines).spec;
    for (const size of [1, 7, 13, 40]) {
      const stream = new SpecStream();
      for (let i = 0; i < lines.length; i += size) stream.push(lines.slice(i, i + size));
      expect(stream.end()).toEqual(whole);
    }
  });

  it("never applies a half-received line", () => {
    const stream = new SpecStream();
    const cut = lines.indexOf("/elements/c1") + 30;
    stream.push(lines.slice(0, cut));
    expect(stream.spec().elements.c1).toBeUndefined();
  });

  it("keeps every complete element when the stream is truncated mid-line", () => {
    const cut = lines.lastIndexOf("{\"op\"") + 20;
    const { spec, issues } = compileJsonl(lines.slice(0, cut));
    expect(Object.keys(spec.elements)).toEqual(["answer", "g1", "c1", "bars"]);
    expect(issues.map((i) => i.code)).toEqual(["parse_error"]);
  });

  it("rejects replace, remove and a second add of the same key", () => {
    const extra = [
      { op: "replace", path: "/elements/c1", value: {} },
      { op: "remove", path: "/elements/c1" },
      { op: "add", path: "/elements/c1", value: { type: "Claim", props: { text: "x[^a1c1].", confidence: "low" } } },
      { op: "add", path: "/elements/c1/props/text", value: "y" },
    ].map((l) => JSON.stringify(l)).join("\n");
    const { spec, issues } = compileJsonl(lines + extra);
    expect(issues.map((i) => i.code)).toEqual(["patch_rejected", "patch_rejected", "patch_rejected", "patch_rejected"]);
    expect(spec.elements.c1!.props.text).toBe("Grocery gets 1–2%[^a1c1].");
  });

  it("quarantines an element that does not parse and carries on", () => {
    const bad = JSON.stringify({ op: "add", path: "/elements/pie", value: { type: "PieChart", props: {} } });
    const { spec, issues, quarantined } = compileJsonl(bad + "\n" + lines);
    expect(quarantined.has("pie")).toBe(true);
    expect(issues.map((i) => i.code)).toEqual(["unknown_component"]);
    expect(spec.elements.answer).toBeDefined();
  });

  it("rejects only the row that breaks an element", () => {
    const row = JSON.stringify({ op: "add", path: "/elements/bars/props/bars/-", value: { label: "C", value: 3 } });
    const { spec, issues } = compileJsonl(lines + row + "\n");
    expect(spec.elements.bars!.props.bars).toHaveLength(2);
    expect(issues.map((i) => i.code)).toEqual(["bare_number"]);
  });
});

describe("the spec block inside a writer's reply", () => {
  it("finds the fenced qvs block and leaves the summary alone", () => {
    const reply = "Here it is.\n\n```qvs\n" + lines + "```\n\n```json\n{\"headline\":\"h\"}\n```";
    const block = extractSpecBlock(reply);
    expect(block?.jsonl).toBe(lines);
    expect(block?.prose).not.toContain("```qvs");
    expect(block?.prose).toContain("Here it is.");
    expect(block?.prose).toContain('{"headline":"h"}');
  });

  it("accepts a jsonl fence and an unterminated block", () => {
    expect(extractSpecBlock("```jsonl\n" + lines)?.jsonl).toBe(lines);
  });

  it("finds nothing in a prose answer", () => {
    expect(extractSpecBlock("Just prose[^a1c1].\n\n```json\n{}\n```")).toBeUndefined();
  });
});

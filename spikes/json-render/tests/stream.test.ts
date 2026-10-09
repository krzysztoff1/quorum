import { beforeAll, describe, expect, test } from "bun:test";
import type { Registry } from "../src/catalog";
import { loadRegistry } from "../src/gen-fixtures";
import { SpecStream, chunkText, compileJsonl, show } from "../src/stream";

let reg: Registry;
let jsonl: string;
beforeAll(async () => {
  reg = await loadRegistry();
  jsonl = await Bun.file(new URL("../fixtures/personalization.spec.jsonl", import.meta.url)).text();
});

/** Offset just past the "\n" that completes the line adding /elements/<key>. */
const lineEnd = (text: string, key: string) => text.indexOf("\n", text.indexOf(`"path":"/elements/${key}"`)) + 1;

describe("SpecStream", () => {
  test("final spec is identical for any chunking (20 seeds)", () => {
    const whole = compileJsonl(jsonl, reg).spec;
    for (let seed = 1; seed <= 20; seed++) {
      const s = new SpecStream(reg);
      for (const c of chunkText(jsonl, seed)) s.push(c);
      expect(s.end()).toEqual(whole);
      expect(s.issues).toEqual([]);
    }
  });

  test("a half-received line is never rendered", () => {
    const s = new SpecStream(reg);
    let fed = 0;
    for (const c of chunkText(jsonl, 3)) {
      s.push(c);
      fed += c.length;
      for (const key of Object.keys(s.elements)) expect(lineEnd(jsonl, key)).toBeLessThanOrEqual(fed);
    }
  });

  test("children that have not arrived render as pending", () => {
    const s = new SpecStream(reg);
    s.push(jsonl.split("\n").slice(0, 3).join("\n") + "\n");
    expect(show(s.snapshot())).toBe("Answer(…g_roi, …g_money, …g_how, …g_risk)");
    expect(s.snapshot()!.children.every((c) => c.status === "pending")).toBe(true);
  });

  test("an invalid element is quarantined; the stream carries on", () => {
    const lines = jsonl.split("\n");
    lines.splice(5, 0,
      `{"op":"add","path":"/elements/g_roi/children/-","value":"bad"}`,
      `{"op":"add","path":"/elements/bad","value":{"type":"BarCompare","props":{"measure":"x","bars":[{"label":"a","value":3}]}}}`);
    const s = new SpecStream(reg);
    for (const c of chunkText(lines.join("\n"), 11)) s.push(c);
    s.end();
    const g = s.snapshot()!.children[0]!;
    expect(g.children.map((c) => `${c.key}:${c.status}`)).toEqual(["c_lift:ready", "roi:ready", "split:ready", "bad:quarantined"]);
    expect(s.issues.map((i) => i.code).sort()).toEqual(["bare_number", "missing_prop"]);
    expect(Object.keys(s.elements)).toHaveLength(18);
  });

  test("only whitelisted append-only add paths apply", () => {
    const s = new SpecStream(reg);
    s.push(jsonl.split("\n").slice(0, 4).join("\n") + "\n");
    s.push(`{"op":"replace","path":"/elements/answer","value":{}}\n`);
    s.push(`{"op":"add","path":"/elements/answer","value":{"type":"Answer","props":{"lead":"x[^a2c6]"},"children":[]}}\n`);
    s.push(`{"op":"add","path":"/elements/answer/props/lead","value":"hijack"}\n`);
    s.push(`{"op":"add","path":"/elements/answer/props/lead/-","value":"x"}\n`);
    s.push(`{"op":"remove","path":"/elements/g_roi"}\n`);
    expect(s.issues.map((i) => i.code)).toEqual(Array(5).fill("patch_rejected"));
    expect(s.elements.answer!.props.lead).toStartWith("Personalization pays");
  });

  test("a row append that breaks the element is rejected, the element is kept", () => {
    const s = new SpecStream(reg);
    const upToAds = jsonl.split("\n").filter((l) => !l.includes("/props/bars/-")).join("\n");
    s.push(upToAds);
    s.push(`\n{"op":"add","path":"/elements/ads/props/bars/-","value":{"label":"Glovo","value":0.4}}\n`);
    expect(s.elements.ads!.props.bars).toHaveLength(1);
    expect(s.issues[0]!.code).toBe("bare_number");
    expect(s.issues[0]!.message).toStartWith("row rejected");
  });

  test("unknown citation ids are flagged on arrival (warn; final validation decides)", () => {
    const s = new SpecStream(reg);
    s.push(`{"op":"add","path":"/elements/k","value":{"type":"Claim","props":{"text":"x[^zz9]","confidence":"low"}}}\n`);
    expect(s.issues).toEqual([{ path: "/elements/k/props/text", code: "cite_unknown", message: `citation "zz9" is not in this run's citations`, severity: "warn" }]);
  });

  test("snapshot sequence (seed 7)", () => {
    const s = new SpecStream(reg);
    const seq: string[] = [];
    for (const c of chunkText(jsonl, 7)) { s.push(c); const v = show(s.snapshot()); if (v !== seq.at(-1)) seq.push(v); }
    expect(seq).toMatchSnapshot();
  });
});

import { beforeAll, describe, expect, test } from "bun:test";
import { ResolvedSpec, type Registry, type SpecLike } from "../src/catalog";
import { SOURCES, buildResolved, loadRegistry, resolvedName } from "../src/gen-fixtures";
import { repairSpec } from "../src/repair";
import { resolveSpec } from "../src/resolve";
import { compileJsonl } from "../src/stream";
import { validateSpec } from "../src/validate";

const F = (p: string) => new URL(`../fixtures/${p}`, import.meta.url);
let reg: Registry;
let spec: SpecLike;
let res: any;
beforeAll(async () => {
  reg = await loadRegistry();
  const c = compileJsonl(await Bun.file(F("personalization.spec.jsonl")).text(), reg);
  expect(c.issues).toEqual([]);
  spec = c.spec;
  res = resolveSpec(spec, reg);
});

describe("personalization fixture", () => {
  test("compiles to 18 elements and validates with only the expected warnings", () => {
    expect(Object.keys(spec.elements)).toHaveLength(18);
    const v = validateSpec(spec, reg);
    expect(v.ok).toBe(true);
    expect(v.issues.map((i) => `${i.severity}:${i.code}@${i.path}`)).toEqual([
      "warn:number_not_in_quote@/elements/ads/props/bars/2/value",
      "warn:visual_budget@/elements",
    ]);
  });

  test("row and child appends landed", () => {
    expect(spec.elements.ads!.props.bars.map((b: any) => b.label)).toEqual(["Uber", "Instacart", "DoorDash"]);
    expect(spec.elements.g_risk!.children).toEqual(["c_legal", "allergy", "ftc", "mix"]);
  });

  test("datum trust: tier = worst cite, numberInQuote, confidence floor", () => {
    const bars = res.elements.ads.props.bars.map((b: any) => b.value.trust);
    expect(bars[0]).toEqual({ tier: "supported", numberInQuote: true, confidence: "high" });
    expect(bars[2]).toEqual({ tier: "unsupported", numberInQuote: false, confidence: "unverified" }); // DoorDash $1B
    const starbucks = res.elements.roi.props.rows[2].value.trust;
    expect(starbucks).toEqual({ tier: "close", numberInQuote: true, confidence: "medium" });
    expect(res.elements.retention.props.series[0].points.map((p: any) => p.y.trust.numberInQuote)).toEqual([true, true, true]);
    expect(res.elements.allergy.props.of.trust.numberInQuote).toBe(true); // 50 restaurants
  });

  test("engine fields: mixedBasis, tierMix, SourceMix counts, claim floor, item tiers", () => {
    expect(res.elements.ads.props.mixedBasis).toEqual({ asOf: true, scope: true });
    expect(res.elements.split.props.sides.map((s: any) => s.tierMix)).toEqual([
      { supported: 1, close: 0, unsupported: 0, unresolved: 0 },
      { supported: 1, close: 1, unsupported: 0, unresolved: 0 }, // a2c4 close, a2c9 supported
    ]);
    const counts = res.elements.mix.props.counts;
    expect(counts[0]).toEqual({ key: "company-reported", n: 6 });
    expect(counts.reduce((s: number, c: any) => s + c.n, 0)).toBe(19); // distinct sources cited in the answer
    expect(res.elements.c_memory.props.confidence).toBe("unverified"); // a1c7 unresolved
    expect(res.elements.c_lift.props.confidence).toBe("high");
    expect(res.elements.ftc.props.events.every((e: any) => e.tier === "supported" && e.dateInQuote)).toBe(true);
    expect(res.elements.matrix.props.cells.find((c: any) => c.option === "llm" && c.criterion === "cold").tier).toBe("unresolved");
    expect(res.elements.matrix.props.cells.find((c: any) => c.rating === null).tier).toBeUndefined();
  });

  test("model spec never carries engine fields; resolved spec parses as ResolvedSpec", () => {
    expect(JSON.stringify(spec)).not.toContain("\"trust\":");
    expect(ResolvedSpec.safeParse(res).success).toBe(true);
  });
});

describe("resolved fixtures are up to date (bun run src/gen-fixtures.ts)", () => {
  for (const n of SOURCES)
    test(n, async () => {
      const fresh = await buildResolved(n, reg);
      expect(fresh).toEqual(await Bun.file(F(resolvedName(n))).json());
      expect(ResolvedSpec.safeParse(fresh).success).toBe(true);
    });
});

describe("invalid fixtures", async () => {
  const files = (await Array.fromAsync(new Bun.Glob("*.json").scan(F("invalid/").pathname))).sort();
  test("there are 5–12 of them", () => expect(files.length).toBeGreaterThanOrEqual(5));
  for (const f of files)
    test(f, async () => {
      const fx = await Bun.file(F(`invalid/${f}`)).json();
      let s: SpecLike, codes: string[];
      if (fx.jsonl) {
        const c = compileJsonl(fx.jsonl, reg);
        s = c.spec;
        codes = [...c.issues, ...validateSpec(s, reg).issues].map((i) => i.code);
      } else {
        s = fx.spec;
        codes = validateSpec(s, reg).issues.map((i) => i.code);
      }
      for (const code of fx.expect) expect(codes).toContain(code);
      const r = repairSpec(s, reg);
      expect(r.actions.map((a) => a.kind)).toEqual(expect.arrayContaining(fx.repair));
      expect(r.renderable).toBe(true);
      // after repair, the only errors left are on prose we deliberately kept
      const kept = new Set(r.actions.filter((a) => a.kind === "keep_prose").map((a) => a.target));
      for (const i of r.validation.issues.filter((i) => i.severity === "error"))
        expect([...kept].some((k) => i.path.startsWith(k))).toBe(true);
      expect(ResolvedSpec.safeParse(resolveSpec(r.spec, reg)).success).toBe(true);
    });
});

describe("repair loop", () => {
  const load = async (n: string) => (await Bun.file(F(`invalid/${n}.json`)).json()).spec as SpecLike;

  test("a model retry that fixes the element wins over the fallback drop", async () => {
    const s = await load("bare-number");
    let seen = "";
    const r = repairSpec(s, reg, {
      modelRetry: (prompt) => {
        seen = prompt;
        return JSON.stringify({ op: "add", path: "/elements/s1", value: { ...s.elements.s1, props: { ...s.elements.s1!.props, value: { v: 80, unit: "pct", basis: "reported", cite: ["a3c11"] } } } });
      },
    });
    expect(seen).toContain("/elements/s1/props/value · bare_number");
    expect(seen).toContain("### Stat");
    expect(r.actions.map((a) => `${a.stage}:${a.kind}`)).toEqual(["model:replace"]);
    expect(r.validation.ok).toBe(true);
    expect(r.spec.elements.s1).toBeDefined();
  });

  test("a model retry that fails again falls back to dropping only the visual", async () => {
    const s = await load("bar-units-mixed");
    const r = repairSpec(s, reg, { modelRetry: () => `{"op":"add","path":"/elements/ads","value":{"type":"BarCompare"}}` });
    expect(r.actions.map((a) => a.kind)).toEqual(["replace", "drop"]);
    expect(Object.keys(r.spec.elements).sort()).toEqual(["answer", "c1", "g1"]);
  });

  test("prose is never blocked: a Claim with an unknown cite is kept and floored at resolve", async () => {
    const r = repairSpec(await load("unknown-cite"), reg);
    expect(r.spec.elements.c2).toBeDefined();
    expect(r.spec.elements.s1).toBeUndefined();
    expect(resolveSpec(r.spec, reg).elements.c2!.props.confidence).toBe("unverified");
    expect(r.repairPrompt).toContain("Valid citation ids: a1c1,");
  });

  test("two-bar chart downgrades to an EvidenceTable that validates", async () => {
    const r = repairSpec(await load("chart-two-data"), reg);
    expect(r.spec.elements.ads!.type).toBe("EvidenceTable");
    expect(r.validation.ok).toBe(true);
  });

  test("over-limit visuals move to the next group with room", () => {
    const s = structuredClone(spec);
    s.elements.g_roi!.children!.push("allergy2");
    s.elements.allergy2 = structuredClone(s.elements.allergy!);
    s.elements.g_how!.children = ["c_arch", "c_memory"];
    delete s.elements.matrix;
    const r = repairSpec(s, reg);
    expect(r.actions.map((a) => `${a.kind} ${a.detail}`)).toContain("move_visual g_roi → g_how");
    expect(r.validation.ok).toBe(true);
  });
});

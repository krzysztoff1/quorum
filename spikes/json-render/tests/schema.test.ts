import { describe, expect, test } from "bun:test";
import Ajv2020 from "ajv/dist/2020";
import { COMPONENT_TYPES, ModelSpec } from "../src/catalog";
import { emitSchemas, schemaText } from "../src/emit-schema";
import { catalogPrompt } from "../src/prompt";
import { compileJsonl } from "../src/stream";

const read = (p: string) => Bun.file(new URL(`../${p}`, import.meta.url));
const { model, resolved } = emitSchemas();

describe("JSON Schema emission", () => {
  test("is stable: matches the committed schema files (bun run src/emit-schema.ts)", async () => {
    expect(schemaText(model)).toBe(await read("schema/qvs-model.schema.json").text());
    expect(schemaText(resolved)).toBe(await read("schema/qvs-resolved.schema.json").text());
  });

  test("lists every component type", () => {
    const types = (resolved as any).$defs.ElementResolved.oneOf.map((o: any) => o.properties.type.const);
    expect(types).toEqual(COMPONENT_TYPES);
  });

  const ajv = new Ajv2020({ strict: false, allErrors: true });
  const checkModel = ajv.compile(model);
  const checkResolved = ajv.compile(resolved);

  test("accepts what Zod accepts", async () => {
    const reg = await read("fixtures/citations.json").json();
    const spec = compileJsonl(await read("fixtures/personalization.spec.jsonl").text(), reg).spec;
    expect(ModelSpec.safeParse(spec).success).toBe(true);
    expect(checkModel(spec)).toBe(true);
    for (const f of ["personalization", "kitchen-sink", "inconclusive"])
      expect(checkResolved(await read(`fixtures/${f}.resolved.json`).json())).toBe(true);
    expect(checkModel(await read("fixtures/kitchen-sink.spec.json").json())).toBe(true);
  });

  test("the Datum either-v-or-range refine survives as oneOf (lo<=hi does not)", async () => {
    const spec = await read("fixtures/inconclusive.spec.json").json();
    const withStat = (value: object) => ({ ...spec, elements: { ...spec.elements, s: { type: "Stat", props: { value, label: "x", caption: "x" } } } });
    const base = { unit: "pct", basis: "reported", cite: ["a1c7"] };
    expect(checkModel(withStat({ ...base, v: 1 }))).toBe(true);
    expect(checkModel(withStat({ ...base, lo: 1, hi: 2 }))).toBe(true);
    expect(checkModel(withStat({ ...base, v: 1, lo: 1, hi: 2 }))).toBe(false);
    expect(checkModel(withStat({ ...base, lo: 1 }))).toBe(false);
    expect(checkModel(withStat({ ...base }))).toBe(false);
    expect(checkModel(withStat({ ...base, lo: 3, hi: 2 }))).toBe(true); // JSON Schema can't say lo <= hi
    expect(ModelSpec.safeParse(withStat({ ...base, lo: 3, hi: 2 })).success).toBe(false);
  });

  test("rejects shape errors from the invalid fixtures (bare number, unknown component, unknown key)", async () => {
    for (const f of ["bare-number", "unknown-component", "sloppy-model"])
      expect(checkModel((await read(`fixtures/invalid/${f}.json`).json()).spec)).toBe(false);
    // semantic failures are NOT schema failures: that's validate.ts's job
    for (const f of ["chart-two-data", "bar-units-mixed", "unknown-cite", "children-cycle"])
      expect(checkModel((await read(`fixtures/invalid/${f}.json`).json()).spec)).toBe(true);
  });
});

describe("prompt", () => {
  const p = catalogPrompt();
  test("covers every component and stays small", () => {
    for (const t of COMPONENT_TYPES) expect(p).toContain(`### ${t}\n`);
    expect(p).not.toContain("[object");
    expect(p).not.toMatch(/: (pipe|default|transform)\b/);
    expect(p.length).toBeLessThan(10_000);
  });
  test("snapshot", () => expect(p).toMatchSnapshot());
});

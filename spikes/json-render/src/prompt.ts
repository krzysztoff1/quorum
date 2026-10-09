// Generate the system-prompt catalog section from the Zod catalog (cf. json-render's catalog.prompt()).
// Walks zod 4 internals (`_zod.def`) to print compact TS-like signatures; named types ($defs ids) print by name.
import { z } from "zod";
import { model, COMPONENT_TYPES, CiteId, Rich, Unit, SourceKind } from "./catalog";

type Any = z.ZodType & { _zod: { def: any; parent?: Any } };
const def = (s: unknown) => (s as Any)._zod.def;

function namedId(s: Any): string | undefined {
  for (let x: Any | undefined = s; x; x = x._zod.parent) {
    const id = z.globalRegistry.get(x)?.id;
    if (id) return id.replace(/Resolved$/, "");
  }
}
/** A schema's OWN description (not a named type's doc, which is printed once in the header). */
function ownDesc(s: Any): string | undefined {
  for (let x: Any | undefined = s; x; x = def(x).innerType) {
    const meta = z.globalRegistry.get(x);
    if (meta?.id) return undefined;
    if (meta?.description) return meta.description;
  }
}
const isOptional = (s: Any) => def(s).type === "optional";

export function sig(s: Any, expand = false): string {
  const n = !expand && namedId(s);
  if (n) return n;
  const d = def(s);
  switch (d.type) {
    case "string": case "boolean": case "null": return d.type;
    case "number": return d.format?.includes("int") ? "int" : "number";
    case "literal": return d.values.map((v: unknown) => JSON.stringify(v)).join(" | ");
    case "enum": return Object.values(d.entries).map((v) => JSON.stringify(v)).join(" | ");
    case "optional": return sig(d.innerType);
    case "nullable": return `${sig(d.innerType)} | null`;
    case "array": { const e = sig(d.element); return e.includes(" | ") && !e.startsWith("{") ? `(${e})[]` : `${e}[]`; }
    case "union": return d.options.map((o: Any) => sig(o)).join(" | ");
    case "tuple": return `[${d.items.map((i: Any) => sig(i)).join(", ")}]`;
    case "record": return `Record<string, ${sig(d.valueType)}>`;
    case "object": return `{ ${Object.entries(d.shape).map(([k, v]) => `${k}${isOptional(v as Any) ? "?" : ""}: ${sig(v as Any)}`).join(", ")} }`;
    default: return d.type;
  }
}

/** Descriptions of fields nested inside arrays/objects, as `rows[].value` lines. */
function nestedNotes(s: Any, prefix: string, out: string[]) {
  const d = def(s);
  if (namedId(s)) return;
  if (d.type === "optional" || d.type === "nullable") return nestedNotes(d.innerType, prefix, out);
  if (d.type === "array") return nestedNotes(d.element, `${prefix}[]`, out);
  if (d.type !== "object") return;
  for (const [k, v] of Object.entries(d.shape)) {
    const desc = ownDesc(v as Any);
    if (desc) out.push(`    ${prefix}.${k}: ${desc}`);
    nestedNotes(v as Any, `${prefix}.${k}`, out);
  }
}

function fieldLines(shape: Record<string, Any>, seen?: Set<string>): string[] {
  const out: string[] = [];
  for (const [k, v] of Object.entries(shape)) {
    let desc = ownDesc(v);
    if (desc && seen) { if (seen.has(desc)) desc = undefined; else seen.add(desc); }
    out.push(`  ${k}${isOptional(v) ? "?" : ""}: ${sig(v)}${desc ? ` — ${desc}` : ""}`);
    nestedNotes(v, k, out);
  }
  return out;
}

function propLines(props: Any, seen?: Set<string>): string[] {
  const d = def(props);
  if (d.type === "object") return fieldLines(d.shape, seen);
  // discriminated union (SmallMultiples): print the discriminator once, then the first option's other fields
  const disc: string = d.discriminator;
  const first = def(d.options[0]).shape;
  return [
    `  ${disc}: ${d.options.map((o: Any) => sig(def(o).shape[disc])).join(" | ")}`,
    `  panels: { title: string, props: <the props of \`${disc}\`, without caption> }[] — ${ownDesc(first.panels) ?? ""}`,
    ...fieldLines(Object.fromEntries(Object.entries(first).filter(([k]) => k !== disc && k !== "panels")) as any, seen),
  ];
}

export function componentPrompt(type: string, seen?: Set<string>): string {
  const c = model.components[type]!;
  return [`### ${type}`, c.description, ...propLines(c.props as Any, seen), ...(c.children ? [`  children: ${c.children}`] : [])].join("\n");
}

export function catalogPrompt(): string {
  const leaf = (s: unknown) => `${namedId(s as Any)} = ${sig(s as Any, true)}  // ${(s as Any).description}`;
  const seen = new Set<string>();
  return `## Answer view spec (QVS v1)

Write the answer as JSONL, one RFC 6902 "add" op per line, each line a COMPLETE element:
{"op":"add","path":"/v","value":1}
{"op":"add","path":"/root","value":"answer"}
{"op":"add","path":"/elements/<key>","value":{"type":"<Component>","props":{…},"children":["<key>",…]}}
Optional appends: /elements/<key>/children/- (a child key) and /elements/<key>/props/<arrayProp>/- (one row).
Write a parent before its children; children may reference keys you have not written yet.

${leaf(CiteId)}
${leaf(Rich)}
${leaf(Unit)}
${leaf(SourceKind)}
Datum = every number, always:
${fieldLines(def(model.Datum).shape).join("\n")}

Rules: no bare numbers anywhere (always a Datum with cite). A chart needs ≥ 3 data, else a Stat. One unit per axis.
≤ 8 rows/series. Every visual has a cited caption. Write labels in the question's language. Never write trust,
confidence floors, tierMix, mixedBasis or counts: the engine adds them.

When NOT to draw (priority order):
1. Prefer a sentence. Draw only for scale, spread, order, or the shape of a disagreement.
2. At most one visual per group and three per answer.
3. Never draw a number you'd hedge in prose without the hedge: use cmp, basis "estimate", ranges.
4. Mostly vendor/SEO evidence → SourceMix or ConflictSplit before any bar chart.
5. An inconclusive answer gets no visuals except SourceMix.

## Components

${COMPONENT_TYPES.map((t) => componentPrompt(t, seen)).join("\n\n")}
`;
}

if (import.meta.main) console.log(catalogPrompt());

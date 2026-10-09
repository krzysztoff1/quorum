import { z } from "zod";
import { COMPONENT_TYPES, modelCatalog } from "./catalog.js";

type Schema = z.ZodType & { _zod: { def: any; parent?: Schema } };

function definition(schema: unknown): any {
  return (schema as Schema)._zod.def;
}

function namedId(schema: Schema): string | undefined {
  for (let s: Schema | undefined = schema; s; s = s._zod.parent) {
    const id = z.globalRegistry.get(s)?.id;
    if (id) return id.replace(/^QVSModel/, "").replace(/^QVS/, "");
  }
  return undefined;
}

function ownDescription(schema: Schema): string | undefined {
  for (let s: Schema | undefined = schema; s; s = definition(s).innerType) {
    const meta = z.globalRegistry.get(s);
    if (meta?.id) return undefined;
    if (meta?.description) return meta.description;
  }
  return undefined;
}

function optional(schema: Schema): boolean {
  return definition(schema).type === "optional";
}

export function signature(schema: Schema, expand = false): string {
  const named = !expand && namedId(schema);
  if (named) return named;
  const def = definition(schema);
  switch (def.type) {
    case "string": case "boolean": case "null": return def.type;
    case "number": return def.format?.includes("int") ? "int" : "number";
    case "literal": return def.values.map((v: unknown) => JSON.stringify(v)).join(" | ");
    case "enum": return Object.values(def.entries).map((v) => JSON.stringify(v)).join(" | ");
    case "optional": return signature(def.innerType);
    case "nullable": return `${signature(def.innerType)} | null`;
    case "array": {
      const element = signature(def.element);
      return element.includes(" | ") && !element.startsWith("{") ? `(${element})[]` : `${element}[]`;
    }
    case "union": return def.options.map((o: Schema) => signature(o)).join(" | ");
    case "record": return `Record<string, ${signature(def.valueType)}>`;
    case "object":
      return `{ ${Object.entries(def.shape).map(([k, v]) => `${k}${optional(v as Schema) ? "?" : ""}: ${signature(v as Schema)}`).join(", ")} }`;
    default: return def.type;
  }
}

function fieldLines(shape: Record<string, Schema>): string[] {
  return Object.entries(shape).map(([key, value]) => {
    const description = ownDescription(value);
    return `  ${key}${optional(value) ? "?" : ""}: ${signature(value)}${description ? ` — ${description}` : ""}`;
  });
}

export function componentPrompt(type: string): string {
  const component = modelCatalog.components[type]!;
  return [
    `### ${type}`,
    `Use: ${component.use}`,
    `Not for: ${component.avoid}`,
    ...fieldLines(definition(component.props).shape),
    ...(component.children ? [`  children: ${component.children}`] : []),
  ].join("\n");
}

export function datumPrompt(): string {
  const shape = definition(definition(modelCatalog.Datum).type === "pipe" ? definition(modelCatalog.Datum).in : modelCatalog.Datum).shape;
  return ["Datum — every number, always:", ...fieldLines(shape)].join("\n");
}

export function catalogPrompt(): string {
  return `## The answer format (QVS v1)

Write the answer as a fenced \`\`\`qvs block of JSONL: one JSON "add" operation per line, each line a COMPLETE element.
{"op":"add","path":"/v","value":1}
{"op":"add","path":"/root","value":"answer"}
{"op":"add","path":"/elements/answer","value":{"type":"Answer","props":{"lead":"…[^a1c2]","verdict":"leaning"},"children":["g1"]}}
{"op":"add","path":"/elements/g1","value":{"type":"Group","props":{"title":"…"},"children":["c1"]}}
{"op":"add","path":"/elements/c1","value":{"type":"Claim","props":{"text":"…[^a2c1].","confidence":"high","reason":"two primary sources"}}}
Write a parent before its children. Children may name keys you write later. Element keys are short ASCII words.

${datumPrompt()}

Rules:
- Every sentence of the lead and of every Claim carries a marker: [^id], with an id from the verified quotes you were handed.
- No bare numbers anywhere: a number in a visual is always a Datum with cite.
- A reported number appears in its cited quote exactly as drawn (same value, same unit); otherwise say derived or estimate.
- At most one visual per group and three per answer. A chart needs at least 3 bars, else a Stat. One unit per chart.
- Every visual has a cited caption. Write every label and title in the question's language.
- Never write trust, tiers, counts, tier_mix or mixed_basis: the engine adds them.

When NOT to draw:
1. Prefer a sentence. Draw only for scale, spread, ranking, or the shape of a disagreement.
2. Never draw a number you would hedge in prose without the hedge: use cmp, ranges, basis "estimate".
3. Mostly vendor or SEO evidence: a SourceMix or ConflictSplit before any bar chart.
4. An inconclusive answer gets no visuals except SourceMix.

## Components

${COMPONENT_TYPES.map(componentPrompt).join("\n\n")}
`;
}

export const REPAIR_SYSTEM_PROMPT = `You repair elements of a research answer's spec. You have no tools. You never add a number or a citation id that the problem list and the elements in front of you do not already carry. Reply with ONLY JSONL lines, one complete element per line, exactly as the instructions say.`;

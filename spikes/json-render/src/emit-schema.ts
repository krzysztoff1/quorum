// Emit JSON Schema (draft 2020-12) from the Zod catalog with zod 4's z.toJSONSchema.
// What does NOT survive, and how it is handled:
//   - `.refine(datumShapeOk)` (either v, or lo+hi) is silently dropped → re-added below as `oneOf` via `override`.
//     `lo <= hi` cannot be expressed in JSON Schema at all; it stays a Zod/validate-only rule.
//   - Transforms would throw ("Transforms cannot be represented") → the catalog uses none.
//   - Semantic rules (counts, cite existence, unit consistency, graph shape) live in validate.ts, never in the schema.
import { z } from "zod";
import { ModelSpec, ResolvedSpec } from "./catalog";

const DATUM_IDS = new Set(["Datum", "DatumResolved"]);
const eitherVOrRange = [
  { required: ["v"], not: { anyOf: [{ required: ["lo"] }, { required: ["hi"] }] } },
  { required: ["lo", "hi"], not: { required: ["v"] } },
];

function emit(schema: z.ZodType) {
  return z.toJSONSchema(schema, {
    target: "draft-2020-12",
    override: (ctx) => {
      const id = z.globalRegistry.get(ctx.zodSchema as unknown as z.ZodType)?.id;
      if (id && DATUM_IDS.has(id)) (ctx.jsonSchema as any).oneOf = eitherVOrRange;
    },
  });
}

export const emitSchemas = () => ({ model: emit(ModelSpec), resolved: emit(ResolvedSpec) });
export const schemaText = (s: unknown) => JSON.stringify(s, null, 2) + "\n";

if (import.meta.main) {
  const { model, resolved } = emitSchemas();
  await Bun.write(new URL("../schema/qvs-model.schema.json", import.meta.url), schemaText(model));
  await Bun.write(new URL("../schema/qvs-resolved.schema.json", import.meta.url), schemaText(resolved));
  console.log("wrote schema/qvs-model.schema.json", schemaText(model).length, "B; schema/qvs-resolved.schema.json", schemaText(resolved).length, "B");
}

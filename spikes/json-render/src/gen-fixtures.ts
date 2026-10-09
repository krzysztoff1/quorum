// Regenerate fixtures/*.resolved.json: compile (JSONL) → validate → resolve. Tests assert these are up to date.
import type { Registry, SpecLike } from "./catalog";
import { resolveSpec } from "./resolve";
import { compileJsonl } from "./stream";
import { validateSpec } from "./validate";

const dir = new URL("../fixtures/", import.meta.url);
export const SOURCES = ["personalization.spec.jsonl", "kitchen-sink.spec.json", "inconclusive.spec.json"];

export async function loadRegistry(): Promise<Registry> { return Bun.file(new URL("citations.json", dir)).json(); }

export async function buildResolved(name: string, reg: Registry): Promise<SpecLike> {
  const file = Bun.file(new URL(name, dir));
  const spec: SpecLike = name.endsWith(".jsonl") ? compileJsonl(await file.text(), reg).spec : await file.json();
  const v = validateSpec(spec, reg);
  if (!v.ok) throw new Error(`${name} does not validate: ${JSON.stringify(v.issues.filter((i) => i.severity === "error"))}`);
  return resolveSpec(spec, reg);
}
export const resolvedName = (n: string) => n.replace(/\.spec\.jsonl?$/, ".resolved.json");

if (import.meta.main) {
  const reg = await loadRegistry();
  for (const n of SOURCES) {
    await Bun.write(new URL(resolvedName(n), dir), JSON.stringify(await buildResolved(n, reg), null, 2) + "\n");
    console.log("wrote fixtures/" + resolvedName(n));
  }
}

// bun run src/demo.ts — prompt excerpt, fixture validation, streaming snapshots, repair.
import { catalogPrompt } from "./prompt";
import { loadRegistry } from "./gen-fixtures";
import { validateSpec } from "./validate";
import { resolveSpec } from "./resolve";
import { SpecStream, chunkText, compileJsonl, show } from "./stream";
import { repairSpec } from "./repair";

const reg = await loadRegistry();
const hr = (t: string) => console.log(`\n━━ ${t} ${"━".repeat(Math.max(0, 70 - t.length))}`);

hr("1. Generated prompt (excerpt)");
const prompt = catalogPrompt();
console.log(prompt.split("\n").slice(0, 32).join("\n"));
console.log(`… (${prompt.length} chars, ~${Math.round(prompt.length / 4)} tokens)`);

hr("2. Streaming personalization.spec.jsonl in 7–40 char chunks");
const jsonl = await Bun.file(new URL("../fixtures/personalization.spec.jsonl", import.meta.url)).text();
// inject a broken element mid-stream to show quarantine
const lines = jsonl.split("\n");
lines.splice(8, 0,
  `{"op":"add","path":"/elements/g_roi/children/-","value":"split2"}`,
  `{"op":"add","path":"/elements/split2","value":{"type":"ConflictSplit","props":{"question":"?","sides":"oops"}}}`);
const stream = new SpecStream(reg);
let last = "";
for (const c of chunkText(lines.join("\n"))) {
  if (stream.push(c) === 0) continue;
  const now = show(stream.snapshot());
  if (now !== last) console.log(" ", now);
  last = now;
}
stream.end();
console.log(`  stream issues: ${stream.issues.map((i) => `${i.code}@${i.path}`).join(", ") || "none"} · quarantined: ${[...stream.quarantined.keys()].join(", ")}`);

hr("3. Validate + resolve fixtures");
const clean = compileJsonl(jsonl, reg).spec;
const v = validateSpec(clean, reg);
console.log(`personalization: ok=${v.ok}; ${v.issues.map((i) => `${i.severity}:${i.code} ${i.path}`).join("; ")}`);
const r = resolveSpec(clean, reg);
for (const b of r.elements.ads!.props.bars) console.log(`  ads ${b.label.padEnd(10)} ${JSON.stringify(b.value.trust)}`);
console.log(`  ads mixedBasis ${JSON.stringify(r.elements.ads!.props.mixedBasis)} · c_memory confidence → ${r.elements.c_memory!.props.confidence}`);
console.log(`  SourceMix ${JSON.stringify(r.elements.mix!.props.counts)}`);

hr("4. Repair invalid fixtures (no model available → fallback)");
const invalid = (await Array.fromAsync(new Bun.Glob("*.json").scan(new URL("../fixtures/invalid/", import.meta.url).pathname))).sort();
for (const f of invalid) {
  const fx = await Bun.file(new URL(`../fixtures/invalid/${f}`, import.meta.url)).json();
  if (!fx.spec) continue;
  const res = repairSpec(fx.spec, reg);
  console.log(`${f.padEnd(26)} → ${res.actions.map((a) => `${a.stage}:${a.kind}`).join(", ") || "(nothing to do)"} · renderable=${res.renderable}`);
}
const bare = await Bun.file(new URL("../fixtures/invalid/bare-number.json", import.meta.url)).json();
console.log("\nRepair prompt for bare-number.json:\n" + repairSpec(bare.spec, reg).repairPrompt);

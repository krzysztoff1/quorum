// Repair loop: (a) deterministic auto-fixes → (b) ONE model retry with a compact, pointer-addressed prompt →
// (c) fallback: drop invalid visuals, salvage prose. The answer's prose is never blocked by a bad chart.
import { COMPONENT_TYPES, VISUAL_TYPES, type El, type Registry, type SpecLike } from "./catalog";
import { componentPrompt } from "./prompt";
import { validateSpec, type Issue, type Validation } from "./validate";
import { getAt } from "./walk";

export type RepairAction = { stage: "auto" | "model" | "fallback"; kind: string; target: string; detail: string };
export type RepairResult = {
  spec: SpecLike; actions: RepairAction[]; validation: Validation;
  repairPrompt?: string; renderable: boolean;
};

const keyOf = (path: string) => path.match(/^\/elements\/([^/]+)/)?.[1]?.replace(/~1/g, "/").replace(/~0/g, "~");
const segs = (path: string) => path.split("/").slice(1).map((s) => s.replace(/~1/g, "/").replace(/~0/g, "~"));
const errors = (v: Validation) => v.issues.filter((i) => i.severity === "error");
const PROSE = new Set(["Answer", "Group", "Claim"]);

function removeRefs(s: SpecLike, key: string) {
  for (const el of Object.values(s.elements)) if (Array.isArray(el?.children)) el.children = el.children.filter((c) => c !== key);
}
function dropElement(s: SpecLike, key: string) { delete s.elements[key]; removeRefs(s, key); }

/** One-datum / two-datum charts become a Stat / EvidenceTable instead of disappearing. */
function downgrade(el: El): El | undefined {
  const p = el.props;
  const pts: { label: string; value: any }[] =
    el.type === "BarCompare" ? p.bars
    : el.type === "RangeCompare" ? p.rows
    : el.type === "TrendLine" && p.series.length === 1 ? p.series[0].points.map((pt: any) => ({ label: String(pt.x), value: pt.y }))
    : [];
  if (pts.length === 1) return { type: "Stat", props: { value: pts[0]!.value, label: pts[0]!.label, caption: p.caption } };
  if (pts.length === 2) return {
    type: "EvidenceTable",
    props: {
      columns: [{ key: "label", label: el.type === "TrendLine" ? p.x.label : "" }, { key: "value", label: p.measure, align: "end" }],
      rows: pts.map((r) => ({ label: r.label, value: r.value })),
      caption: p.caption,
    },
  };
}

export function autoFix(input: SpecLike, reg: Registry): { spec: SpecLike; actions: RepairAction[] } {
  const s: SpecLike = structuredClone(input);
  const actions: RepairAction[] = [];
  const act = (kind: string, target: string, detail: string) => actions.push({ stage: "auto", kind, target, detail });
  for (let pass = 0; pass < 10; pass++) { // index-shifting fixes `break` and re-validate
    const v = validateSpec(s, reg);
    let changed = false;
    for (const i of v.issues) {
      const path = segs(i.path);
      const parent = getAt(s, path.slice(0, -1));
      const last = path[path.length - 1]!;
      const key = keyOf(i.path);
      if (i.code === "unknown_key" && parent && typeof parent === "object") { delete parent[last]; act("drop_key", i.path, `removed unknown key "${last}"`); changed = true; }
      else if (i.code === "numeric_string" && parent) { parent[last] = Number(parent[last]); act("coerce_number", i.path, `"${getAt(input, path)}" → ${parent[last]}`); changed = true; }
      else if (i.code === "child_missing" && Array.isArray(parent)) { parent.splice(Number(last), 1); act("drop_ref", i.path, "removed reference to a missing child"); changed = true; break; }
      else if (i.code === "cycle" && Array.isArray(parent)) { parent.splice(Number(last), 1); act("break_cycle", i.path, "removed the back-edge child reference"); changed = true; break; }
      else if (i.code === "orphan" && key) { dropElement(s, key); act("drop_orphan", i.path, `"${key}" unreachable from root`); changed = true; }
      else if ((i.code === "root_missing" || i.code === "root_not_answer")) {
        const answers = Object.keys(s.elements).filter((k) => s.elements[k]?.type === "Answer");
        if (answers.length === 1) { s.root = answers[0]!; act("set_root", "/root", `root → "${answers[0]}"`); changed = true; }
      }
      else if (i.code === "chart_min_data" && key && s.elements[key] && !i.path.includes("/panels/")) {
        const d = downgrade(s.elements[key]!);
        if (d) { act("downgrade", `/elements/${key}`, `${s.elements[key]!.type} → ${d.type}`); s.elements[key] = d; changed = true; }
      }
      else if (i.code === "group_visuals" && key) { changed = moveExtraVisuals(s, key, act) || changed; }
    }
    if (!changed) break;
  }
  return { spec: s, actions };
}

/** A group with > 2 visuals: move the extras to the next group with room, else a new group after it. */
function moveExtraVisuals(s: SpecLike, gkey: string, act: (k: string, t: string, d: string) => void): boolean {
  const answer = s.elements[s.root];
  const g = s.elements[gkey];
  if (!answer?.children || !g?.children) return false;
  const isVisual = (k: string) => VISUAL_TYPES.has(s.elements[k]?.type ?? "");
  const extras = g.children.filter(isVisual).slice(2);
  g.children = g.children.filter((c) => !extras.includes(c));
  const order = answer.children;
  for (const x of extras) {
    const target = order.slice(order.indexOf(gkey) + 1).find((k) => (s.elements[k]?.children ?? []).filter(isVisual).length < 2);
    if (target) { s.elements[target]!.children!.push(x); act("move_visual", `/elements/${x}`, `${gkey} → ${target}`); continue; }
    if (order.length < 4) {
      const nk = `${gkey}_more`;
      s.elements[nk] = { type: "Group", props: { title: g.props.title }, children: [x] };
      order.splice(order.indexOf(gkey) + 1, 0, nk);
      act("move_visual", `/elements/${x}`, `${gkey} → new group ${nk}`);
    } else { dropElement(s, x); act("drop_visual", `/elements/${x}`, "no group has room"); }
  }
  return extras.length > 0;
}

/** (b) One compact retry prompt: issues by JSON pointer, the offending elements, the catalog for their types. */
export function buildRepairPrompt(s: SpecLike, issues: Issue[], reg: Registry): string {
  const errs = issues.filter((i) => i.severity === "error");
  const keys = [...new Set(errs.map((i) => keyOf(i.path)).filter((k): k is string => !!k && k in s.elements))];
  const types = [...new Set(keys.map((k) => s.elements[k]!.type).filter((t) => COMPONENT_TYPES.includes(t)))];
  const needIds = errs.some((i) => i.code === "cite_unknown");
  return [
    `Your answer view spec has ${errs.length} problem(s). Fix ONLY these elements. Reply with JSONL, one line per element,`,
    `each the COMPLETE corrected element: {"op":"add","path":"/elements/<key>","value":{…}}. To give up on a visual: {"op":"remove","path":"/elements/<key>"}.`,
    `Do not invent numbers or citations: if a number has no citation, remove it or make it a Claim.`,
    ``,
    `Problems (JSON pointer · code · message):`,
    ...errs.map((i) => `- ${i.path} · ${i.code} · ${i.message}`),
    ``,
    `Current elements:`,
    ...keys.map((k) => `${k}: ${JSON.stringify(s.elements[k])}`),
    ...(types.length ? [``, `Catalog for these components:`, ...types.map((t) => componentPrompt(t))] : []),
    ...(needIds ? [``, `Valid citation ids: ${reg.citations.map((c) => c.id).join(", ")}`] : []),
  ].join("\n");
}

/** Apply the model's repair reply: whole-element replacement or removal (repair mode only — not append-only). */
export function applyRepairReply(s: SpecLike, reply: string): { spec: SpecLike; actions: RepairAction[] } {
  const out: SpecLike = structuredClone(s);
  const actions: RepairAction[] = [];
  for (const line of reply.split("\n")) {
    if (!line.trim()) continue;
    let op: any;
    try { op = JSON.parse(line); } catch { actions.push({ stage: "model", kind: "bad_line", target: "", detail: line.slice(0, 60) }); continue; }
    const key = keyOf(op?.path ?? "");
    if (!key || op.path !== `/elements/${key}`) continue;
    if (op.op === "remove") { dropElement(out, key); actions.push({ stage: "model", kind: "remove", target: op.path, detail: "model removed element" }); }
    else if (op.op === "add") { out.elements[key] = op.value; actions.push({ stage: "model", kind: "replace", target: op.path, detail: `model rewrote ${op.value?.type}` }); }
  }
  return { spec: out, actions };
}

/** (c) Drop invalid visuals; keep prose (a bad marker in a Claim resolves as "unresolved" and floors confidence). */
export function fallback(input: SpecLike, reg: Registry): { spec: SpecLike; actions: RepairAction[] } {
  const s: SpecLike = structuredClone(input);
  const actions: RepairAction[] = [];
  const v = validateSpec(s, reg);
  for (const key of new Set(errors(v).map((i) => keyOf(i.path)).filter((k): k is string => !!k))) {
    const el = s.elements[key];
    if (!el) continue;
    if (PROSE.has(el.type) && !v.invalid.has(key)) {
      actions.push({ stage: "fallback", kind: "keep_prose", target: `/elements/${key}`, detail: `${el.type} kept despite: ${errors(v).filter((i) => keyOf(i.path) === key).map((i) => i.code).join(", ")}` });
    } else if (el.type === "Claim" && typeof el.props?.text === "string") {
      s.elements[key] = { type: "Claim", props: { text: el.props.text, confidence: "low" } };
      actions.push({ stage: "fallback", kind: "salvage_claim", target: `/elements/${key}`, detail: "rebuilt as a bare Claim" });
    } else if (el.type !== "Answer") {
      dropElement(s, key);
      actions.push({ stage: "fallback", kind: "drop", target: `/elements/${key}`, detail: `dropped ${el.type ?? "unknown"}` });
    }
  }
  const tidy = autoFix(s, reg); // dropping can orphan things or empty a group
  return { spec: tidy.spec, actions: [...actions, ...tidy.actions] };
}

export function repairSpec(spec: SpecLike, reg: Registry, opts: { modelRetry?: (prompt: string) => string | undefined } = {}): RepairResult {
  const actions: RepairAction[] = [];
  let cur = spec;
  let v = validateSpec(cur, reg);
  let repairPrompt: string | undefined;
  if (errors(v).length) {
    const a = autoFix(cur, reg); cur = a.spec; actions.push(...a.actions); v = validateSpec(cur, reg);
  }
  if (errors(v).length) {
    repairPrompt = buildRepairPrompt(cur, v.issues, reg);
    const reply = opts.modelRetry?.(repairPrompt);
    if (reply) {
      const m = applyRepairReply(cur, reply); cur = m.spec; actions.push(...m.actions);
      const a = autoFix(cur, reg); cur = a.spec; actions.push(...a.actions);
      v = validateSpec(cur, reg);
    }
  }
  if (errors(v).length) {
    const f = fallback(cur, reg); cur = f.spec; actions.push(...f.actions); v = validateSpec(cur, reg);
  }
  const renderable = cur.elements[cur.root]?.type === "Answer" && v.invalid.size === 0;
  return { spec: cur, actions, validation: v, repairPrompt, renderable };
}

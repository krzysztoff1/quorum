// validateSpec: Zod shape parse per element + the cheap semantic rules from CATALOG §2–§4.
// Hard limits from §3 are errors; §4's "prompt guidance" limits are warnings.
import type { z } from "zod";
import { model, resolved, COMPONENT_TYPES, VISUAL_TYPES, type El, type Mode, type Registry, type SpecLike } from "./catalog";
import { datumInQuotes, yearInQuotes } from "./numbers";
import { citeRefs, elPath, forEachDatum, getAt, markers, ptr, type Path } from "./walk";

export type Severity = "error" | "warn";
export type Issue = { path: string; code: string; message: string; severity: Severity };
type Add = (path: Path, code: string, message: string, severity?: Severity) => void;

export const issueSink = (issues: Issue[]): Add => (path, code, message, severity = "error") =>
  issues.push({ path: ptr(path), code, message, severity });

// ---------- element-level (used by validateSpec and by the stream compiler on arrival) ----------
export function parseElement(key: string, raw: unknown, mode: Mode = "model"): { el?: El; issues: Issue[] } {
  const issues: Issue[] = [];
  const add = issueSink(issues);
  const type = (raw as any)?.type;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    add(elPath(key), "wrong_type", "element must be an object");
    return { issues };
  }
  if (!COMPONENT_TYPES.includes(type)) {
    add(elPath(key, "type"), "unknown_component", `unknown component type ${JSON.stringify(type)}; allowed: ${COMPONENT_TYPES.join(", ")}`);
    return { issues };
  }
  const schema = (mode === "model" ? model : resolved).elementSchemas[type]!;
  const r = schema.safeParse(raw);
  if (r.success) return { el: r.data as El, issues };
  for (const iss of r.error.issues) mapZodIssue(iss, raw, elPath(key), add);
  return { issues };
}

function mapZodIssue(iss: z.core.$ZodIssue, raw: unknown, base: Path, add: Add) {
  const path = [...base, ...(iss.path as Path)];
  const input = getAt(raw, iss.path as Path);
  switch (iss.code) {
    case "unrecognized_keys":
      for (const k of iss.keys) add([...path, k], "unknown_key", `unknown key "${k}"`);
      return;
    case "invalid_type":
    case "invalid_union":
      if (typeof input === "number" && (iss.code === "invalid_union" || iss.expected === "object"))
        return add(path, "bare_number", `bare number ${input}: every number must be a Datum {v|lo,hi, unit, basis, cite}`);
      if (iss.code === "invalid_type" && iss.expected === "number" && typeof input === "string" && input.trim() !== "" && Number.isFinite(Number(input)))
        return add(path, "numeric_string", `"${input}" is a string, expected a number`);
      if (input === undefined) return add(path, "missing_prop", iss.message);
      return add(path, "wrong_type", iss.message);
    case "invalid_value":
      return add(path, "invalid_enum", iss.message);
    case "custom":
      return add(path, (iss.params as any)?.code ?? "schema", iss.message);
    default:
      return add(path, "schema", iss.message);
  }
}

// ---------- spec-level ----------
export type Validation = { ok: boolean; issues: Issue[]; invalid: Set<string> };

export function validateSpec(spec: unknown, reg: Registry, mode: Mode = "model"): Validation {
  const issues: Issue[] = [];
  const add = issueSink(issues);
  const invalid = new Set<string>();
  const s = spec as SpecLike;
  if (!s || typeof s !== "object" || typeof s.elements !== "object" || s.elements === null) {
    add([], "envelope", "spec must be {v:1, root, elements}");
    return { ok: false, issues, invalid };
  }
  if (s.v !== 1) add(["v"], "envelope", "v must be 1");
  for (const k of Object.keys(s)) if (!["v", "root", "elements"].includes(k)) add([k], "unknown_key", `unknown key "${k}"`);

  const els = s.elements;
  const parsed: Record<string, El> = {};
  for (const [key, raw] of Object.entries(els)) {
    const r = parseElement(key, raw, mode);
    issues.push(...r.issues);
    if (r.el) parsed[key] = r.el; else invalid.add(key);
  }

  // citations exist
  const known = new Map(reg.citations.map((c) => [c.id, c]));
  for (const [key, raw] of Object.entries(els))
    for (const ref of citeRefs((raw as any)?.props, elPath(key, "props")))
      if (!known.has(ref.id)) add(ref.path, "cite_unknown", `citation "${ref.id}" is not in this run's citations`);

  graphChecks(s, add);
  const answer = parsed[s.root]?.type === "Answer" ? parsed[s.root]! : undefined;
  for (const [key, el] of Object.entries(parsed)) componentRules(key, el, { answer, known, add });
  budgetChecks(s, parsed, answer, add);

  return { ok: !issues.some((i) => i.severity === "error"), issues, invalid };
}

function graphChecks(s: SpecLike, add: Add) {
  const els = s.elements;
  const typeOf = (k: string) => (els[k] as any)?.type;
  if (!(s.root in els)) add(["root"], "root_missing", `root "${s.root}" is not an element`);
  else if (typeOf(s.root) !== "Answer") add(["root"], "root_not_answer", `root must be an Answer, got ${typeOf(s.root)}`);
  const answers = Object.keys(els).filter((k) => typeOf(k) === "Answer");
  if (answers.length !== 1) add(["elements"], "answer_count", `exactly one Answer required, found ${answers.length}`);

  const kids = (k: string): string[] => (Array.isArray((els[k] as any)?.children) ? (els[k] as any).children : []);
  for (const k of Object.keys(els))
    kids(k).forEach((c, i) => {
      if (!(c in els)) add(elPath(k, "children", i), "child_missing", `child "${c}" does not exist`);
      else if (typeOf(k) === "Answer" && typeOf(c) !== "Group") add(elPath(k, "children", i), "answer_children", `Answer children must be Groups, "${c}" is ${typeOf(c)}`);
      else if (typeOf(k) === "Group" && ["Answer", "Group"].includes(typeOf(c))) add(elPath(k, "children", i), "group_children", `a Group cannot contain ${typeOf(c)} "${c}"`);
    });

  // cycles (DFS colouring) and reachability
  const color = new Map<string, 1 | 2>();
  const dfs = (k: string) => {
    color.set(k, 1);
    kids(k).forEach((c, i) => {
      if (!(c in els)) return;
      if (color.get(c) === 1) add(elPath(k, "children", i), "cycle", `"${k}" → "${c}" closes a cycle`);
      else if (!color.has(c)) dfs(c);
    });
    color.set(k, 2);
  };
  if (s.root in els) dfs(s.root);
  for (const k of Object.keys(els)) if (!color.has(k)) add(elPath(k), "orphan", `"${k}" is not reachable from root`, "warn");
}

type Ctx = { answer?: El; known: Map<string, { quote: string }>; add: Add };
const words = (s: string) => s.replace(/\[\^[^\]]+\]/g, "").trim().split(/\s+/).filter(Boolean).length;
const count = (add: Add, path: Path, n: number, min: number, max: number, code: string, what: string) => {
  if (n < min) add(path, code, `${what}: ${n}, needs ≥ ${min}`);
  else if (n > max) add(path, code, `${what}: ${n}, max ${max}`);
};
const unitsOf = (xs: any[]) => new Set(xs.filter(Boolean).map((d) => d.unit));

/** Chart rules shared by top-level charts and SmallMultiples panels. */
function chartRules(type: string, p: any, at: Path, add: Add) {
  if (type === "RangeCompare") {
    if (p.rows.length < 2) add([...at, "rows"], "chart_min_data", `RangeCompare has ${p.rows.length} row(s); needs ≥ 2 (else a Stat)`);
    if (p.rows.length > 8) add([...at, "rows"], "rows_max", `RangeCompare has ${p.rows.length} rows; max 8`);
    if (unitsOf([...p.rows.map((r: any) => r.value), p.reference?.value]).size > 1) add([...at, "rows"], "unit_mixed", "rows use different units; one axis = one unit");
  }
  if (type === "BarCompare") {
    if (p.bars.length < 3) add([...at, "bars"], "chart_min_data", `BarCompare has ${p.bars.length} bar(s); a chart needs ≥ 3 (else Stat / EvidenceTable)`);
    if (p.bars.length > 8) add([...at, "bars"], "rows_max", `BarCompare has ${p.bars.length} bars; max 8`);
    if (unitsOf(p.bars.map((b: any) => b.value)).size > 1) add([...at, "bars"], "unit_mixed", "bars use different units");
    p.bars.forEach((b: any, i: number) => !b.value.asOf && add([...at, "bars", i, "value", "asOf"], "asof_missing", `bar "${b.label}" has no asOf`));
  }
  if (type === "TrendLine") {
    count(add, [...at, "series"], p.series.length, 1, 4, "series_count", "series");
    p.series.forEach((s: any, i: number) => s.points.length < 3 && add([...at, "series", i, "points"], "chart_min_data", `series "${s.label}" has ${s.points.length} point(s); needs ≥ 3`));
    if (unitsOf([...p.series.flatMap((s: any) => s.points.map((pt: any) => pt.y)), p.reference?.value]).size > 1) add([...at, "series"], "unit_mixed", "series mix units; one axis");
  }
}

function componentRules(key: string, el: El, { answer, known, add }: Ctx) {
  const p = el.props;
  const at = elPath(key, "props");
  // numbers drawn as "reported" must be in a cited quote (warn: rendered as unverified, not blocked)
  forEachDatum(p, at, (d, path) => {
    if (d.basis !== "reported") return;
    const quotes = (d.cite as string[]).map((c) => known.get(c)?.quote).filter((q): q is string => !!q);
    if (quotes.length && !datumInQuotes(d, quotes))
      add(path, "number_not_in_quote", `${d.v ?? `${d.lo}–${d.hi}`}${d.scale ?? ""} ${d.unit} is not in the cited quote(s) ${d.cite.join(", ")}`, "warn");
    if (d.label && d.label.length > 32) add([...path, "label"], "label_long", "label > 32 chars", "warn");
  });
  switch (el.type) {
    case "Answer":
      count(add, elPath(key, "children"), el.children?.length ?? 0, 1, 4, "answer_size", "Answer groups");
      if (words(p.lead) > 40) add([...at, "lead"], "lead_long", `lead is ${words(p.lead)} words; ≤ 40`, "warn");
      break;
    case "Group":
      count(add, elPath(key, "children"), el.children?.length ?? 0, 1, 6, "group_size", "Group children");
      if (words(p.title) > 8) add([...at, "title"], "title_long", `title is ${words(p.title)} words; ≤ 8`, "warn");
      break;
    case "Claim":
      if (!markers(p.text).length) add([...at, "text"], "claim_uncited", "a Claim needs ≥ 1 [^id] marker");
      break;
    case "RangeCompare": case "BarCompare": case "TrendLine":
      chartRules(el.type, p, at, add);
      break;
    case "SmallMultiples":
      count(add, [...at, "panels"], p.panels.length, 2, 6, "panels_count", "panels");
      p.panels.forEach((pn: any, i: number) => chartRules(p.of, pn.props, [...at, "panels", i, "props"], add));
      break;
    case "ConflictSplit":
      count(add, [...at, "sides"], p.sides.length, 2, 3, "sides_count", "sides");
      if (p.leaning && !(p.leaning.side >= 0 && p.leaning.side < p.sides.length)) add([...at, "leaning", "side"], "leaning_side", `leaning.side ${p.leaning.side} is not a side index`);
      break;
    case "EvidenceTable": {
      if (p.columns.length > 6) add([...at, "columns"], "columns_max", `${p.columns.length} columns; max 6`);
      if (p.rows.length > 12) add([...at, "rows"], "rows_max", `${p.rows.length} rows; max 12`);
      const cols = new Set(p.columns.map((c: any) => c.key));
      p.rows.forEach((r: any, i: number) => Object.keys(r).forEach((k) => !cols.has(k) && add([...at, "rows", i, k], "table_key", `"${k}" is not a column key`)));
      break;
    }
    case "Timeline": {
      count(add, [...at, "events"], p.events.length, 3, 12, "events_count", "events");
      if ((p.kinds?.length ?? 0) > 4) add([...at, "kinds"], "kinds_max", "≤ 4 kinds");
      const kinds = new Set((p.kinds ?? []).map((k: any) => k.key));
      p.events.forEach((e: any, i: number) => {
        if (e.kind && !kinds.has(e.kind)) add([...at, "events", i, "kind"], "kind_unknown", `kind "${e.kind}" is not in kinds`);
        const quotes = e.cite.map((c: string) => known.get(c)?.quote).filter(Boolean);
        if (p.axis === "date" && quotes.length && yearInQuotes(e.at, quotes) === false)
          add([...at, "events", i, "at"], "date_not_in_quote", `year of "${e.at}" is not in the cited quote`, "warn");
      });
      break;
    }
    case "DecisionMatrix": {
      count(add, [...at, "options"], p.options.length, 2, 6, "matrix_size", "options");
      count(add, [...at, "criteria"], p.criteria.length, 2, 6, "matrix_size", "criteria");
      const opts = new Set(p.options.map((o: any) => o.key));
      const crit = new Set(p.criteria.map((c: any) => c.key));
      p.cells.forEach((c: any, i: number) => {
        if (!opts.has(c.option) || !crit.has(c.criterion)) add([...at, "cells", i], "matrix_ref", `cell refers to unknown option/criterion ${c.option}/${c.criterion}`);
        if (c.rating !== null && !c.cite.length) add([...at, "cells", i, "cite"], "matrix_cell_uncited", `rated cell ${c.option}/${c.criterion} has no citation`);
      });
      if (p.recommend && !opts.has(p.recommend.option)) add([...at, "recommend", "option"], "matrix_ref", `recommend.option "${p.recommend.option}" is not an option`);
      break;
    }
    case "Quadrant":
      count(add, [...at, "points"], p.points.length, 4, 20, "points_count", "points");
    {
      const est: Path[] = [];
      forEachDatum(p, at, (d, path) => d.basis === "estimate" && est.push(path));
      if (est.length) add(est[0]!, "quadrant_estimate", `${est.length} Quadrant coordinate(s) are estimates; every coordinate must be a cited measurement`);
      break;
    }
    case "ArgumentMap": {
      count(add, [...at, "nodes"], p.nodes.length, 3, 9, "nodes_count", "nodes");
      const ids = new Set(p.nodes.map((n: any) => n.id));
      p.nodes.forEach((n: any, i: number) => n.parent && !ids.has(n.parent) && add([...at, "nodes", i, "parent"], "node_parent", `parent "${n.parent}" is not a node`));
      if (answer?.props.verdict === "settled") add(elPath(key), "argmap_settled", "ArgumentMap in a settled answer is decoration", "warn");
      break;
    }
  }
}

function budgetChecks(s: SpecLike, parsed: Record<string, El>, answer: El | undefined, add: Add) {
  const typeOf = (k: string) => (s.elements[k] as any)?.type as string | undefined;
  let total = 0, crowded = false, mixes = 0;
  for (const [k, el] of Object.entries(s.elements) as [string, El][]) {
    if (el?.type === "SourceMix") mixes++;
    if (el?.type !== "Group" || !Array.isArray(el.children)) continue;
    const visuals = el.children.filter((c) => VISUAL_TYPES.has(typeOf(c) ?? ""));
    total += visuals.length;
    if (visuals.length > 2) add(elPath(k, "children"), "group_visuals", `Group has ${visuals.length} visuals; max 2`);
    if (visuals.length > 1) crowded = true;
    let run = 0;
    el.children.forEach((c, i) => {
      run = typeOf(c) === "Stat" ? run + 1 : 0;
      if (run === 3) add(elPath(k, "children", i), "stat_row", "≥ 3 Stats in a row is a dashboard", "warn");
    });
  }
  if (total > 3 || crowded) add(["elements"], "visual_budget", `${total} visuals; guidance is ≤ 1 per group and ≤ 3 per answer`, "warn");
  if (mixes > 1) add(["elements"], "sourcemix_multiple", `${mixes} SourceMix elements; use at most one`, "warn");
  if (answer?.props.verdict === "inconclusive")
    for (const [k, el] of Object.entries(parsed))
      if (VISUAL_TYPES.has(el.type)) add(elPath(k), "inconclusive_visual", `an inconclusive answer gets no visuals except SourceMix (${el.type})`);
}

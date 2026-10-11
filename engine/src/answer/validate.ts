import type { z } from "zod";
import {
  COMPONENT_TYPES,
  modelCatalog,
  resolvedCatalog,
  VISUAL_TYPES,
  type Element,
  type Mode,
  type Spec,
} from "./catalog.js";
import { datumInQuotes, formatDatum, numericStringValue } from "./numbers.js";
import { citeRefs, elementPath, forEachDatum, markers, pointer, valueAt, type Path } from "./walk.js";

export type Severity = "error" | "warn";

export interface Issue {
  path: string;
  code: string;
  message: string;
  severity: Severity;
}

export interface KnownCitation {
  id: string;
  quote: string;
  match: string;
}

export interface Validation {
  ok: boolean;
  issues: Issue[];
  invalid: Set<string>;
}

type Report = (path: Path, code: string, message: string, severity?: Severity) => void;

export const MAX_GROUPS = 4;
export const MAX_GROUP_CHILDREN = 6;
export const MAX_VISUALS = 3;
export const MAX_GROUP_VISUALS = 1;
const LEAD_WORDS = 40;
const TITLE_WORDS = 8;
const LABEL_CHARS = 32;

export function reporter(issues: Issue[]): Report {
  return (path, code, message, severity = "error") => issues.push({ path: pointer(path), code, message, severity });
}

export function errors(validation: Validation): Issue[] {
  return validation.issues.filter((issue) => issue.severity === "error");
}

export function parseElement(key: string, raw: unknown, mode: Mode = "model"): { element?: Element; issues: Issue[] } {
  const issues: Issue[] = [];
  const report = reporter(issues);
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    report(elementPath(key), "wrong_type", "an element must be an object");
    return { issues };
  }
  const type = (raw as any).type;
  if (!COMPONENT_TYPES.includes(type)) {
    report(elementPath(key, "type"), "unknown_component",
      `unknown component ${JSON.stringify(type)}; the catalog has ${COMPONENT_TYPES.join(", ")}`);
    return { issues };
  }
  const schema = (mode === "model" ? modelCatalog : resolvedCatalog).elementSchemas[type]!;
  const parsed = schema.safeParse(raw);
  if (parsed.success) return { element: parsed.data as unknown as Element, issues };
  for (const issue of parsed.error.issues) translate(issue, raw, elementPath(key), report);
  return { issues };
}

function translate(issue: z.core.$ZodIssue, raw: unknown, base: Path, report: Report): void {
  const path = [...base, ...(issue.path as Path)];
  const input = valueAt(raw, issue.path as Path);
  switch (issue.code) {
    case "unrecognized_keys":
      for (const key of issue.keys) report([...path, key], "unknown_key", `unknown key "${key}"`);
      return;
    case "invalid_type":
    case "invalid_union":
      if (typeof input === "number" && (issue.code === "invalid_union" || issue.expected === "object")) {
        return report(path, "bare_number", `bare number ${input}: every number is a datum {v or lo/hi, unit, basis, cite}`);
      }
      if (issue.code === "invalid_type" && issue.expected === "number" && typeof input === "string"
          && numericStringValue(input) !== undefined) {
        return report(path, "numeric_string", `"${input}" is a string, a number was expected`);
      }
      if (input === undefined) return report(path, "missing_prop", issue.message);
      return report(path, "wrong_type", issue.message);
    case "invalid_value":
      return report(path, "invalid_enum", issue.message);
    case "too_small":
      return report(path, input === undefined || Array.isArray(input) ? "missing_prop" : "schema", issue.message);
    case "custom":
      return report(path, (issue.params as any)?.code ?? "schema", issue.message);
    default:
      return report(path, "schema", issue.message);
  }
}

const SETTLED_WARNINGS = new Set(["claim_uncited", "lead_uncited", "answer_empty", "answer_size", "group_size"]);

export function validateSpec(spec: unknown, citations: KnownCitation[], mode: Mode = "model",
                             options: { settled?: boolean; language?: string } = {}): Validation {
  const issues: Issue[] = [];
  const raw = reporter(issues);
  const report: Report = (path, code, message, severity) =>
    raw(path, code, message, options.settled && SETTLED_WARNINGS.has(code) ? "warn" : severity);
  const invalid = new Set<string>();
  const candidate = spec as Spec;
  if (!candidate || typeof candidate !== "object" || !candidate.elements || typeof candidate.elements !== "object") {
    report([], "envelope", "a spec is {v: 1, root, elements}");
    return { ok: false, issues, invalid };
  }
  if (candidate.v !== 1) report(["v"], "envelope", "v must be 1");

  const parsed: Record<string, Element> = {};
  for (const [key, raw] of Object.entries(candidate.elements)) {
    const result = parseElement(key, raw, mode);
    issues.push(...result.issues);
    if (result.element) parsed[key] = result.element;
    else invalid.add(key);
  }

  const known = new Map(citations.map((c) => [c.id, c]));
  for (const [key, raw] of Object.entries(candidate.elements)) {
    for (const ref of citeRefs((raw as any)?.props, elementPath(key, "props"))) {
      if (!known.has(ref.id)) report(ref.path, "cite_unknown", `citation "${ref.id}" is not one of this run's quotes`);
    }
  }

  graphRules(candidate, report);
  const answer = parsed[candidate.root]?.type === "Answer" ? parsed[candidate.root] : undefined;
  for (const [key, element] of Object.entries(parsed)) componentRules(key, element, known, report, options.language);
  budgetRules(candidate, answer, report);
  return { ok: !issues.some((i) => i.severity === "error"), issues, invalid };
}

function childrenOf(spec: Spec, key: string): string[] {
  const children = (spec.elements[key] as any)?.children;
  return Array.isArray(children) ? children : [];
}

function typeOf(spec: Spec, key: string): string | undefined {
  return (spec.elements[key] as any)?.type;
}

function graphRules(spec: Spec, report: Report): void {
  if (!(spec.root in spec.elements)) report(["root"], "root_missing", `root "${spec.root}" is not an element`);
  else if (typeOf(spec, spec.root) !== "Answer") report(["root"], "root_not_answer", `the root must be an Answer, not ${typeOf(spec, spec.root)}`);
  const answers = Object.keys(spec.elements).filter((k) => typeOf(spec, k) === "Answer");
  if (answers.length !== 1) report(["elements"], "answer_count", `exactly one Answer, found ${answers.length}`);

  for (const key of Object.keys(spec.elements)) {
    childrenOf(spec, key).forEach((child, index) => {
      const at = elementPath(key, "children", index);
      if (!(child in spec.elements)) report(at, "child_missing", `child "${child}" does not exist`);
      else if (typeOf(spec, key) === "Answer" && typeOf(spec, child) !== "Group") {
        report(at, "answer_children", `an Answer holds Groups, "${child}" is a ${typeOf(spec, child)}`);
      } else if (typeOf(spec, key) === "Group" && (typeOf(spec, child) === "Answer" || typeOf(spec, child) === "Group")) {
        report(at, "group_children", `a Group cannot hold the ${typeOf(spec, child)} "${child}"`);
      }
    });
  }

  const colour = new Map<string, 1 | 2>();
  const walk = (key: string) => {
    colour.set(key, 1);
    childrenOf(spec, key).forEach((child, index) => {
      if (!(child in spec.elements)) return;
      if (colour.get(child) === 1) report(elementPath(key, "children", index), "cycle", `"${key}" → "${child}" closes a cycle`);
      else if (!colour.has(child)) walk(child);
    });
    colour.set(key, 2);
  };
  if (spec.root in spec.elements) walk(spec.root);
  for (const key of Object.keys(spec.elements)) {
    if (!colour.has(key)) report(elementPath(key), "orphan", `"${key}" is not reachable from the root`, "warn");
  }
}

function words(text: string): number {
  return text.replace(/\[\^[^\]]+\]/g, "").trim().split(/\s+/).filter(Boolean).length;
}

function countRule(report: Report, path: Path, n: number, min: number, max: number, low: string, high: string, what: string): void {
  if (n < min) report(path, low, `${what}: ${n}, needs at least ${min}`);
  else if (n > max) report(path, high, `${what}: ${n}, at most ${max}`);
}

function unitsOf(datums: unknown[]): Set<string> {
  return new Set(datums.filter(Boolean).map((d: any) => d.unit));
}

function componentRules(key: string, element: Element, known: Map<string, KnownCitation>, report: Report, language?: string): void {
  const props = element.props;
  const at = elementPath(key, "props");
  forEachDatum(props, at, (datum, path) => {
    if (datum.label && datum.label.length > LABEL_CHARS) report([...path, "label"], "label_long", `label over ${LABEL_CHARS} characters`, "warn");
    if (datum.basis !== "reported") return;
    const quotes = (datum.cite as string[]).map((id) => known.get(id)).filter((c) => c && c.match !== "unresolved").map((c) => c!.quote);
    if (quotes.length > 0 && !datumInQuotes(datum as any, quotes, language)) {
      report(path, "number_not_in_quote", `${formatDatum(datum as any)} is not in the quote(s) ${datum.cite.join(", ")}`, "warn");
    }
  });
  if (VISUAL_TYPES.has(element.type) && markers(String(props.caption ?? "")).length === 0) {
    report([...at, "caption"], "caption_uncited", "every visual needs a cited caption");
  }
  switch (element.type) {
    case "Answer":
      countRule(report, elementPath(key, "children"), element.children?.length ?? 0, 1, MAX_GROUPS, "answer_empty", "answer_size", "groups");
      if (markers(props.lead).length === 0) report([...at, "lead"], "lead_uncited", "the lead needs at least one marker");
      if (words(props.lead) > LEAD_WORDS) report([...at, "lead"], "lead_long", `the lead is ${words(props.lead)} words, at most ${LEAD_WORDS}`, "warn");
      return;
    case "Group":
      countRule(report, elementPath(key, "children"), element.children?.length ?? 0, 1, MAX_GROUP_CHILDREN, "group_empty", "group_size", "group children");
      if (words(props.title) > TITLE_WORDS) report([...at, "title"], "title_long", `the title is ${words(props.title)} words, at most ${TITLE_WORDS}`, "warn");
      return;
    case "Claim":
      if (markers(props.text).length === 0) report([...at, "text"], "claim_uncited", "a Claim needs at least one marker");
      return;
    case "RangeCompare":
      countRule(report, [...at, "rows"], props.rows.length, 2, 8, "chart_min_data", "rows_max", "rows");
      if (unitsOf([...props.rows.map((r: any) => r.value), props.reference?.value]).size > 1) {
        report([...at, "rows"], "unit_mixed", "the rows use different units; one axis takes one unit");
      }
      return;
    case "BarCompare":
      countRule(report, [...at, "bars"], props.bars.length, 3, 8, "chart_min_data", "rows_max", "bars");
      if (unitsOf(props.bars.map((b: any) => b.value)).size > 1) report([...at, "bars"], "unit_mixed", "the bars use different units");
      props.bars.forEach((bar: any, index: number) => {
        if (!bar.value.as_of) report([...at, "bars", index, "value", "as_of"], "asof_missing", `bar "${bar.label}" has no as_of`);
      });
      return;
    case "ConflictSplit":
      countRule(report, [...at, "sides"], props.sides.length, 2, 3, "sides_count", "sides_count", "sides");
      if (props.leaning && !(props.leaning.side >= 0 && props.leaning.side < props.sides.length)) {
        report([...at, "leaning", "side"], "leaning_side", `leaning.side ${props.leaning.side} is not a side`);
      }
      return;
    case "EvidenceTable": {
      countRule(report, [...at, "rows"], props.rows.length, 1, 12, "chart_min_data", "rows_max", "rows");
      if (props.columns.length > 6) report([...at, "columns"], "columns_max", `${props.columns.length} columns, at most 6`);
      const columns = new Set(props.columns.map((c: any) => c.key));
      props.rows.forEach((row: Record<string, unknown>, index: number) => {
        for (const cell of Object.keys(row)) {
          if (!columns.has(cell)) report([...at, "rows", index, cell], "table_key", `"${cell}" is not a column`);
        }
      });
      return;
    }
  }
}

function budgetRules(spec: Spec, answer: Element | undefined, report: Report): void {
  const visual = (key: string) => VISUAL_TYPES.has(typeOf(spec, key) ?? "");
  const groups = answer?.children ?? [];
  let total = 0;
  for (const group of groups) {
    const visuals = childrenOf(spec, group).filter(visual);
    total += visuals.length;
    if (visuals.length > MAX_GROUP_VISUALS) {
      report(elementPath(group, "children"), "group_visuals", `${visuals.length} visuals in one group, at most ${MAX_GROUP_VISUALS}`);
    }
  }
  if (total > MAX_VISUALS) report(["elements"], "visual_budget", `${total} visuals, at most ${MAX_VISUALS}`);
  const mixes = Object.keys(spec.elements).filter((k) => typeOf(spec, k) === "SourceMix");
  if (mixes.length > 1) report(elementPath(mixes[1]!), "sourcemix_multiple", `${mixes.length} SourceMix elements, at most one`);
  if (answer?.props.verdict === "inconclusive") {
    for (const key of Object.keys(spec.elements).filter(visual)) {
      report(elementPath(key), "inconclusive_visual", `an inconclusive answer draws no ${typeOf(spec, key)}`);
    }
  }
}

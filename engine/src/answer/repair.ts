import { CHART_TYPES, COMPONENT_TYPES, PROSE_TYPES, VISUAL_TYPES, type Element, type Spec } from "./catalog.js";
import { componentPrompt } from "./prompt.js";
import {
  errors,
  MAX_GROUPS,
  MAX_VISUALS,
  validateSpec,
  type Issue,
  type KnownCitation,
  type Validation,
} from "./validate.js";
import { elementKeyOf, isDatum, markers, MARKER, segments, valueAt } from "./walk.js";

export interface RepairAction {
  stage: "auto" | "model" | "fallback";
  action: string;
  element_id: string;
  detail: string;
}

export interface DroppedVisual {
  element_id: string;
  type: string;
  reason: string;
}

export interface Repaired {
  spec: Spec;
  actions: RepairAction[];
  validation: Validation;
  dropped: DroppedVisual[];
  stripped: string[];
  renderable: boolean;
  prompt?: string;
}

export type RepairRetry = (prompt: string) => Promise<string | undefined>;

const PASSES = 80;
const CITE_CODES = new Set(["cite_unknown", "claim_uncited", "lead_uncited", "caption_uncited"]);
const CAPTION_CONFIDENCE = "medium";
const MAX_CAPTION_MARKERS = 3;

export async function repairSpec(input: Spec, citations: KnownCitation[], options: { retry?: RepairRetry } = {}): Promise<Repaired> {
  const actions: RepairAction[] = [];
  let spec = autoFix(structuredClone(input), citations, actions);
  const validation = validateSpec(spec, citations);
  let prompt: string | undefined;
  if (errors(validation).length > 0 && options.retry) {
    prompt = repairPrompt(spec, validation.issues, citations);
    const reply = await options.retry(prompt).catch(() => undefined);
    if (reply) spec = autoFix(applyRepairReply(spec, reply, actions), citations, actions);
  }
  return { ...settleRepairs(spec, citations, actions), ...(prompt ? { prompt } : {}) };
}

export function repairSpecWithoutModel(input: Spec, citations: KnownCitation[]): Repaired {
  const actions: RepairAction[] = [];
  return settleRepairs(autoFix(structuredClone(input), citations, actions), citations, actions);
}

function settleRepairs(input: Spec, citations: KnownCitation[], actions: RepairAction[]): Repaired {
  let spec = input;
  let validation = validateSpec(spec, citations);
  const dropped: DroppedVisual[] = [];
  const stripped: string[] = [];
  if (errors(validation).length > 0) {
    spec = fallback(spec, citations, actions, dropped, stripped);
  }
  validation = validateSpec(spec, citations, "model", { settled: true });
  return { spec, actions, validation, dropped, stripped, renderable: renderable(spec) };
}

function renderable(spec: Spec): boolean {
  const root = spec.elements[spec.root];
  return root?.type === "Answer" && typeof root.props?.lead === "string" && root.props.lead.trim().length > 0;
}

function act(actions: RepairAction[], stage: RepairAction["stage"], action: string, elementId: string, detail: string): void {
  actions.push({ stage, action, element_id: elementId, detail });
}

function removeReferences(spec: Spec, key: string): void {
  for (const element of Object.values(spec.elements)) {
    if (Array.isArray(element?.children)) element.children = element.children.filter((child) => child !== key);
  }
}

function dropElement(spec: Spec, key: string): void {
  delete spec.elements[key];
  removeReferences(spec, key);
}

function groupsOf(spec: Spec): string[] {
  return spec.elements[spec.root]?.children ?? [];
}

function isVisual(spec: Spec, key: string): boolean {
  return VISUAL_TYPES.has(spec.elements[key]?.type ?? "") || !COMPONENT_TYPES.includes(spec.elements[key]?.type ?? "Claim");
}

function captionClaim(caption: unknown): Element | undefined {
  if (typeof caption !== "string" || markers(caption).length === 0) return undefined;
  return { type: "Claim", props: { text: caption, confidence: CAPTION_CONFIDENCE } };
}

function toProse(spec: Spec, key: string): Element | undefined {
  const prose = captionClaim(spec.elements[key]?.props?.caption);
  if (prose) spec.elements[key] = prose;
  else dropElement(spec, key);
  return prose;
}

function downgrade(element: Element): Element | undefined {
  const props = element.props;
  const points: { label: string; value: unknown }[] = element.type === "BarCompare" ? props.bars : element.type === "RangeCompare" ? props.rows : [];
  if (points.length === 1) {
    return { type: "Stat", props: { value: points[0]!.value, label: points[0]!.label, caption: props.caption } };
  }
  if (points.length === 2) return tableOf(points, props.measure, props.caption);
  return undefined;
}

function tableOf(points: { label: string; value: unknown }[], measure: string, caption: string): Element {
  return {
    type: "EvidenceTable",
    props: {
      columns: [{ key: "label", label: "" }, { key: "value", label: measure ?? "", align: "end" }],
      rows: points.map((point) => ({ label: point.label, value: point.value })),
      caption,
    },
  };
}

type Fix = (spec: Spec, issue: Issue, actions: RepairAction[]) => boolean;

const FIXES: Record<string, Fix> = {
  unknown_key(spec, issue, actions) {
    const path = segments(issue.path);
    const parent = valueAt(spec, path.slice(0, -1));
    if (!parent || typeof parent !== "object") return false;
    delete parent[path.at(-1)!];
    act(actions, "auto", "drop_key", elementKeyOf(issue.path) ?? "", `removed unknown key "${path.at(-1)}"`);
    return true;
  },
  numeric_string(spec, issue, actions) {
    const path = segments(issue.path);
    const parent = valueAt(spec, path.slice(0, -1));
    const last = path.at(-1)!;
    const before = parent?.[last];
    parent[last] = Number(String(before).replace(",", "."));
    act(actions, "auto", "coerce_number", elementKeyOf(issue.path) ?? "", `"${before}" → ${parent[last]}`);
    return true;
  },
  child_missing: spliceChild("drop_ref", "removed a reference to a missing element"),
  cycle: spliceChild("break_cycle", "removed the reference that closed a cycle"),
  root_missing: setRoot,
  root_not_answer: setRoot,
  orphan(spec, issue, actions) {
    const key = elementKeyOf(issue.path)!;
    dropElement(spec, key);
    act(actions, "auto", "drop_orphan", key, "not reachable from the root");
    return true;
  },
  answer_children(spec, issue, actions) {
    const path = segments(issue.path);
    const index = Number(path.at(-1));
    const groups = groupsOf(spec);
    const child = groups[index]!;
    groups.splice(index, 1);
    const isGroup = (k: string) => spec.elements[k]?.type === "Group";
    const after = groups.slice(index).find(isGroup);
    const before = groups.slice(0, index).reverse().find(isGroup);
    if (after) spec.elements[after]!.children!.unshift(child);
    else if (before) spec.elements[before]!.children!.push(child);
    else {
      const key = freshKey(spec, "group");
      spec.elements[key] = { type: "Group", props: { title: "" }, children: [child] };
      groups.splice(index, 0, key);
    }
    act(actions, "auto", "regroup", child, "moved into a group");
    return true;
  },
  group_children(spec, issue, actions) {
    const path = segments(issue.path);
    const outer = path[1]!;
    const index = Number(path.at(-1));
    const inner = spec.elements[outer]!.children!.splice(index, 1)[0]!;
    const groups = groupsOf(spec);
    groups.splice(groups.indexOf(outer) + 1, 0, inner);
    act(actions, "auto", "hoist_group", inner, `moved out of ${outer}`);
    return true;
  },
  chart_min_data(spec, issue, actions) {
    const key = elementKeyOf(issue.path)!;
    const element = spec.elements[key]!;
    if (CHART_TYPES.has(element.type)) {
      const lesser = downgrade(element);
      if (!lesser) return false;
      spec.elements[key] = lesser;
      act(actions, "auto", "downgrade", key, `${element.type} → ${lesser.type}`);
      return true;
    }
    toProse(spec, key);
    act(actions, "auto", "to_prose", key, `an empty ${element.type}`);
    return true;
  },
  group_empty(spec, issue, actions) {
    const key = elementKeyOf(issue.path)!;
    if (groupsOf(spec).length <= 1) return false;
    dropElement(spec, key);
    act(actions, "auto", "drop_group", key, "an empty group");
    return true;
  },
  group_visuals(spec, issue, actions) {
    const group = elementKeyOf(issue.path)!;
    const visuals = spec.elements[group]!.children!.filter((k) => isVisual(spec, k));
    const extra = visuals[1]!;
    spec.elements[group]!.children = spec.elements[group]!.children!.filter((k) => k !== extra);
    const groups = groupsOf(spec);
    const room = groups.slice(groups.indexOf(group) + 1)
      .find((k) => spec.elements[k]?.type === "Group" && !spec.elements[k]!.children!.some((c) => isVisual(spec, c)));
    if (room) {
      spec.elements[room]!.children!.push(extra);
      act(actions, "auto", "move_visual", extra, `${group} → ${room}`);
    } else if (groups.length < MAX_GROUPS) {
      const key = freshKey(spec, `${group}_more`);
      spec.elements[key] = { type: "Group", props: { title: "" }, children: [extra] };
      groups.splice(groups.indexOf(group) + 1, 0, key);
      act(actions, "auto", "move_visual", extra, `${group} → a new group`);
    } else {
      spec.elements[group]!.children!.push(extra);
      toProse(spec, extra);
      act(actions, "auto", "to_prose", extra, "no group had room for another visual");
    }
    return true;
  },
  visual_budget(spec, _issue, actions) {
    const visuals = groupsOf(spec).flatMap((g) => spec.elements[g]?.children ?? []).filter((k) => isVisual(spec, k));
    for (const key of visuals.slice(MAX_VISUALS)) {
      toProse(spec, key);
      act(actions, "auto", "to_prose", key, `over the answer's ${MAX_VISUALS} visuals`);
    }
    return visuals.length > MAX_VISUALS;
  },
  inconclusive_visual(spec, issue, actions) {
    const key = elementKeyOf(issue.path)!;
    toProse(spec, key);
    act(actions, "auto", "to_prose", key, "an inconclusive answer draws nothing");
    return true;
  },
  sourcemix_multiple(spec, issue, actions) {
    const key = elementKeyOf(issue.path)!;
    dropElement(spec, key);
    act(actions, "auto", "drop_duplicate", key, "a second SourceMix");
    return true;
  },
};

function spliceChild(action: string, detail: string): Fix {
  return (spec, issue, actions) => {
    const path = segments(issue.path);
    const list = valueAt(spec, path.slice(0, -1));
    if (!Array.isArray(list)) return false;
    list.splice(Number(path.at(-1)), 1);
    act(actions, "auto", action, elementKeyOf(issue.path) ?? "", detail);
    return true;
  };
}

function setRoot(spec: Spec, _issue: Issue, actions: RepairAction[]): boolean {
  const answers = Object.keys(spec.elements).filter((k) => spec.elements[k]?.type === "Answer");
  if (answers.length !== 1 || spec.root === answers[0]) return false;
  spec.root = answers[0]!;
  act(actions, "auto", "set_root", spec.root, "the only Answer is the root");
  return true;
}

function freshKey(spec: Spec, base: string): string {
  let key = base;
  for (let n = 2; key in spec.elements; n++) key = `${base}${n}`;
  return key;
}

export function autoFix(spec: Spec, citations: KnownCitation[], actions: RepairAction[]): Spec {
  for (let pass = 0; pass < PASSES; pass++) {
    const validation = validateSpec(spec, citations);
    const fixed = validation.issues.some((issue) => FIXES[issue.code]?.(spec, issue, actions) ?? false);
    if (!fixed) break;
  }
  return spec;
}

export function repairPrompt(spec: Spec, issues: Issue[], citations: KnownCitation[]): string {
  const failing = issues.filter((issue) => issue.severity === "error");
  const keys = [...new Set(failing.map((issue) => elementKeyOf(issue.path)).filter((k): k is string => !!k && k in spec.elements))];
  const types = [...new Set(keys.map((k) => spec.elements[k]!.type).filter((t) => COMPONENT_TYPES.includes(t)))];
  const needsIds = failing.some((issue) => CITE_CODES.has(issue.code));
  return [
    `Your answer spec has ${failing.length} problem(s). Fix ONLY these elements. Reply with JSONL, one line per element,`,
    `each the COMPLETE corrected element: {"op":"add","path":"/elements/<key>","value":{…}}.`,
    `To give up on a visual instead: {"op":"remove","path":"/elements/<key>"}.`,
    `Do not invent numbers or citations: a number without a citation is removed or said in a Claim.`,
    `A Claim or the lead is never removed: give it the marker of the quote that states it, or return it unchanged.`,
    "",
    "Problems (JSON pointer · code · message):",
    ...failing.map((issue) => `- ${issue.path} · ${issue.code} · ${issue.message}`),
    "",
    "Current elements:",
    ...keys.map((key) => `${key}: ${JSON.stringify(spec.elements[key])}`),
    ...(types.length > 0 ? ["", "The catalog for these components:", ...types.map(componentPrompt)] : []),
    ...(needsIds ? ["", `Valid citation ids: ${citations.filter((c) => c.match !== "unresolved").map((c) => c.id).join(", ")}`] : []),
  ].join("\n");
}

export function applyRepairReply(input: Spec, reply: string, actions: RepairAction[]): Spec {
  const spec = structuredClone(input);
  const body = /```(?:qvs|jsonl|json)?[^\n]*\n([\s\S]*?)(?:```|$)/.exec(reply)?.[1] ?? reply;
  for (const line of body.split("\n")) {
    if (!line.trim()) continue;
    let op: any;
    try {
      op = JSON.parse(line);
    } catch {
      continue;
    }
    const key = typeof op?.path === "string" ? elementKeyOf(op.path) : undefined;
    if (!key || op.path !== `/elements/${key}` || !(key in spec.elements)) continue;
    if (op.op === "remove") {
      if (PROSE_TYPES.has(spec.elements[key]!.type)) {
        act(actions, "model", "kept_prose", key, "the model asked to remove prose; text always survives");
        continue;
      }
      toProse(spec, key);
      act(actions, "model", "remove", key, "the model gave up on it");
      continue;
    }
    if (op.op !== "add" && op.op !== "replace") continue;
    if (!op.value || typeof op.value !== "object") continue;
    const children = spec.elements[key]!.children;
    spec.elements[key] = { ...op.value, ...(children && !op.value?.children ? { children } : {}) };
    act(actions, "model", "replace", key, `the model rewrote the ${op.value?.type}`);
  }
  return spec;
}

function fallback(input: Spec, citations: KnownCitation[], actions: RepairAction[],
                  dropped: DroppedVisual[], stripped: string[]): Spec {
  let spec = stripUnknownMarkers(input, citations, stripped);
  const validation = validateSpec(spec, citations, "model", { settled: true });
  const failing = new Map<string, string[]>();
  for (const issue of errors(validation)) {
    const key = elementKeyOf(issue.path);
    if (key && key in spec.elements) failing.set(key, [...(failing.get(key) ?? []), issue.code]);
  }
  const known = new Set(citations.map((c) => c.id));
  for (const [key, codes] of failing) {
    const element = spec.elements[key]!;
    if (element.type === "Answer") continue;
    if (element.type === "Group") {
      spec.elements[key] = { type: "Group", props: { title: String(element.props?.title ?? "") }, children: element.children ?? [] };
      act(actions, "fallback", "rebuild_group", key, codes.join(", "));
      continue;
    }
    if (element.type === "Claim") {
      spec.elements[key] = { type: "Claim", props: { text: String(element.props?.text ?? ""), confidence: "low" } };
      act(actions, "fallback", "rebuild_claim", key, codes.join(", "));
      continue;
    }
    const table = element.type === "EvidenceTable" ? undefined : salvageTable(element, known);
    if (table && validateElement(key, table, citations)) {
      spec.elements[key] = table;
      act(actions, "fallback", "to_table", key, `${element.type} → EvidenceTable (${codes.join(", ")})`);
      continue;
    }
    dropped.push({ element_id: key, type: String(element.type), reason: codes.join(", ") });
    const prose = toProse(spec, key);
    act(actions, "fallback", prose ? "to_prose" : "drop", key, `${element.type}: ${codes.join(", ")}`);
  }
  spec = autoFix(spec, citations, actions);
  return spec;
}

function validateElement(key: string, element: Element, citations: KnownCitation[]): boolean {
  const probe: Spec = {
    v: 1, root: "probe",
    elements: {
      probe: { type: "Answer", props: { lead: `probe${markers(element.props.caption ?? "").map((m) => `[^${m}]`).join("")}` }, children: ["g"] },
      g: { type: "Group", props: { title: "probe" }, children: [key] },
      [key]: element,
    },
  };
  return validateSpec(probe, citations).ok;
}

function datumPoints(element: Element): { label: string; value: any }[] {
  const props = element.props ?? {};
  switch (element.type) {
    case "Stat":
      return [{ label: props.label, value: props.value }, ...(props.of ? [{ label: props.of.label ?? "", value: props.of }] : [])];
    case "RangeCompare":
      return [...(props.rows ?? []), ...(props.reference ? [props.reference] : [])];
    case "BarCompare":
      return props.bars ?? [];
    case "ConflictSplit":
      return (props.sides ?? []).filter((side: any) => isDatum(side.headline)).map((side: any) => ({ label: side.label, value: side.headline }));
    default:
      return [];
  }
}

function salvageTable(element: Element, known: Set<string>): Element | undefined {
  const points = datumPoints(element).filter((point) =>
    typeof point?.label === "string" && isDatum(point.value) && Array.isArray(point.value.cite)
    && point.value.cite.length > 0 && point.value.cite.every((id: unknown) => typeof id === "string" && known.has(id)));
  if (points.length === 0) return undefined;
  const caption = typeof element.props?.caption === "string" && markers(element.props.caption).length > 0
    ? element.props.caption
    : `${element.props?.measure ?? element.props?.label ?? ""}${[...new Set(points.flatMap((p) => p.value.cite))].slice(0, MAX_CAPTION_MARKERS).map((id) => `[^${id}]`).join("")}`;
  return tableOf(points, element.props?.measure ?? element.props?.label ?? "", caption);
}

function stripUnknownMarkers(input: Spec, citations: KnownCitation[], stripped: string[]): Spec {
  const known = new Set(citations.map((c) => c.id));
  const spec = structuredClone(input);
  const strip = (text: string) => text.replace(MARKER, (marker, id: string) => {
    if (known.has(id)) return marker;
    if (!stripped.includes(id)) stripped.push(id);
    return "";
  });
  const walk = (node: any): any => {
    if (typeof node === "string") return strip(node);
    if (Array.isArray(node)) return node.map(walk);
    if (node && typeof node === "object") {
      for (const [key, value] of Object.entries(node)) if (key !== "cite") node[key] = walk(value);
    }
    return node;
  };
  for (const element of Object.values(spec.elements)) if (element?.props) element.props = walk(element.props);
  return spec;
}

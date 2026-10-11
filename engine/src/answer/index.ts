import { type Element, type ResolvedSpec, type Spec } from "./catalog.js";
import { compileJsonl, extractSpecBlock } from "./compile.js";
import { answerMarkdown, fallbackMarkdown } from "./markdown.js";
import { repairSpec, repairSpecWithoutModel, type DroppedVisual, type RepairAction, type RepairRetry } from "./repair.js";
import { resolveSpec, type CheckIssue, type ResolveInput } from "./resolve.js";
import { validateSpec, type Issue, type KnownCitation } from "./validate.js";
import { datumInQuotes, formatDatum } from "./numbers.js";
import { stripMarkers, elementKeyOf, markers, segments, valueAt } from "./walk.js";
import { datumUnits, readingOrder } from "./datums.js";
import { lastJsonFence } from "../fence.js";

export { catalogPrompt } from "./prompt.js";
export { datumUnits } from "./datums.js";
export { CATALOG_VERSION } from "./catalog.js";

export interface AnswerDraft {
  spec: Spec;
  origin: "spec" | "prose";
  actions: RepairAction[];
  dropped: DroppedVisual[];
  stripped: string[];
  issues: Issue[];
}

export interface SettledAnswer {
  origin: "spec" | "prose";
  spec: ResolvedSpec;
  display: Record<string, "chart" | "table">;
  fallback_md: Record<string, string>;
  check: { ok: boolean; issues: CheckIssue[] };
  repairs: RepairAction[];
  markdown: string;
}

export interface DraftObjection {
  lens: "claim_sweep" | "structure";
  statement: string;
  severity: "blocking" | "minor";
  followup: string;
}

const APPENDIX = /^##\s+(Sources|Citation check|Validation)\b/m;
const STREAM_CODES = new Set(["parse_error", "patch_rejected"]);

export async function draftAnswer(reply: string, citations: KnownCitation[], retry?: RepairRetry): Promise<AnswerDraft> {
  const block = extractSpecBlock(reply);
  if (block) {
    const compiled = compileJsonl(block.jsonl);
    const repaired = await repairSpec(withQuarantined(compiled.spec, compiled.quarantined), citations, retry ? { retry } : {});
    if (repaired.renderable) {
      return {
        spec: repaired.spec, origin: "spec", actions: repaired.actions, dropped: repaired.dropped, stripped: repaired.stripped,
        issues: [...compiled.issues.filter((i) => STREAM_CODES.has(i.code)), ...repaired.validation.issues],
      };
    }
    return proseDraft(block.prose, citations, [...repaired.actions, { stage: "fallback", action: "prose_answer", element_id: "", detail: "the spec's root could not be rendered" }]);
  }
  return proseDraft(reply, citations, []);
}

export function draftFromProse(reply: string, citations: KnownCitation[], reason?: string): AnswerDraft {
  return proseDraft(reply, citations, reason ? [{ stage: "fallback", action: "prose_answer", element_id: "", detail: reason }] : []);
}

function withQuarantined(spec: Spec, quarantined: Map<string, { type?: string; raw: unknown }>): Spec {
  const elements = { ...spec.elements };
  for (const [key, entry] of quarantined) {
    if (key in elements) continue;
    const raw = entry.raw;
    elements[key] = raw && typeof raw === "object" && !Array.isArray(raw)
      ? { ...(raw as Element), props: (raw as any).props ?? {} }
      : { type: entry.type ?? "Unknown", props: {} } as Element;
  }
  return { ...spec, elements };
}

function proseDraft(reply: string, citations: KnownCitation[], actions: RepairAction[]): AnswerDraft {
  const repaired = repairSpecWithoutModel(specFromProse(proseBody(reply)), citations);
  return {
    spec: repaired.spec, origin: "prose", actions: [...actions, ...repaired.actions], dropped: repaired.dropped,
    stripped: repaired.stripped, issues: repaired.validation.issues,
  };
}

function proseBody(reply: string): string {
  const fence = lastJsonFence(reply);
  const body = fence === -1 ? reply : reply.slice(0, fence);
  const appendix = body.search(APPENDIX);
  return appendix === -1 ? body : body.slice(0, appendix);
}

export function specFromProse(markdown: string): Spec {
  const blocks = markdown.split(/\n\s*\n/).map((b) => b.trim()).filter(Boolean)
    .filter((b) => !b.startsWith("```") && !/^\[\^[^\]]+\]:/.test(b));
  const elements: Record<string, Element> = {};
  const groups: string[] = [];
  let lead = "";
  let current: Element | undefined;
  let claimCount = 0;
  const openGroup = (title: string) => {
    const key = `g${groups.length + 1}`;
    current = { type: "Group", props: { title }, children: [] };
    elements[key] = current;
    groups.push(key);
  };
  for (const block of blocks) {
    const heading = /^#{1,6}\s+(.*)$/.exec(block);
    if (heading) {
      openGroup(heading[1]!.trim());
      continue;
    }
    if (!lead && groups.length === 0 && !block.startsWith("|")) {
      lead = joinLines(block.split("\n"));
      continue;
    }
    for (const text of block.startsWith("|") ? tableClaimTexts(block) : claimTexts(block)) {
      if (!current) openGroup("");
      const key = `c${++claimCount}`;
      elements[key] = { type: "Claim", props: { text, confidence: "medium" } };
      current!.children!.push(key);
    }
  }
  if (!lead) lead = promoteFirstClaim(elements, groups);
  elements.answer = { type: "Answer", props: { lead }, children: groups };
  return { v: 1, root: "answer", elements };
}

function promoteFirstClaim(elements: Record<string, Element>, groups: string[]): string {
  const home = groups.find((key) => (elements[key]!.children ?? []).length > 0);
  if (!home) return "";
  const claimKey = elements[home]!.children!.shift()!;
  const text = String(elements[claimKey]!.props.text);
  delete elements[claimKey];
  if (elements[home]!.children!.length === 0) {
    delete elements[home];
    groups.splice(groups.indexOf(home), 1);
  }
  return text;
}

const TABLE_RULE = /^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$/;
const MARKER_TEXT = /\[\^[^\]]+\]/g;

function tableCells(line: string): string[] {
  return line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((cell) => cell.trim());
}

function tableClaimTexts(block: string): string[] {
  const lines = block.split("\n").filter((line) => line.trim().startsWith("|"));
  const [header, ...body] = lines.map(tableCells);
  const rows = body.filter((cells) => !TABLE_RULE.test(cells.join("|")));
  return rows.map((cells) => {
    const markers = cells.flatMap((cell) => cell.match(MARKER_TEXT) ?? []);
    const [label = "", ...rest] = cells.map((cell) => cell.replace(MARKER_TEXT, "").trim());
    const described = rest
      .map((cell, index) => (cell && header?.[index + 1] ? `${header[index + 1]} ${cell}` : cell))
      .filter(Boolean);
    const text = label ? `${label}: ${described.join("; ")}` : described.join("; ");
    return text.replace(/:\s*$/, "") + markers.join("");
  }).filter((text) => text.length > 0);
}

const LIST_ITEM = /^([-*+]|\d+[.)])\s+/;

function joinLines(lines: string[]): string {
  return lines.map((l) => l.trim().replace(/^>\s?/, "")).filter(Boolean).join(" ");
}

function claimTexts(block: string): string[] {
  const lines = block.split("\n");
  if (!LIST_ITEM.test(lines[0]!.trim())) return [joinLines(lines)].filter(Boolean);
  const items: string[][] = [];
  for (const line of lines) {
    if (LIST_ITEM.test(line.trim())) items.push([line.trim().replace(LIST_ITEM, "")]);
    else items.at(-1)?.push(line);
  }
  return items.map(joinLines).filter(Boolean);
}

export interface SpecFinding {
  claim: string;
  confidence: string;
  citations: string[];
  sources: string[];
}

export function specFindings(spec: Spec, citations: { id: string; source_id: string; match: string }[],
                             urlOf: (sourceId: string) => string | undefined): SpecFinding[] {
  const located = new Map(citations.filter((c) => c.match !== "unresolved").map((c) => [c.id, c.source_id]));
  return readingOrder(spec).map((key) => spec.elements[key]!).filter((element) => element.type === "Claim").map((element) => {
    const ids = [...new Set(markers(String(element.props.text)))];
    const urls = ids.map((id) => located.get(id)).filter((s): s is string => Boolean(s)).map(urlOf).filter((u): u is string => Boolean(u));
    return { claim: stripMarkers(String(element.props.text)), confidence: String(element.props.confidence), citations: ids, sources: [...new Set(urls)] };
  });
}

export function draftMarkdown(draft: AnswerDraft): string {
  return answerMarkdown(draft.spec, fallbackMarkdown(draft.spec));
}

export function untracedObjections(draft: AnswerDraft, citations: KnownCitation[]): DraftObjection[] {
  const located = new Map(citations.filter((c) => c.match !== "unresolved").map((c) => [c.id, c.quote]));
  const objections: DraftObjection[] = [];
  for (const unit of datumUnits(draft.spec, citations.map((c) => ({ source_id: "", ...c })))) {
    const datum = valueAtPointer(draft.spec, unit.pointer);
    if (datum?.basis !== "reported") continue;
    const quotes = (datum.cite as string[]).map((id) => located.get(id)).filter((q): q is string => Boolean(q));
    if (datumInQuotes(datum, quotes)) continue;
    const label = unit.claim.split(":")[0]!;
    const measure = unit.context.split(" — ")[0] ?? "";
    objections.push({
      lens: "claim_sweep", severity: "blocking",
      statement: `the figure ${label} = ${formatDatum(datum)} is not in its cited quote (${datum.cite.join(", ")})`,
      followup: `find a primary source that states the figure for ${label}${measure ? `: ${measure}` : ""}`,
    });
  }
  return objections;
}

export function droppedObjections(draft: AnswerDraft): DraftObjection[] {
  return draft.dropped.map((visual) => ({
    lens: "structure", severity: "minor",
    statement: `a ${visual.type} (${visual.element_id}) was dropped from the answer: ${visual.reason}`,
    followup: `redraw the ${visual.type} from cited figures, or keep it as prose: ${visual.element_id}`,
  }));
}

function valueAtPointer(spec: Spec, pointerText: string): any {
  return valueAt(spec, segments(pointerText));
}

export function settleAnswer(draft: AnswerDraft, context: ResolveInput): SettledAnswer {
  const resolved = resolveSpec(draft.spec, context);
  const validation = validateSpec(resolved.spec, context.citations, "resolved", { settled: true });
  const issues: CheckIssue[] = [
    ...validation.issues.map((issue) => ({
      element_id: elementKeyOf(issue.path) ?? "", rule: issue.code, severity: issue.severity, detail: issue.message,
    })).filter((issue) => issue.rule !== "number_not_in_quote"),
    ...resolved.issues,
  ];
  const root = resolved.spec.elements[resolved.spec.root];
  const renderable = root?.type === "Answer" && stripMarkers(String((root.props as any).lead ?? "")).length > 0;
  return {
    origin: draft.origin,
    spec: resolved.spec,
    display: resolved.display,
    fallback_md: resolved.fallback_md,
    check: { ok: renderable && !issues.some((i) => i.severity === "error"), issues },
    repairs: draft.actions,
    markdown: answerMarkdown(resolved.spec as unknown as Spec, resolved.fallback_md),
  };
}

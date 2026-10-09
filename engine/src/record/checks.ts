import { isDeepStrictEqual } from "node:util";
import { markerIds } from "../validate.js";
import { detectLanguage } from "./language.js";
import { QuestionSchema, RunRecordSchema, type Question, type RecordCheck, type RunRecord } from "./schema.js";
import { citedSourceIds, computeStats } from "./stats.js";
import { titleProblem } from "./title.js";
import { VISUAL_TYPES, type Tier } from "../answer/catalog.js";
import { citationTier, datumConfidence } from "../answer/resolve.js";
import { validateSpec } from "../answer/validate.js";
import { datumInQuotes } from "../answer/numbers.js";
import { citeRefs, forEachDatum, markers, pointer } from "../answer/walk.js";

export interface RecordInput {
  record: RunRecord;
  question: Question | undefined;
}

const SHOWN_PROBLEMS = 5;

export function checkRecord(input: RecordInput): RecordCheck[] {
  return [
    checkSchema(input),
    checkStats(input.record),
    checkReferences(input.record),
    checkAnswer(input.record),
    checkSpec(input.record),
    checkTitle(input.question),
    checkLanguage(input.record),
    checkLimits(input.record),
  ];
}

function result(id: string, name: string, problems: string[], pass: string): RecordCheck {
  if (problems.length === 0) return { id, name, status: "pass", detail: pass };
  const shown = problems.slice(0, SHOWN_PROBLEMS).join("; ");
  const more = problems.length > SHOWN_PROBLEMS ? `; +${problems.length - SHOWN_PROBLEMS} more` : "";
  return { id, name, status: "fail", detail: shown + more };
}

function checkSchema({ record, question }: RecordInput): RecordCheck {
  const problems: string[] = [];
  const parsed = RunRecordSchema.safeParse(record);
  if (!parsed.success) {
    problems.push(...parsed.error.issues.map((i) => `run.json ${i.path.join(".") || "(root)"}: ${i.message}`));
  }
  if (question) {
    const q = QuestionSchema.safeParse(question);
    if (!q.success) problems.push(...q.error.issues.map((i) => `question.json ${i.path.join(".") || "(root)"}: ${i.message}`));
  }
  return result("schema", "the record validates against its schema", problems, record.schema);
}

function checkStats(record: RunRecord): RecordCheck {
  const problems: string[] = [];
  const { stats, checks, ...rest } = record;
  let recomputed;
  try {
    recomputed = computeStats(rest);
  } catch (error) {
    return result("stats", "stats recompute from the record", [`stats could not be recomputed: ${String(error)}`], "");
  }
  for (const key of Object.keys(recomputed) as (keyof typeof recomputed)[]) {
    if (!isDeepStrictEqual(recomputed[key], stats?.[key])) {
      problems.push(`${key} is stored as ${JSON.stringify(stats?.[key])}, the record says ${JSON.stringify(recomputed[key])}`);
    }
  }
  const cited = citedSourceIds(record);
  for (const source of record.sources) {
    if (source.cited !== cited.has(source.id)) problems.push(`source ${source.id} is flagged cited=${source.cited}`);
  }
  return result("stats", "stats recompute from the record", problems,
    `${stats.sources_cited} cited · ${stats.sources_read} read · ${stats.claims} claim(s) · trust ${stats.trust_level}`);
}

function checkReferences(record: RunRecord): RecordCheck {
  const name = "every marker, citation and open item resolves";
  const citations = new Set(record.citations.map((c) => c.id));
  const sources = new Set(record.sources.map((s) => s.id));
  const problems: string[] = [];
  const texts: [string, string][] = [
    ["the answer", record.answer?.markdown ?? ""],
    ...record.tasks.map((t): [string, string] => [t.id, t.writeup ?? ""]),
  ];
  for (const [where, text] of texts) {
    for (const id of new Set(markerIds(text))) if (!citations.has(id)) problems.push(`[^${id}] in ${where} names no citation`);
  }
  for (const [key, element] of Object.entries(record.answer?.spec.elements ?? {}) as [string, any][]) {
    for (const ref of citeRefs(element.props, [])) {
      if (!citations.has(ref.id)) problems.push(`${key} in the answer spec cites ${ref.id}, which is not a citation`);
    }
  }
  for (const claim of record.claims) {
    for (const id of claim.citation_ids) if (!citations.has(id)) problems.push(`claim ${claim.id} cites ${id}, which is not a citation`);
  }
  for (const task of record.tasks) {
    for (const finding of task.findings) {
      for (const id of finding.citation_ids) if (!citations.has(id)) problems.push(`a finding of ${task.id} cites ${id}, which is not a citation`);
    }
  }
  for (const citation of record.citations) {
    if (citation.match !== "unresolved" && !sources.has(citation.source_id)) problems.push(`${citation.id} quotes ${citation.source_id}, which the record does not hold`);
  }
  const ids = {
    conflicts: new Set(record.conflicts.map((c) => c.id)),
    objections: new Set((record.validation?.objections_open ?? []).map((o) => o.id)),
    gaps: new Set(record.gaps.map((g) => g.id)),
    failed_tasks: new Set(record.tasks.map((t) => t.id)),
  };
  for (const [kind, known] of Object.entries(ids) as [keyof typeof ids, Set<string>][]) {
    for (const id of record.open_items[kind]) if (!known.has(id)) problems.push(`open item ${kind}/${id} names nothing`);
  }
  const verdict = result("references", name, problems, `${citations.size} citation(s) over ${sources.size} source(s)`);
  if (verdict.status === "fail" || record.stripped_markers.length === 0) return verdict;
  return {
    id: "references", name, status: "warn",
    detail: record.stripped_markers.map((m) => `[^${m.marker}] stripped from ${m.task_id}`).join("; ")
      + ": the model cited a quote it never declared",
  };
}

function checkAnswer(record: RunRecord): RecordCheck {
  const problems: string[] = [];
  if (record.status === "complete" && !record.answer) problems.push("the run is complete but holds no answer");
  if (record.answer) {
    const task = record.tasks.find((t) => t.id === record.answer!.task_id);
    if (!task) problems.push(`the answer names task ${record.answer.task_id}, which the record does not hold`);
    else if (task.status !== "complete") problems.push(`the answer comes from ${task.id}, which ended ${task.status}`);
    if (!record.answer.markdown.trim()) problems.push("the answer is empty");
  }
  return result("answer", "a finished answer is present and comes from a completed task", problems,
    record.answer ? `answer from ${record.answer.task_id}` : `no answer (${record.status})`);
}

const TIER_RANK: Tier[] = ["supported", "close", "unsupported", "unresolved"];

function checkSpec(record: RunRecord): RecordCheck {
  const name = "the answer spec validates, and every datum's trust is the engine's";
  const answer = record.answer;
  if (!answer) return { id: "spec", name, status: "pass", detail: "no answer" };
  const problems: string[] = [];
  const citations = new Map(record.citations.map((c) => [c.id, c]));
  const validation = validateSpec(answer.spec, record.citations, "resolved", { settled: true });
  for (const issue of validation.issues.filter((i) => i.severity === "error")) problems.push(`${issue.path}: ${issue.code}`);
  if (!answer.check.ok) problems.push("the engine's own answer check did not pass");
  let visuals = 0;
  let datums = 0;
  for (const [key, element] of Object.entries(answer.spec.elements) as [string, any][]) {
    const visual = VISUAL_TYPES.has(element.type);
    if (visual) visuals += 1;
    if (visual || element.type === "SourceMix") {
      if (!answer.display[key]) problems.push(`${key} has no display`);
      if (!answer.fallback_md[key]) problems.push(`${key} has no fallback text`);
    }
    if (visual && markers(String(element.props.caption ?? "")).length === 0) problems.push(`${key} has no cited caption`);
    forEachDatum(element.props, ["elements", key, "props"], (datum, path) => {
      datums += 1;
      const at = pointer(path);
      const trust = datum.trust;
      if (!trust) return void problems.push(`${at} has no trust`);
      const located = (datum.cite as string[]).map((id) => citations.get(id)).filter((c) => c && c.match !== "unresolved").map((c) => c!.quote);
      const quoted = datumInQuotes(datum as any, located);
      if ((trust.trace === "quoted") !== quoted) problems.push(`${at} trace is ${trust.trace}, its quotes say ${quoted ? "quoted" : "not quoted"}`);
      const floor = (datum.cite as string[]).map((id) => citationTier(citations.get(id), record.pipeline.grounding))
        .reduce<Tier>((w, t) => (TIER_RANK.indexOf(t) > TIER_RANK.indexOf(w) ? t : w), "supported");
      if (TIER_RANK.indexOf(trust.tier) < TIER_RANK.indexOf(floor)) problems.push(`${at} tier ${trust.tier} is better than its quotes (${floor})`);
      if (trust.confidence !== datumConfidence(datum.basis, trust.tier, trust.trace)) problems.push(`${at} confidence ${trust.confidence} does not follow from its trust`);
    });
  }
  return result("spec", name, problems, `${visuals} visual${visuals === 1 ? "" : "s"} · ${datums} datum${datums === 1 ? "" : "s"} · ${answer.origin}`);
}

function checkTitle(question: Question | undefined): RecordCheck {
  const name = "the question's title names the question";
  if (!question) return { id: "title", name, status: "warn", detail: "no question.json beside the run" };
  const problem = titleProblem(question.title, question.title_source);
  return result("title", name, problem ? [`"${question.title}": ${problem}`] : [], `"${question.title}" (from ${question.title_source})`);
}

function checkLanguage(record: RunRecord): RecordCheck {
  const name = "the answer is in the question's language";
  const expected = record.brief.language;
  if (!record.answer || expected === "und") return { id: "language", name, status: "pass", detail: "nothing to compare" };
  const found = detectLanguage(record.answer.markdown);
  if (found === "und" || found === expected) return { id: "language", name, status: "pass", detail: expected };
  return { id: "language", name, status: "warn", detail: `the question is ${expected}, the answer reads as ${found}` };
}

function checkLimits(record: RunRecord): RecordCheck {
  const name = "the run kept to its cost cap and deadline";
  const warnings: string[] = [];
  const { cap_usd, deadline_s } = record.limits;
  if (cap_usd !== undefined && record.cost.usd > cap_usd) warnings.push(`cost $${record.cost.usd.toFixed(2)} over the $${cap_usd} cap`);
  if (deadline_s !== undefined && record.stats.duration_s > deadline_s) {
    warnings.push(`${record.stats.duration_s}s over the ${deadline_s}s deadline`);
  }
  if (warnings.length > 0) return { id: "limits", name, status: "warn", detail: warnings.join("; ") };
  return { id: "limits", name, status: "pass", detail: `$${record.cost.usd.toFixed(2)} in ${record.stats.duration_s}s` };
}

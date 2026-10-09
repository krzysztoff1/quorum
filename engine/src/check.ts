import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { PROTOCOL_VERSION } from "./emitter.js";
import { EvidenceStore, type Citation, type SourceDocument } from "./evidence.js";
import { parseFencedJson } from "./agent.js";
import { checkRecord } from "./record/checks.js";
import type { Question, RunRecord } from "./record/schema.js";
import { readStoredRun } from "./record/store.js";

export type CheckStatus = "pass" | "fail" | "warn";

export interface CheckResult {
  id: string;
  name: string;
  status: CheckStatus;
  detail: string;
}

export interface CheckReport {
  ok: boolean;
  failed: number;
  warnings: number;
  results: CheckResult[];
}

export interface RunInput {
  events: any[];
  evidenceDir: string | undefined;
  malformedLines: number;
  record?: RunRecord;
  question?: Question;
  recordProblem?: string;
}

const MARKER = /\[\^([A-Za-z0-9_-]{1,32})\]/g;
const VERDICTS = new Set(["supported", "unsupported", "misquoted"]);
const COST_EPSILON = 1e-9;

export function loadRunDir(runDir: string): RunInput {
  const events: any[] = [];
  let malformedLines = 0;
  const eventsPath = join(runDir, "events.ndjson");
  if (existsSync(eventsPath)) {
    for (const line of readFileSync(eventsPath, "utf8").split("\n")) {
      if (!line.trim()) continue;
      try {
        events.push(JSON.parse(line));
      } catch {
        malformedLines += 1;
      }
    }
  }
  const evidenceDir = join(runDir, "evidence");
  const stored = readStoredRun(runDir);
  return {
    events,
    evidenceDir: existsSync(evidenceDir) ? evidenceDir : undefined,
    malformedLines,
    ...(stored.record ? { record: stored.record } : {}),
    ...(stored.question ? { question: stored.question } : {}),
    recordProblem: stored.problem ?? (stored.record ? undefined : "the run directory holds no run.json"),
  };
}

export function checkRun(input: RunInput): CheckReport {
  const view = new RunView(input);
  const results = [
    checkStamp(view),
    checkStream(view),
    checkMarkers(view),
    checkSources(view),
    checkSpans(view),
    checkSnapshots(view),
    checkCounts(view),
    checkVerdicts(view),
    checkGrounding(view),
    checkRefusal(view),
    ...recordChecks(input),
  ];
  const failed = results.filter((r) => r.status === "fail").length;
  const warnings = results.filter((r) => r.status === "warn").length;
  return { ok: failed === 0, failed, warnings, results };
}

export function formatReport(report: CheckReport): string {
  const rows = report.results.map((r) => `${r.status.toUpperCase().padEnd(5)} ${r.id.padEnd(10)} ${r.detail}`);
  const passed = report.results.filter((r) => r.status === "pass").length;
  rows.push(`check: ${passed} passed, ${report.failed} failed, ${report.warnings} warning${report.warnings === 1 ? "" : "s"}`);
  return rows.join("\n") + "\n";
}

class RunView {
  readonly start: any;
  readonly result: any;
  readonly documents: SourceDocument[];
  readonly captureFailures: any[];
  readonly synthesis: any;
  readonly summary: any;
  readonly writeup: string;
  readonly citations: Citation[];

  constructor(readonly input: RunInput) {
    this.start = input.events.find((e) => e?.type === "run_start");
    const results = input.events.filter((e) => e?.type === "run_result");
    this.result = results.at(-1);
    this.documents = Array.isArray(this.result?.documents) ? this.result.documents : [];
    this.captureFailures = Array.isArray(this.result?.capture_failures) ? this.result.capture_failures : [];
    const syntheses = (this.result?.topics ?? []).filter((t: any) => t?.role === "synthesis" && t?.status === "complete");
    this.synthesis = syntheses.filter((t: any) => t.reconciled).at(-1) ?? syntheses.at(-1);
    this.summary = this.synthesis ? parseFencedJson(String(this.synthesis.result ?? "")) : undefined;
    const text = String(this.synthesis?.result ?? "");
    const fence = text.lastIndexOf("```json");
    this.writeup = fence === -1 ? text : text.slice(0, fence);
    this.citations = Array.isArray(this.summary?.citations) ? this.summary.citations : [];
  }

  get evidenceDir(): string | undefined {
    return this.input.evidenceDir;
  }

  get researched(): boolean {
    return (this.result?.topics ?? []).some((t: any) => t?.role === "research");
  }

  hasCapturedText(document: SourceDocument): boolean {
    return Boolean(document.snapshot_path) || document.text_length > 0;
  }

  documentById(sourceId: string): SourceDocument | undefined {
    return this.documents.find((d) => d.source_id === sourceId);
  }

  failureFor(sourceId: string): boolean {
    return this.captureFailures.some((f) => f?.source_id === sourceId);
  }

  snapshotText(document: SourceDocument): string | undefined {
    if (!this.evidenceDir || !document.snapshot_path) return undefined;
    const path = join(this.evidenceDir, document.snapshot_path);
    return existsSync(path) ? readFileSync(path, "utf8") : undefined;
  }
}

function recordChecks(input: RunInput): CheckResult[] {
  if (input.record) return checkRecord({ record: input.record, question: input.question });
  return [{
    id: "record", name: "the engine wrote the run record", status: "fail",
    detail: input.recordProblem ?? "no run record was written",
  }];
}

function verdict(id: string, name: string, problems: string[], pass: string): CheckResult {
  return problems.length === 0
    ? { id, name, status: "pass", detail: pass }
    : { id, name, status: "fail", detail: problems.slice(0, 5).join("; ") + (problems.length > 5 ? `; +${problems.length - 5} more` : "") };
}

function unverifiable(id: string, name: string, why: string): CheckResult {
  return { id, name, status: "warn", detail: why };
}

function checkStamp(view: RunView): CheckResult {
  const problems: string[] = [];
  if (!view.start) problems.push("no run_start event");
  else {
    if (typeof view.start.build !== "string" || !view.start.build) problems.push("run_start carries no build stamp");
    if (view.start.protocol_version !== PROTOCOL_VERSION) {
      problems.push(`protocol ${view.start.protocol_version ?? "missing"}, engine speaks ${PROTOCOL_VERSION}`);
    }
  }
  return verdict("stamp", "build stamp and protocol", problems, `build ${view.start?.build}, protocol ${PROTOCOL_VERSION}`);
}

function checkStream(view: RunView): CheckResult {
  const { events, malformedLines } = view.input;
  const problems: string[] = [];
  if (events.length === 0) problems.push("no events were recorded");
  else {
    if (events[0]?.type !== "run_start") problems.push("the stream does not begin with run_start");
    if (events.at(-1)?.type !== "run_result") problems.push("the stream does not end with run_result");
    const results = events.filter((e) => e?.type === "run_result").length;
    if (results > 1) problems.push(`${results} run_result events`);
  }
  if (malformedLines > 0) problems.push(`${malformedLines} unreadable line(s)`);
  return verdict("stream", "event stream is well formed", problems, `${events.length} events, run_start to run_result`);
}

function checkMarkers(view: RunView): CheckResult {
  if (!view.synthesis) return { id: "markers", name: "footnote markers resolve", status: "pass", detail: "no completed synthesis to check" };
  const declared = new Set(view.citations.map((c) => c.id));
  const problems: string[] = [];
  const markers = new Set([...view.writeup.matchAll(MARKER)].map((m) => m[1]!));
  for (const marker of markers) if (!declared.has(marker)) problems.push(`marker [^${marker}] names no citation`);
  const findings: any[] = Array.isArray(view.summary?.findings) ? view.summary.findings : [];
  for (const finding of findings) {
    for (const id of Array.isArray(finding?.citations) ? finding.citations : []) {
      if (!declared.has(String(id))) problems.push(`a finding cites ${id}, which the answer never declared`);
    }
  }
  const checked = verdict("markers", "footnote markers resolve", problems, `${markers.size} marker(s), ${declared.size} citation(s)`);
  const stripped: any[] = Array.isArray(view.result?.stripped_markers) ? view.result.stripped_markers : [];
  if (checked.status === "fail" || stripped.length === 0) return checked;
  return {
    ...checked, status: "warn",
    detail: `${checked.detail}; ${stripped.length} dangling marker(s) stripped and flagged: `
      + stripped.map((m) => `[^${m.marker}] in ${m.angle_id}`).join(", "),
  };
}

function checkSources(view: RunView): CheckResult {
  const problems: string[] = [];
  for (const citation of view.citations) {
    const document = view.documentById(citation.source_id);
    if (!document) problems.push(`${citation.id} cites ${citation.source_id}, which was never captured`);
    else if (!view.hasCapturedText(document) && !view.failureFor(document.source_id)) {
      problems.push(`${citation.id} rests on ${document.source_id}, which has no snapshot and no recorded capture failure`);
    }
  }
  return verdict("sources", "every citation has a snapshot or a recorded failure", problems, `${view.citations.length} citation(s)`);
}

function checkSpans(view: RunView): CheckResult {
  if (!view.evidenceDir) return unverifiable("spans", "resolved spans lie inside their snapshots", "no evidence directory, so spans could not be checked");
  const problems: string[] = [];
  let resolved = 0;
  for (const citation of view.citations) {
    if (citation.match === "unresolved") continue;
    resolved += 1;
    const document = view.documentById(citation.source_id);
    const text = document ? view.snapshotText(document) : undefined;
    if (text === undefined) {
      problems.push(`${citation.id} is resolved but its snapshot cannot be read`);
      continue;
    }
    const { start, end } = citation;
    if (typeof start !== "number" || typeof end !== "number" || start < 0 || end <= start || end > text.length) {
      problems.push(`${citation.id} span ${start}..${end} lies outside its ${text.length}-character snapshot`);
    } else if (citation.match === "exact" && text.slice(start, end) !== citation.quote) {
      problems.push(`${citation.id} is marked exact but its quote is not at ${start}..${end}`);
    }
  }
  return verdict("spans", "resolved spans lie inside their snapshots", problems, `${resolved} resolved span(s)`);
}

function checkSnapshots(view: RunView): CheckResult {
  if (!view.evidenceDir) return unverifiable("snapshots", "snapshots on disk match the index", "no evidence directory, so snapshots could not be checked");
  const problems: string[] = [];
  let checked = 0;
  for (const document of view.documents) {
    if (document.snapshot_path) {
      checked += 1;
      const text = view.snapshotText(document);
      if (text === undefined) problems.push(`${document.source_id}: ${document.snapshot_path} is missing`);
      else if (text.length !== document.text_length) {
        problems.push(`${document.source_id}: snapshot is ${text.length} characters, the index says ${document.text_length}`);
      }
    }
    if (document.original_path && !existsSync(join(view.evidenceDir, document.original_path))) {
      problems.push(`${document.source_id}: ${document.original_path} is missing`);
    }
    const offsets = document.page_offsets ?? [];
    if (offsets.some((o, i) => o < 0 || o > document.text_length || (i > 0 && o < offsets[i - 1]!))) {
      problems.push(`${document.source_id}: page offsets are out of order or out of range`);
    }
  }
  return verdict("snapshots", "snapshots on disk match the index", problems, `${checked} snapshot(s)`);
}

function checkCounts(view: RunView): CheckResult {
  const problems: string[] = [];
  const known = new Set(view.documents.map((d) => d.source_id));
  for (const event of view.input.events) {
    if (event?.type === "document" && event.document?.source_id && !known.has(event.document.source_id)) {
      problems.push(`a document event announced ${event.document.source_id}, which run_result does not list`);
    }
  }
  if (view.evidenceDir) {
    const disk = EvidenceStore.load(view.evidenceDir);
    const onDisk = new Set(disk.all().map((d) => d.source_id));
    if (onDisk.size !== known.size || [...known].some((id) => !onDisk.has(id))) {
      problems.push(`run_result lists ${known.size} document(s), the evidence index holds ${onDisk.size}`);
    }
    const fetchFailures = view.captureFailures.filter((f) => f?.stage === "fetch").length;
    const loggedFailures = disk.captureFailures().filter((f) => f.stage === "fetch").length;
    if (fetchFailures !== loggedFailures) {
      problems.push(`run_result lists ${fetchFailures} fetch failure(s), the failure log holds ${loggedFailures}`);
    }
  }
  if (view.result) {
    const topicCost = (view.result.topics ?? []).reduce((sum: number, t: any) => sum + (t?.usage?.cost_usd ?? 0), 0);
    if ((view.result.total_cost_usd ?? 0) + COST_EPSILON < topicCost) {
      problems.push(`total cost ${view.result.total_cost_usd} is below the ${topicCost} its topics add up to`);
    }
  }
  return verdict("counts", "counts agree across the stream and the evidence", problems, `${known.size} document(s)`);
}

function checkVerdicts(view: RunView): CheckResult {
  const name = "every claim has a verdict or is reported unjudged";
  if (!view.result) return { id: "verdicts", name, status: "pass", detail: "no run_result to check" };
  const validation = view.result.validation;
  if (!validation) {
    return view.synthesis
      ? { id: "verdicts", name, status: "fail", detail: "an answer was written but never validated" }
      : { id: "verdicts", name, status: "pass", detail: "no completed synthesis, so nothing to validate" };
  }
  const problems: string[] = [];
  for (const round of validation.rounds ?? []) {
    if (round.sweep === "skipped") {
      if (!round.note) problems.push(`round ${round.round} skipped its claim sweep without saying why`);
      continue;
    }
    if (round.verdicts.length !== round.claims_checked) {
      problems.push(`round ${round.round} counts ${round.claims_checked} checked claim(s) but holds ${round.verdicts.length} verdict(s)`);
    }
    if (round.verdicts.some((v: any) => !VERDICTS.has(v?.verdict))) problems.push(`round ${round.round} holds a verdict that is not supported/unsupported/misquoted`);
    const unjudged = round.claims_found - round.claims_checked;
    if (unjudged > 0 && !round.objections.some((o: any) => o.lens === "claim_sweep")) {
      problems.push(`round ${round.round} left ${unjudged} claim(s) unjudged without saying so`);
    }
  }
  return verdict("verdicts", name, problems, `${(validation.rounds ?? []).length} validation round(s)`);
}

function checkGrounding(view: RunView): CheckResult {
  const name = "grounding is captured, or the failures explain why not";
  if (!view.result) return { id: "grounding", name, status: "pass", detail: "no run_result to check" };
  if (!view.researched) return { id: "grounding", name, status: "pass", detail: "no research ran" };
  const snapshots = view.documents.filter((d) => view.hasCapturedText(d)).length;
  const failures = view.captureFailures.length;
  const grounded = view.result.grounding === "captured" && snapshots > 0;
  if (grounded || failures > 0) {
    return { id: "grounding", name, status: "pass", detail: `${view.result.grounding}, ${snapshots} snapshot(s), ${failures} failure(s)` };
  }
  return {
    id: "grounding", name, status: "fail",
    detail: `grounding ${view.result.grounding}, ${snapshots} snapshot(s) and no capture failure to explain it`,
  };
}

function checkRefusal(view: RunView): CheckResult {
  const refused = view.result?.refusal;
  if (refused && view.result.status === "complete") {
    return { id: "refusal", name: "a refused run is never complete", status: "fail", detail: `run was refused (${refused.kind}) yet ended complete` };
  }
  return { id: "refusal", name: "a refused run is never complete", status: "pass", detail: refused ? `refused: ${refused.kind}` : "not refused" };
}

export function summarizeRun(input: RunInput): Record<string, unknown> {
  const start = input.events.find((e) => e?.type === "run_start");
  const result = input.events.findLast((e) => e?.type === "run_result");
  const record = input.record;
  const rounds: any[] = record?.validation?.rounds ?? result?.validation?.rounds ?? [];
  const documents: any[] = record?.sources ?? result?.documents ?? [];
  return {
    build: record?.pipeline.build ?? start?.build ?? null,
    protocol: record?.pipeline.protocol ?? start?.protocol_version ?? null,
    status: record?.status ?? result?.status ?? null,
    grounding: record?.pipeline.grounding ?? result?.grounding ?? null,
    total_cost_usd: record?.cost.usd ?? result?.total_cost_usd ?? null,
    documents: documents.length,
    snapshots: documents.filter((d) => d?.snapshot_path).length,
    claims_checked: rounds.reduce((sum, r) => sum + (r?.claims_checked ?? 0), 0),
    validation: record?.validation?.status ?? result?.validation?.status ?? null,
    refusal: record?.refusal?.kind ?? result?.refusal?.kind ?? null,
    note: record?.status_note ?? result?.note ?? null,
    trust_level: record?.stats.trust_level ?? null,
    sources_cited: record?.stats.sources_cited ?? null,
    sources_read: record?.stats.sources_read ?? null,
    stripped_markers: record?.stats.stripped_markers ?? null,
  };
}

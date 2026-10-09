import { parseFencedJson } from "../agent.js";
import { classifySource } from "../sourceTypes.js";
import { markedSentences } from "../validate.js";
import type { SourceDocument } from "../evidence.js";
import {
  RECORD_SCHEMA,
  type RecordCheck,
  type RecordCitation,
  type RecordClaim,
  type RecordGraphNode,
  type RecordObjection,
  type RecordSource,
  type RecordStatus,
  type RecordTask,
  type RunRecord,
} from "./schema.js";
import { citedSourceIds, computeStats, type StatsInput } from "./stats.js";
import { normalizeWriteup } from "./writeup.js";

export interface RecordContext {
  runId: string;
  questionId: string;
  kind: RunRecord["kind"];
  createdAt: string;
  question: string;
  language: string;
  models: RunRecord["pipeline"]["models"];
  limits: RunRecord["limits"];
  transcripts: boolean;
}

type TaskKind = RecordTask["kind"];
type TaskStatus = RecordTask["status"];

interface TaskState {
  task: RecordTask;
  summary: any;
  reconciled: boolean;
}

const REPEATING_KINDS = new Set<TaskKind>(["synthesis", "verify"]);
const FINISHED = new Set<TaskStatus>(["complete", "inconclusive", "halted", "error"]);
const CONFIDENCE = new Set(["high", "medium", "low", "unverified"]);
const PLANNER_NODE = "planning";
const ROUND_ONE = 1;

export class RecordFold {
  private status: RecordStatus = "running";
  private statusNote: string | undefined;
  private refusal: RunRecord["refusal"];
  private pipeline: RunRecord["pipeline"];
  private updatedAt: string;
  private finishedAt: string | undefined;
  private round = ROUND_ONE;
  private readonly tasks: TaskState[] = [];
  private readonly latest = new Map<string, TaskState>();
  private readonly nodes = new Map<string, RecordGraphNode>();
  private readonly edges: RunRecord["graph"]["edges"] = [];
  private readonly documents = new Map<string, SourceDocument>();
  private readonly readBy = new Map<string, Set<string>>();
  private readonly citations = new Map<string, RecordCitation>();
  private readonly withTranscripts = new Set<string>();
  private captureFailures: RunRecord["capture_failures"] = [];
  private readonly timeline: RunRecord["timeline"] = [];
  private strippedMarkers: RunRecord["stripped_markers"] = [];
  private result: any;
  private checks: RecordCheck[] = [];
  private readonly reported = new Map<string, number>();

  constructor(private readonly context: RecordContext) {
    this.updatedAt = context.createdAt;
    this.pipeline = {
      engine_version: "", build: "", protocol: 0, backend: backendOf(context.models.research),
      models: context.models, grounding: "captured",
    };
  }

  apply(event: any, at: string): void {
    if (!event || typeof event !== "object") return;
    this.updatedAt = at;
    const nodeId = typeof event.angle_id === "string" ? event.angle_id : undefined;
    if (nodeId) this.withTranscripts.add(nodeId);
    if (nodeId === PLANNER_NODE && !this.latest.has(PLANNER_NODE)) this.startPlanner(at);
    switch (event.type) {
      case "run_start": return this.started(event);
      case "phase": return void this.timeline.push({ at, phase: String(event.phase) });
      case "plan": return this.planned(event.angles, at);
      case "round": return this.roundStarted(Number(event.round), event.angles);
      case "graph_node": return this.nodeAdded(event.node);
      case "graph_edge": return void this.edges.push(compact({
        from: String(event.edge?.from), to: String(event.edge?.to), kind: String(event.edge?.kind),
        label: optionalString(event.edge?.label),
      }));
      case "graph_node_update": return this.nodeUpdated(String(event.id), String(event.status), event.meta);
      case "angle_status": return this.angleStatus(String(event.angle_id), String(event.status), at);
      case "document": return this.documentSeen(event.document, nodeId);
      case "capture_failure": return void (event.failure && this.captureFailures.push(compactFailure(event.failure)));
      case "topic_result": return this.topicFinished(event, at);
      case "run_result": return this.finished(event, at);
    }
  }

  crash(at: string, note: string): void {
    this.abandon("crashed", at, note);
  }

  abandon(status: RecordStatus, at: string, note: string): void {
    if (this.result) return;
    this.status = status;
    this.statusNote = note;
    this.updatedAt = at;
    this.finishedAt ??= at;
    this.haltUnfinished();
  }

  snapshot(): RunRecord {
    const finalTasks = this.tasks.map((s) => this.finalTask(s));
    const validation = this.validation();
    const cost = this.cost(finalTasks, validation);
    const tasks = finalTasks.map((t) => (t.kind === "plan" ? { ...t, cost_usd: cost.by_role.plan } : t));
    const answerState = this.answerState();
    const answer = answerState && answerState.task.writeup
      ? { format: "markdown" as const, task_id: answerState.task.id, headline: answerState.task.headline ?? "",
          markdown: answerState.task.writeup }
      : undefined;
    const citations = [...this.citations.values()];
    const conflicts = answerState ? conflictsOf(answerState) : [];
    const gaps = answerState ? gapsOf(answerState) : [];
    const failed = tasks.filter((t) => (t.kind === "angle" || t.kind === "objection") && FINISHED.has(t.status) && t.status !== "complete");
    const draft: Omit<StatsInput, "sources"> = {
      schema: RECORD_SCHEMA,
      id: this.context.runId,
      question_id: this.context.questionId,
      kind: this.context.kind,
      created_at: this.context.createdAt,
      updated_at: this.updatedAt,
      ...(this.finishedAt ? { finished_at: this.finishedAt } : {}),
      status: this.status,
      ...(this.statusNote ? { status_note: this.statusNote } : {}),
      ...(this.refusal ? { refusal: this.refusal } : {}),
      brief: { question: this.context.question, language: this.context.language },
      pipeline: this.pipeline,
      ...(answer ? { answer } : {}),
      claims: answer ? this.claims(answer.markdown, answerState!.task, validation) : [],
      citations,
      capture_failures: this.captureFailures,
      conflicts,
      gaps,
      ...(validation ? { validation } : {}),
      open_items: {
        conflicts: conflicts.filter((c) => c.status === "open").map((c) => c.id),
        objections: (validation?.objections_open ?? []).map((o) => o.id),
        gaps: gaps.map((g) => g.id),
        failed_tasks: failed.map((t) => t.id),
      },
      tasks,
      graph: { nodes: [...this.nodes.values()], edges: this.edges },
      cost,
      limits: this.context.limits,
      timeline: this.timeline,
      stripped_markers: this.strippedMarkers,
    };
    const cited = citedSourceIds({ answer: draft.answer, tasks, citations });
    const withSources: StatsInput = { ...draft, sources: this.sources(cited) };
    return { ...withSources, stats: computeStats(withSources), checks: this.checks };
  }

  private started(event: any): void {
    this.pipeline = {
      ...this.pipeline,
      engine_version: String(event.engine_version ?? ""),
      build: String(event.build ?? ""),
      protocol: Number(event.protocol_version ?? 0),
      grounding: event.grounding === "none" ? "none" : "captured",
    };
  }

  private startPlanner(at: string): void {
    this.addTask(PLANNER_NODE, "plan", { title: "Planning", origin: "planner", status: "running", started_at: at });
  }

  private planTask(): TaskState | undefined {
    return this.latest.get(PLANNER_NODE);
  }

  private planned(angles: any[], at: string): void {
    const planner = this.planTask();
    if (planner && !FINISHED.has(planner.task.status)) {
      planner.task.status = "complete";
      planner.task.finished_at = at;
    }
    for (const angle of Array.isArray(angles) ? angles : []) this.queueAngle(angle, "angle", "planner");
  }

  private roundStarted(round: number, angles: any[]): void {
    if (Number.isFinite(round)) this.round = round;
    for (const angle of Array.isArray(angles) ? angles : []) {
      const origin = this.nodes.get(String(angle?.angle_id))?.origin ?? "objection";
      this.queueAngle(angle, origin === "objection" ? "objection" : "angle", origin);
    }
  }

  private queueAngle(angle: any, kind: TaskKind, origin: string): void {
    const id = String(angle?.angle_id ?? "");
    if (!id) return;
    const known = this.latest.get(id);
    if (known) {
      known.task.title = String(angle.title ?? known.task.title);
      if (angle.prompt) known.task.prompt = String(angle.prompt);
      return;
    }
    this.addTask(id, kind, {
      title: String(angle.title ?? id), origin, status: "queued",
      ...(angle.prompt ? { prompt: String(angle.prompt) } : {}),
    });
  }

  private nodeAdded(raw: any): void {
    if (!raw?.id) return;
    const meta = raw.meta ?? {};
    const node: RecordGraphNode = compact({
      id: String(raw.id),
      kind: String(raw.kind ?? ""),
      title: String(raw.title ?? ""),
      parent_ids: Array.isArray(raw.parent_ids) ? raw.parent_ids.map(String) : [],
      depth: Number(raw.depth ?? 0),
      round: Number(raw.round ?? ROUND_ONE),
      status: String(raw.status ?? ""),
      origin: String(raw.origin ?? ""),
      ...nodeMeta(meta),
    });
    this.nodes.set(node.id, { ...this.nodes.get(node.id), ...node });
  }

  private nodeUpdated(id: string, status: string, meta: any): void {
    const node = this.nodes.get(id);
    if (!node) return;
    this.nodes.set(id, compact({ ...node, status, ...nodeMeta(meta ?? {}) }));
  }

  private angleStatus(id: string, status: string, at: string): void {
    const node = this.nodes.get(id);
    if (node) this.nodes.set(id, { ...node, status });
    if (status !== "running") return;
    const state = this.taskFor(id, kindForNode(id, this.nodes.get(id)?.origin));
    state.task.status = "running";
    state.task.started_at ??= at;
  }

  private documentSeen(document: any, readerId: string | undefined): void {
    if (!document?.source_id) return;
    const id = String(document.source_id);
    if (!this.documents.has(id)) this.documents.set(id, document as SourceDocument);
    if (readerId) {
      const readers = this.readBy.get(id) ?? new Set<string>();
      readers.add(readerId);
      this.readBy.set(id, readers);
    }
  }

  private topicFinished(event: any, at: string): void {
    const nodeId = String(event.angle_id ?? "");
    if (!nodeId) return;
    this.reported.set(nodeId, (this.reported.get(nodeId) ?? 0) + 1);
    const state = this.taskFor(nodeId, kindForRole(String(event.role ?? ""), nodeId, this.nodes.get(nodeId)?.origin));
    const task = state.task;
    const result = String(event.result ?? "");
    const summary = parseFencedJson(result);
    state.summary = summary;
    state.reconciled = event.reconciled === true;
    task.status = topicStatus(event.status);
    task.finished_at = at;
    task.cost_usd = Number(event.usage?.cost_usd ?? 0);
    task.backend = optionalString(event.backend);
    task.model = optionalString(event.model);
    task.session_id = optionalString(event.session_id);
    task.note = optionalString(event.note);
    task.headline = typeof summary?.headline === "string" ? summary.headline : undefined;
    task.writeup = normalizeWriteup(result);
    task.findings = findingsOf(summary);
    const citations: any[] = Array.isArray(event.citations) ? event.citations : [];
    task.citation_ids = citations.map((c) => String(c.id));
    for (const citation of citations) {
      const id = String(citation.id);
      if (!this.citations.has(id)) this.citations.set(id, recordCitation(citation, task.id));
    }
  }

  private finished(event: any, at: string): void {
    this.result = event;
    this.status = runStatus(event.status);
    this.statusNote = optionalString(event.note);
    this.refusal = event.refusal ? { kind: String(event.refusal.kind), reason: String(event.refusal.reason) } : undefined;
    this.finishedAt ??= at;
    for (const document of Array.isArray(event.documents) ? event.documents : []) this.documentSeen(document, undefined);
    this.fileUnreported(Array.isArray(event.topics) ? event.topics : [], at);
    this.haltUnfinished();
    if (Array.isArray(event.capture_failures)) this.captureFailures = event.capture_failures.map(compactFailure);
    if (Array.isArray(event.stripped_markers)) {
      this.strippedMarkers = event.stripped_markers.map((m: any) => ({
        task_id: this.taskIn(String(m.angle_id), Number(m.round)) ?? String(m.angle_id), marker: String(m.marker),
      }));
    }
    if (Array.isArray(event.checks?.results)) this.checks = event.checks.results.map(recordCheck);
  }

  private fileUnreported(topics: any[], at: string): void {
    const seen = new Map<string, number>();
    for (const topic of topics) {
      const nodeId = String(topic?.angle_id ?? "");
      if (!nodeId) continue;
      const index = (seen.get(nodeId) ?? 0) + 1;
      seen.set(nodeId, index);
      if (index > (this.reported.get(nodeId) ?? 0)) this.topicFinished(topic, at);
    }
  }

  private haltUnfinished(): void {
    for (const state of this.tasks) if (state.task.status === "running") state.task.status = "halted";
  }

  private taskIn(nodeId: string, round: number): string | undefined {
    const inRound = Number.isFinite(round) ? this.tasks.find((s) => s.task.node_id === nodeId && s.task.round === round) : undefined;
    return (inRound ?? this.latest.get(nodeId))?.task.id;
  }

  private taskFor(nodeId: string, kind: TaskKind): TaskState {
    const known = this.latest.get(nodeId);
    if (known && !(REPEATING_KINDS.has(kind) && FINISHED.has(known.task.status))) return known;
    const title = this.nodes.get(nodeId)?.title ?? titleFor(nodeId, kind);
    return this.addTask(nodeId, kind, { title, origin: this.nodes.get(nodeId)?.origin ?? "derived", status: "queued" });
  }

  private addTask(nodeId: string, kind: TaskKind,
                  fields: Pick<RecordTask, "title" | "origin" | "status"> & Partial<RecordTask>): TaskState {
    const repeat = this.tasks.filter((s) => s.task.node_id === nodeId).length;
    const task: RecordTask = {
      id: repeat === 0 ? nodeId : `${nodeId}.r${this.round}`,
      node_id: nodeId,
      kind,
      round: this.round,
      cost_usd: 0,
      findings: [],
      citation_ids: [],
      source_ids: [],
      ...fields,
    };
    const state: TaskState = { task, summary: undefined, reconciled: false };
    this.tasks.push(state);
    this.latest.set(nodeId, state);
    return state;
  }

  private finalTask(state: TaskState): RecordTask {
    const { task } = state;
    const readers = [...this.readBy.entries()].filter(([, by]) => by.has(task.node_id)).map(([id]) => id);
    const fromCitations = task.citation_ids.map((id) => this.citations.get(id)?.source_id).filter((id): id is string => Boolean(id));
    return compact({
      ...task,
      source_ids: [...new Set([...readers, ...fromCitations])].sort(),
      ...(this.context.transcripts && this.withTranscripts.has(task.node_id)
        ? { transcript: `transcripts/${task.node_id}.ndjson` } : {}),
    });
  }

  private answerState(): TaskState | undefined {
    const complete = this.tasks.filter((s) => (s.task.kind === "synthesis" || s.task.kind === "reconciliation")
      && s.task.status === "complete");
    return complete.filter((s) => s.reconciled).at(-1) ?? complete.filter((s) => s.task.kind === "synthesis").at(-1);
  }

  private validation(): RunRecord["validation"] {
    const raw = this.result?.validation;
    if (!raw) return undefined;
    return {
      status: raw.status === "validated" ? "validated" : "unvalidated",
      holds: Boolean(raw.holds),
      blocking: Number(raw.blocking ?? 0),
      spend_usd: Number(raw.spend_usd ?? 0),
      objections_admitted: Number(raw.objections_admitted ?? 0),
      objections_resolved: Number(raw.objections_resolved ?? 0),
      objections_open: (raw.objections_outstanding ?? []).map((o: any, i: number) => ({ id: `o${i + 1}`, ...objection(o) })),
      unsupported_citations: (raw.unsupported_citations ?? []).map(String),
      rounds: (raw.rounds ?? []).map((r: any) => compact({
        round: Number(r.round),
        sweep: r.sweep === "run" ? "run" as const : "skipped" as const,
        critics: r.critics === "run" ? "run" as const : "skipped" as const,
        claims_found: Number(r.claims_found ?? 0),
        claims_checked: Number(r.claims_checked ?? 0),
        verdicts: (r.verdicts ?? []).map((v: any) => compact({
          claim_id: String(v.claim_id), claim: String(v.claim), verdict: v.verdict,
          severity: v.severity, reason: optionalString(v.reason),
          citation_ids: Array.isArray(v.citation_ids) ? v.citation_ids.map(String) : undefined,
        })),
        objections: (r.objections ?? []).map(objection),
        discarded_objections: Number(r.discarded_objections ?? 0),
        holds: Boolean(r.holds),
        note: optionalString(r.note),
      })),
    };
  }

  private claims(markdown: string, answerTask: RecordTask, validation: RunRecord["validation"]): RecordClaim[] {
    const round = validation?.rounds.find((r) => r.round === answerTask.round) ?? validation?.rounds.at(-1);
    return markedSentences(markdown).map(({ claim, ids }, index) => {
      const located = ids.map((id) => this.citations.get(id)).filter((c): c is RecordCitation => Boolean(c) && c!.match !== "unresolved");
      const judged = round?.sweep === "run" ? round.verdicts.find((v) => v.claim === claim) : undefined;
      const verdict = judged
        ? compact({ verdict: judged.verdict, severity: judged.severity, reason: judged.reason })
        : { verdict: "unjudged" as const };
      const solid = verdict.verdict === "supported" && this.independentlySourced(located);
      return {
        id: `k${index + 1}`,
        text: claim,
        citation_ids: ids,
        confidence: verdict.verdict === "unjudged" ? "unverified"
          : verdict.verdict !== "supported" ? "low" : solid ? "high" : "medium",
        strength: solid ? "solid" : "shaky",
        verdict,
        task_id: answerTask.id,
        round: answerTask.round,
      };
    });
  }

  private independentlySourced(located: RecordCitation[]): boolean {
    const sources = new Set(located.map((c) => c.source_id));
    if (sources.size >= 2) return true;
    return [...sources].some((id) => this.sourceType(id) === "primary");
  }

  private sourceType(id: string): RecordSource["source_type"] {
    const document = this.documents.get(id);
    if (!document) return "vendor";
    return document.source_type ?? classifySource(document.url, document.title);
  }

  private sources(cited: Set<string>): RecordSource[] {
    return [...this.documents.values()].map((d) => ({
      id: d.source_id,
      url: d.url,
      host: hostOf(d.url),
      title: d.title ?? "",
      content_type: d.content_type === "pdf" || d.content_type === "text" ? d.content_type : "html",
      source_type: this.sourceType(d.source_id),
      capture: d.capture === "degraded" || d.capture === "failed" ? d.capture : "ok",
      fetched_at: d.fetched_at ?? null,
      snapshot_path: d.snapshot_path ?? null,
      original_path: d.original_path ?? null,
      text_length: Number(d.text_length ?? 0),
      byte_size: Number(d.byte_size ?? 0),
      page_offsets: Array.isArray(d.page_offsets) ? d.page_offsets.map(Number) : [],
      read_by: [...(this.readBy.get(d.source_id) ?? [])].sort(),
      cited: cited.has(d.source_id),
    }));
  }

  private cost(tasks: RecordTask[], validation: RunRecord["validation"]): RunRecord["cost"] {
    const sum = (kinds: TaskKind[]) => tasks.filter((t) => kinds.includes(t.kind)).reduce((s, t) => s + t.cost_usd, 0);
    const research = round6(sum(["angle", "objection"]));
    const synthesis = round6(sum(["synthesis", "reconciliation"]));
    const verify = round6(sum(["verify"]));
    const validate = validation?.spend_usd ?? 0;
    const usd = this.result ? Number(this.result.total_cost_usd ?? 0) : research + synthesis + verify;
    const plan = Math.max(0, round6(usd - research - synthesis - verify - validate));
    return { usd, by_role: { plan, research, synthesis, verify, validate } };
  }
}

function conflictsOf(state: TaskState): RunRecord["conflicts"] {
  const raw: any[] = Array.isArray(state.summary?.conflicts) ? state.summary.conflicts : [];
  return raw.flatMap((c) => {
    const statement = String(c?.claim ?? "").trim();
    const positions = (Array.isArray(c?.positions) ? c.positions : []).map((p: unknown) => String(p).trim()).filter(Boolean);
    return statement && positions.length > 0 ? [{ statement, positions }] : [];
  }).map((c, i) => ({ id: `cf${i + 1}`, ...c, status: "open" as const, task_id: state.task.id }));
}

function gapsOf(state: TaskState): RunRecord["gaps"] {
  const raw: any[] = Array.isArray(state.summary?.gaps) ? state.summary.gaps : [];
  return raw.map((g) => String(g).trim()).filter(Boolean)
    .map((text, i) => ({ id: `g${i + 1}`, text, task_id: state.task.id }));
}

function findingsOf(summary: any): RecordTask["findings"] {
  const raw: any[] = Array.isArray(summary?.findings) ? summary.findings : [];
  return raw.filter((f) => typeof f?.claim === "string" && f.claim.trim()).map((f) => ({
    claim: f.claim,
    confidence: CONFIDENCE.has(f.confidence) ? f.confidence : "unverified",
    citation_ids: (Array.isArray(f.citations) ? f.citations : []).map(String).filter(Boolean),
    sources: (Array.isArray(f.sources) ? f.sources : []).map(String),
  }));
}

function recordCitation(raw: any, taskId: string): RecordCitation {
  return compact({
    id: String(raw.id),
    source_id: String(raw.source_id ?? ""),
    quote: String(raw.quote ?? ""),
    match: ["exact", "normalized", "fuzzy"].includes(raw.match) ? raw.match : "unresolved",
    start: typeof raw.start === "number" ? raw.start : undefined,
    end: typeof raw.end === "number" ? raw.end : undefined,
    page: typeof raw.page === "number" ? raw.page : undefined,
    task_id: taskId,
  });
}

function recordCheck(raw: any): RecordCheck {
  return {
    id: String(raw.id), name: String(raw.name),
    status: raw.status === "fail" || raw.status === "warn" ? raw.status : "pass",
    detail: String(raw.detail ?? ""),
  };
}

function objection(raw: any): RecordObjection {
  return {
    lens: String(raw?.lens ?? ""),
    statement: String(raw?.statement ?? ""),
    severity: raw?.severity === "minor" ? "minor" : "blocking",
    followup: String(raw?.followup ?? ""),
  };
}

function nodeMeta(meta: any): Partial<RecordGraphNode> {
  return compact({
    cost_usd: typeof meta.cost_usd === "number" ? meta.cost_usd : undefined,
    lens: optionalString(meta.lens),
    objections: Array.isArray(meta.objections) ? meta.objections.map(objection) : undefined,
    why: optionalString(meta.why),
    provoked_by: optionalString(meta.provoked_by),
    statement: optionalString(meta.statement),
    severity: optionalString(meta.severity),
    est_cost_usd: typeof meta.est_cost_usd === "number" ? meta.est_cost_usd : undefined,
    rejected_reason: optionalString(meta.rejected_reason),
  });
}

function compactFailure(raw: any): RunRecord["capture_failures"][number] {
  return compact({
    source_id: String(raw?.source_id ?? ""), url: String(raw?.url ?? ""), stage: String(raw?.stage ?? ""),
    error: String(raw?.error ?? ""), kind: optionalString(raw?.kind),
  });
}

function kindForNode(nodeId: string, origin: string | undefined): TaskKind {
  if (nodeId === "synthesis") return "synthesis";
  if (nodeId === "reconciliation") return "reconciliation";
  if (nodeId === "verify") return "verify";
  if (nodeId === PLANNER_NODE) return "plan";
  return origin === "objection" ? "objection" : "angle";
}

function kindForRole(role: string, nodeId: string, origin: string | undefined): TaskKind {
  if (role === "synthesis") return nodeId === "reconciliation" ? "reconciliation" : "synthesis";
  if (role === "verify") return "verify";
  if (role === "plan") return "plan";
  return origin === "objection" ? "objection" : "angle";
}

function titleFor(nodeId: string, kind: TaskKind): string {
  if (kind === "synthesis") return "Synthesis";
  if (kind === "reconciliation") return "Reconciliation";
  if (kind === "verify") return "Citation check";
  return nodeId;
}

function topicStatus(raw: unknown): TaskStatus {
  return raw === "inconclusive" || raw === "halted" || raw === "error" ? raw : "complete";
}

function runStatus(raw: unknown): RecordStatus {
  return raw === "inconclusive" || raw === "halted" ? raw : raw === "complete" ? "complete" : "failed";
}

function backendOf(spec: string): string {
  if (spec.startsWith("claude-code")) return "claude-code";
  if (spec.startsWith("codex")) return "codex";
  return "engine";
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return url;
  }
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value ? value : undefined;
}

function round6(value: number): number {
  return Math.round(value * 1e6) / 1e6;
}

function compact<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(Object.entries(value).filter(([, v]) => v !== undefined)) as T;
}

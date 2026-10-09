import { randomUUID } from "node:crypto";
import { ENGINE_BUILD, ENGINE_VERSION, Emitter, PROTOCOL_VERSION, type Sink, type UsageBlock } from "./emitter.js";
import {
  answerLanguage,
  buildSystemPrompt,
  SYNTHESIS_SYSTEM_PROMPT,
  VERIFY_SYSTEM_PROMPT,
  templateInstructions,
  synthesisWordBudget,
  planPrompt,
  planSystemPrompt,
} from "./systemPrompt.js";
import { parsePlannedAngles } from "./planner.js";
import { angleEmitter, runTopic, type RunBackendDeps, type RunTopicConfig, type TopicOutcome } from "./backend.js";
import { parseClaudeCodeSpec } from "./claudeCode.js";
import { parseCodexSpec } from "./codex.js";
import { parseFencedJson } from "./agent.js";
import {
  citationRequests,
  EvidenceStore,
  normalizeSource,
  textSimilarity,
  type Citation,
  type SourceDocument,
} from "./evidence.js";
import { groundingTier, makeSearchClient, type GroundingTier } from "./config.js";
import {
  appendValidation,
  conflictObjections,
  loopObjections,
  orphanedMarkerObjection,
  skippedRound,
  summarizeValidation,
  taskVerdicts,
  unreadableSummaryObjection,
  validateSynthesis,
  type Objection,
  type ValidationRound,
} from "./validate.js";
import {
  divergedAcrossRounds,
  reconciliationContext,
  standsAgainstAnswer,
  type ReconciliationRound,
} from "./reconcile.js";
import { AdmissionGate, type AdmittedInquiry } from "./admission.js";
import type { Refusal } from "./refusal.js";
import { checkRun } from "./check.js";
import { RunLog } from "./runLog.js";
import { RunLiveness } from "./liveness.js";
import { join } from "node:path";
import type { Env } from "./providers.js";
import { settleMarkers } from "./markers.js";
import { briefFromQuestion } from "./record/brief.js";
import type { Brief } from "./record/schema.js";
import { openRecording, type Recording } from "./record/store.js";

export interface PreApprovedAngle {
  /// The id the approved plan already gave this angle. The app drew those cards and the reader edited them
  /// there, so the engine names the angle by the same id — a run has one graph, not a planned one and a
  /// researched one. Absent (an angle from somewhere with no plan) → numbered here.
  id?: string;
  title: string;
  prompt: string;
}

export interface RunConfig {
  question: string;
  angleCount?: number;
  angles?: PreApprovedAngle[];
  angleModel?: string;
  synthesisModel?: string;
  validatorModel?: string;
  effort?: string;
  perTopicBudgetUSD?: number;
  runBudgetUSD?: number;
  perTopicTimeoutSec?: number;
  maxTurns?: number;
  priorNotesExcerpt?: string;
  template?: string;
  rounds?: number;
  angleConcurrency?: number;
  useProjectContext?: boolean;
  projectDir?: string;
  evidenceDir?: string;
  runDir?: string;
  brainDir?: string;
  runDeadlineSec?: number;
  questionId?: string;
  runId?: string;
  brief?: Brief;
}

type WaveEnd = "done" | "budget" | "aborted" | "refused";

export interface RunOutcome {
  status: "complete" | "inconclusive" | "halted";
  refusal?: Refusal;
}

export interface PlannedAngle {
  angle_id: string;
  title: string;
  prompt: string;
}

export type CitationOrphanStage = "verify";

export interface CitationOrphan {
  stage: CitationOrphanStage;
  claim: string;
  citation_ids: string[];
}

export interface StrippedMarker {
  angle_id: string;
  marker: string;
  round: number;
}

export interface PlanInput {
  question: string;
  angleCount: number;
  priorNotesExcerpt?: string;
  template?: string;
  nextAngleId: () => string;
}

export interface RunDeps {
  sink: Sink;
  runTopic?: (cfg: RunTopicConfig) => Promise<TopicOutcome>;
  planAngles?: (input: PlanInput) => Promise<PlannedAngle[]> | PlannedAngle[];
  abortController?: AbortController;
  now?: () => number;
  sessionId?: string;
  backendDeps?: RunBackendDeps;
  newId?: () => string;
  pid?: number;
}

const PLANNER_ID = "planning";
const PLANNER_BUDGET_USD = 0.15;
const DEFAULT_MODEL = "deepseek/deepseek-chat";
const DEFAULT_ANGLE_COUNT = 3;
const DEFAULT_PER_TOPIC_BUDGET = 0.25;
const DEFAULT_RUN_BUDGET = 1.0;
const DEFAULT_PER_TOPIC_TIMEOUT_SEC = 300;
const DEFAULT_ROUND_CAP = 4;
const DEFAULT_ANGLE_CONCURRENCY = 4;
const VERIFY_BUDGET_USD = 0.05;
const VALIDATION_RESERVE_FRACTION = 0.15;
const RUN_SEARCH_CONCURRENCY = 8;
const CITATION_OFFER_LIMIT = 24;
const CITATION_QUOTE_CAP = 300;

export async function runRun(requested: RunConfig, env: Env, deps: RunDeps): Promise<RunOutcome> {
  const now = deps.now ?? Date.now;
  const brief = requested.brief ?? briefFromQuestion(requested.question);
  const config: RunConfig = { ...requested, question: brief.question, brief };
  const recording = openRecording({
    brief,
    ...(config.brainDir ? { brainDir: config.brainDir } : {}),
    ...(config.runDir ? { runDir: config.runDir } : {}),
    ...(config.questionId && config.runId ? { ids: { questionId: config.questionId, runId: config.runId } } : {}),
    models: {
      planner: config.angleModel ?? DEFAULT_MODEL, research: config.angleModel ?? DEFAULT_MODEL,
      synthesis: config.synthesisModel ?? DEFAULT_MODEL,
      validator: config.validatorModel ?? config.synthesisModel ?? DEFAULT_MODEL,
    },
    limits: {
      cap_usd: config.runBudgetUSD ?? DEFAULT_RUN_BUDGET,
      ...(config.runDeadlineSec ? { deadline_s: config.runDeadlineSec } : {}),
    },
    now,
    ...(deps.newId ? { newId: deps.newId } : {}),
  });
  const heartbeat: { stop: () => void } = { stop: () => {} };
  try {
    return await orchestrate(config, env, deps, recording, now, heartbeat);
  } catch (error) {
    heartbeat.stop();
    recording.recorder.crash(error instanceof Error ? error.message : String(error));
    throw error;
  }
}

async function orchestrate(config: RunConfig, env: Env, deps: RunDeps, recording: Recording,
                           now: () => number, heartbeat: { stop: () => void }): Promise<RunOutcome> {
  const at = () => new Date(now()).toISOString();
  const { layout, runDir, question, recorder, startFields } = recording;
  const log = new RunLog(runDir);
  const sink = log.tee(recorder.tee(deps.sink));
  const bus = new Emitter(sink);
  const controller = deps.abortController ?? new AbortController();
  const signal = controller.signal;
  const sessionId = deps.sessionId ?? `qrun-${randomUUID()}`;
  const runTopicFn = deps.runTopic ?? runTopic;
  const sharedSearch =
    deps.backendDeps?.search ??
    (deps.backendDeps?.makeSearchClient
      ? deps.backendDeps.makeSearchClient(env)
      : makeSearchClient(env, RUN_SEARCH_CONCURRENCY));
  const backendDeps: RunBackendDeps = { ...deps.backendDeps, search: sharedSearch, now };

  const angleModel = config.angleModel ?? DEFAULT_MODEL;
  const synthesisModel = config.synthesisModel ?? DEFAULT_MODEL;
  const validatorModel = config.validatorModel ?? synthesisModel;
  const effort = config.effort ?? "medium";
  const perTopicBudgetUsd = config.perTopicBudgetUSD ?? DEFAULT_PER_TOPIC_BUDGET;
  const runBudgetUsd = config.runBudgetUSD ?? DEFAULT_RUN_BUDGET;
  const perTopicTimeoutMs = (config.perTopicTimeoutSec ?? DEFAULT_PER_TOPIC_TIMEOUT_SEC) * 1000;
  const maxTurns = config.maxTurns;
  const angleCount = config.angleCount ?? DEFAULT_ANGLE_COUNT;
  const roundCap = Math.max(1, config.rounds ?? DEFAULT_ROUND_CAP);
  const angleConcurrency = Math.max(1, config.angleConcurrency ?? DEFAULT_ANGLE_CONCURRENCY);
  const template = config.template;
  const researchSystemPrompt = buildSystemPrompt(answerLanguage(config.question, config.brief?.language));

  let angleSeq = 0;
  const nextAngleId = () => `a${++angleSeq}`;

  const evidenceDir = config.evidenceDir ?? env.QUORUM_EVIDENCE_DIR ?? (runDir ? join(runDir, "evidence") : undefined);
  const runEvidence = new EvidenceStore({ now });
  const citationIndex = new Map<string, Citation>();
  const citationOrphans: CitationOrphan[] = [];
  const strippedMarkers: StrippedMarker[] = [];

  const topics: TopicOutcome[] = [];
  const validators: TopicOutcome[] = [];
  const planners: TopicOutcome[] = [];
  const validationRounds: ValidationRound[] = [];
  const dive: ReconciliationRound[] = [];
  const admittedObjections: Objection[] = [];
  const filedObjections: Objection[] = [];
  const validationCost = () => validators.reduce((sum, t) => sum + (t.usage?.cost_usd ?? 0), 0);
  const planningCost = () => planners.reduce((sum, t) => sum + (t.usage?.cost_usd ?? 0), 0);
  const cost = () => topics.reduce((sum, t) => sum + (t.usage?.cost_usd ?? 0), 0) + validationCost() + planningCost();
  const budgetExceeded = () => cost() >= runBudgetUsd;

  const startedAt = now();
  const deadlineMs = (config.runDeadlineSec ?? 0) * 1000;
  const elapsedFraction = () => (deadlineMs > 0 ? (now() - startedAt) / deadlineMs : 0);
  const pastDeadline = () => deadlineMs > 0 && now() - startedAt >= deadlineMs;
  const validationReserveUsd = runBudgetUsd * VALIDATION_RESERVE_FRACTION;
  const gate = new AdmissionGate({
    perTopicBudgetUsd,
    runBudgetUsd,
    synthesisReserveUsd: perTopicBudgetUsd,
    validationReserveUsd,
    spentUsd: cost,
    elapsedFraction,
  });
  const inquiryDepth = new Map<string, number>();
  const fedSynthesis = new Set<string>();
  const drawnVerdicts = new Set<string>();

  let runStatus: "complete" | "inconclusive" | "halted" = "complete";
  let refusal: Refusal | undefined;
  let windDownNote: string | null = null;
  let currentRound = 1;
  let rejectionSeq = 0;

  const grounding = groundingTier(env, parseClaudeCodeSpec(angleModel) !== null);
  const liveness = new RunLiveness({ bus, ...(deps.pid === undefined ? {} : { pid: deps.pid }), sourcesRead: () => runEvidence.all().length });
  bus.line({
    type: "run_start", session_id: sessionId, protocol_version: PROTOCOL_VERSION,
    engine_version: ENGINE_VERSION, build: ENGINE_BUILD, grounding,
    ...(deps.pid === undefined ? {} : { pid: deps.pid }),
    ...startFields,
  });
  liveness.start();
  heartbeat.stop = () => liveness.stop();

  function angleEvidence(): EvidenceStore {
    return new EvidenceStore({ ...(evidenceDir ? { dir: evidenceDir } : {}), now });
  }

  async function execTopic(
    angle: PlannedAngle,
    role: TopicOutcome["role"],
    spec: string,
    topicBudgetUsd: number,
    systemPrompt: string,
    emitter: Emitter,
    overrides: { effort?: string; maxTurns?: number; evidence?: EvidenceStore } = {},
  ): Promise<TopicOutcome> {
    try {
      const outcome = await runTopicFn({
        angleId: angle.angle_id,
        role,
        spec,
        prompt: angle.prompt,
        systemPrompt,
        effort: overrides.effort ?? effort,
        perTopicBudgetUsd: topicBudgetUsd,
        timeoutMs: perTopicTimeoutMs,
        maxTurns: overrides.maxTurns ?? maxTurns,
        env,
        emitter,
        signal,
        useProjectContext: config.useProjectContext,
        projectDir: config.projectDir,
        ...(overrides.evidence ? { evidence: overrides.evidence } : {}),
        ...(evidenceDir && role !== "validate" ? { evidenceDir } : {}),
        deps: backendDeps,
      });
      if (outcome.refusal) refusal ??= outcome.refusal;
      return outcome;
    } catch (e) {
      return errorOutcome(angle.angle_id, role, spec, e);
    }
  }

  /// What a topic actually captured. A Claude Code or Codex angle fetches through the `mcp-serve`
  /// subprocess, which is a separate process and can only hand its captures over on disk.
  function capturedEvidence(outcome: TopicOutcome, store: EvidenceStore): EvidenceStore {
    return outcome.backend !== "engine" && evidenceDir ? EvidenceStore.load(evidenceDir) : store;
  }

  function absorbCaptures(outcome: TopicOutcome, captured: EvidenceStore): void {
    const failuresBefore = runEvidence.captureFailures().length;
    const merged = runEvidence.merge(captured);
    if (outcome.backend === "engine") return;
    announceCaptures(merged, outcome.angle_id);
    const emitter = angleEmitter(sink, outcome.angle_id);
    for (const failure of runEvidence.captureFailures().slice(failuresBefore)) emitter.captureFailure(failure);
  }

  /// A CLI angle's fetches happened in the `mcp-serve` subprocess, so nothing has announced them live yet.
  function announceCaptures(documents: SourceDocument[], angleId: string): void {
    const emitter = angleEmitter(sink, angleId);
    for (const document of documents) emitter.document(document);
  }

  function indexCitations(citations: Citation[]): void {
    for (const citation of citations) if (!citationIndex.has(citation.id)) citationIndex.set(citation.id, citation);
  }

  /// Verify one angle's quotes against the snapshots it captured, then give its citation ids a run-unique
  /// `<angle_id>c<n>` prefix — in the ids, in the writeup's markers, and in the findings that lean on them —
  /// so two angles can never collide on `c1`.
  function groundAngle(outcome: TopicOutcome, store: EvidenceStore): void {
    const captured = capturedEvidence(outcome, store);
    absorbCaptures(outcome, captured);
    const summary = parseFencedJson(outcome.result);
    const citations = resolveCitations(summary, captured, outcome.angle_id, citationIndex);
    indexCitations(citations);
    outcome.citations = citations;
    if (!summary) {
      filedObjections.push(unreadableSummaryObjection(outcome.angle_id));
      settleUngrounded(outcome, outcome.angle_id);
      return;
    }
    const grounded = composeGrounded(outcome.result, summary, {
      citations,
      prefix: outcome.angle_id,
      floorUnverified: captured.hasSnapshots(),
      grounding,
    });
    outcome.result = grounded.result;
    outcome.citations = grounded.citations;
    noteStripped(outcome.angle_id, grounded.stripped);
  }

  function noteStripped(angleId: string, markers: string[]): void {
    for (const marker of markers) strippedMarkers.push({ angle_id: angleId, marker, round: currentRound });
  }

  function settleUngrounded(outcome: TopicOutcome, prefix: string, known?: Map<string, Citation>): void {
    const writeup = writeupPart(outcome.result);
    const settled = settleMarkers(prefixMarkers(writeup.trimEnd(), prefix), [], outcome.citations ?? [], known);
    const rest = outcome.result.slice(writeup.length).trim();
    outcome.result = rest ? `${settled.writeup}\n\n${rest}` : settled.writeup;
    outcome.citations = settled.citations;
    noteStripped(outcome.angle_id, settled.stripped);
  }

  function emitTopic(outcome: TopicOutcome): void {
    bus.line({ type: "topic_result", ...outcome });
    if (outcome.role === "research") liveness.taskFinished();
    bus.line({ type: "angle_status", angle_id: outcome.angle_id, status: angleStatus(outcome.status) });
    bus.graphNodeUpdate(outcome.angle_id, angleStatus(outcome.status),
                        { cost_usd: outcome.usage?.cost_usd ?? 0 });
  }

  function emitInquiryNode(angle: PlannedAngle, depth: number, round: number,
                           origin: "planner" | "followup" | "objection"): void {
    liveness.taskQueued();
    bus.graphNode({
      id: angle.angle_id, kind: "inquiry", title: angle.title, parent_ids: [],
      depth, round, status: "queued", origin,
    });
  }

  function announceSynthesis(id: string, title: string, feeding: TopicOutcome[], round: number): void {
    bus.graphNode({
      id, kind: "synthesis", title, parent_ids: [], depth: synthesisDepth(), round,
      status: "running", origin: "derived",
    });
    for (const topic of feeding) {
      if (fedSynthesis.has(topic.angle_id)) continue;
      fedSynthesis.add(topic.angle_id);
      bus.graphEdge({ from: topic.angle_id, to: id, kind: "synthesizes" });
    }
  }

  function announceVerdicts(judged: ValidationRound, target: string): void {
    for (const task of taskVerdicts(judged)) {
      const id = `v${judged.round}_${task.lens}`;
      drawnVerdicts.add(id);
      bus.graphNode({
        id, kind: "verdict", title: task.title, parent_ids: [], depth: synthesisDepth() + 1,
        round: judged.round, status: task.status, origin: "derived",
        meta: { lens: task.lens, objections: task.objections },
      });
      bus.graphEdge({ from: id, to: target, kind: "judges", label: task.status });
    }
  }

  function verdictThatFiled(lens: string): string {
    const id = `v${currentRound}_${lens}`;
    return drawnVerdicts.has(id) ? id : "root";
  }

  function synthesisDepth(): number {
    return Math.max(1, ...inquiryDepth.values()) + 1;
  }

  /// A refusal is drawn, not swallowed: the user sees what the run wanted and why it was turned down,
  /// rather than the run quietly deciding for them.
  function emitRejectedQuestion(parentID: string, question: string, reason: string): void {
    const id = `r${++rejectionSeq}`;
    bus.graphNode({
      id, kind: "question", title: question, parent_ids: [parentID], depth: 0,
      round: currentRound, status: "rejected", origin: "objection", meta: { rejected_reason: reason },
    });
    bus.graphEdge({ from: parentID, to: id, kind: "spawned" });
  }

  async function runOneAngle(
    angle: PlannedAngle,
    role: "research" | "synthesis",
    spec: string,
    topicBudgetUsd: number,
    systemPrompt: string,
  ): Promise<TopicOutcome> {
    bus.line({ type: "angle_status", angle_id: angle.angle_id, status: "running" });
    const store = angleEvidence();
    const outcome = await execTopic(angle, role, spec, topicBudgetUsd, systemPrompt,
      angleEmitter(sink, angle.angle_id), { evidence: store });
    groundAngle(outcome, store);
    emitTopic(outcome);
    return outcome;
  }

  async function researchWave(planned: PlannedAngle[]): Promise<WaveEnd> {
    const queue: PlannedAngle[] = [...planned];
    const inFlight = new Set<Promise<void>>();
    let end: WaveEnd = "done";

    while (true) {
      if (end === "done" && refusal) end = "refused";
      while (end === "done" && queue.length > 0 && inFlight.size < angleConcurrency) {
        const angle = queue.shift()!;
        const share = Math.max(0, runBudgetUsd - cost()) / (queue.length + inFlight.size + 2);
        const budgetUsd = Math.min(perTopicBudgetUsd, share);
        if (budgetUsd <= 0) {
          queue.length = 0;
          end = "budget";
          break;
        }
        const ceiling = Math.min(budgetUsd, gate.ceilingFor(inquiryDepth.get(angle.angle_id) ?? 1));
        const task: Promise<void> = runOneAngle(angle, "research", angleModel, ceiling, researchSystemPrompt)
          .then((outcome) => { topics.push(outcome); })
          .finally(() => { inFlight.delete(task); });
        inFlight.add(task);
      }
      if (inFlight.size === 0) break;
      await Promise.race(inFlight);
      if (signal.aborted) {
        queue.length = 0;
        end = "aborted";
      } else if (refusal) {
        queue.length = 0;
        end = "refused";
      }
    }
    return signal.aborted ? "aborted" : end;
  }

  /// Grounding for the synthesis: quotes are checked deterministically against the stored snapshots (no
  /// model asked), while URLs the angles never cited still get their ONE gated low-effort verify call.
  async function groundSynthesis(synthesis: TopicOutcome, research: TopicOutcome[],
                                 store: EvidenceStore): Promise<TopicOutcome | undefined> {
    absorbCaptures(synthesis, capturedEvidence(synthesis, store));
    const summary = parseFencedJson(synthesis.result);
    const citations = resolveCitations(summary, runEvidence, "", citationIndex);
    indexCitations(citations);
    synthesis.citations = citations;
    if (!summary) {
      filedObjections.push(unreadableSummaryObjection(synthesis.angle_id));
      settleUngrounded(synthesis, "", citationIndex);
      return undefined;
    }

    const trusted = trustedSources(research);
    let untraceable = citedSources(summary).filter((u) => !trusted.has(u));
    let verifyOutcome: TopicOutcome | undefined;
    if (untraceable.length > 0) {
      const cap = Math.min(VERIFY_BUDGET_USD, Math.max(0, runBudgetUsd - cost()));
      if (cap > 0) {
        const verifyAngle: PlannedAngle = {
          angle_id: "verify",
          title: "Citation check",
          prompt: verifyContext(summary, trusted),
        };
        verifyOutcome = await execTopic(verifyAngle, "verify", synthesisModel, cap, VERIFY_SYSTEM_PROMPT,
          angleEmitter(sink, verifyAngle.angle_id), { effort: "low", maxTurns: 1 });
        const corrected = parseFencedJson(verifyOutcome.result);
        if (Array.isArray(corrected?.findings) && corrected.findings.length > 0) {
          const kept = keepCitationLinks(corrected.findings, summary.findings, "verify");
          summary.findings = kept.findings;
          citationOrphans.push(...kept.orphans);
          for (const orphan of kept.orphans) {
            filedObjections.push(orphanedMarkerObjection(orphan.claim, orphan.citation_ids));
          }
        }
      }
      untraceable = citedSources(summary).filter((u) => !trusted.has(u)).sort();
    }

    const grounded = composeGrounded(synthesis.result, summary, {
      citations,
      prefix: "",
      floorUnverified: runEvidence.hasSnapshots(),
      grounding,
      untraceable,
      evidence: runEvidence,
      known: citationIndex,
    });
    synthesis.result = grounded.result;
    synthesis.citations = grounded.citations;
    indexCitations(grounded.citations);
    noteStripped(synthesis.angle_id, grounded.stripped);
    if (untraceable.length > 0 && !synthesis.note) {
      synthesis.note = `${untraceable.length} untraceable citation(s) — see Citation check.`;
    }
    return verifyOutcome;
  }

  function citationsForSweep(declared: Citation[]): Citation[] {
    const declaredIds = new Set(declared.map((c) => c.id));
    return [...declared, ...[...citationIndex.values()].filter((c) => !declaredIds.has(c.id))];
  }

  async function validateRound(synthesis: TopicOutcome, research: TopicOutcome[],
                               round: number): Promise<ValidationRound> {
    if (synthesis.status !== "complete") {
      return skippedRound(round, 0, "The synthesis did not complete, so there was no answer to judge.",
                          [...filedObjections]);
    }
    return validateSynthesis({
      question: config.question,
      round,
      synthesisResult: synthesis.result,
      citations: citationsForSweep(synthesis.citations ?? []),
      research: research.map((t) => ({ angle_id: t.angle_id, result: t.result })),
      documents: runEvidence.all(),
      grounding,
      budgetUsd: Math.max(0, runBudgetUsd - cost()),
      filed: [...filedObjections],
      judge: async (call) => {
        const angle: PlannedAngle = { angle_id: call.id, title: call.id, prompt: call.prompt };
        const outcome = await execTopic(angle, "validate", validatorModel, call.budgetUsd, call.systemPrompt,
          angleEmitter(sink, call.id), { effort: "low", maxTurns: 1 });
        validators.push(outcome);
        return outcome.result;
      },
    });
  }

  async function reconcileDive(): Promise<void> {
    const remainingUsd = runBudgetUsd - cost();
    if (dive.length < 2 || signal.aborted || remainingUsd < perTopicBudgetUsd) return;
    if (!divergedAcrossRounds(dive.map((round) => round.synthesis))) return;

    liveness.phase("reconciling");
    const angle: PlannedAngle = {
      angle_id: "reconciliation",
      title: "Reconciliation",
      prompt: reconciliationContext(config.question, dive),
    };
    bus.line({ type: "angle_status", angle_id: angle.angle_id, status: "running" });
    announceSynthesis(angle.angle_id, angle.title, [], currentRound);
    bus.graphEdge({ from: "synthesis", to: angle.angle_id, kind: "synthesizes" });
    const store = angleEvidence();
    const fused = await execTopic(angle, "synthesis", synthesisModel,
      Math.min(perTopicBudgetUsd, remainingUsd), SYNTHESIS_SYSTEM_PROMPT,
      angleEmitter(sink, angle.angle_id), { evidence: store });
    topics.push(fused);
    if (fused.status !== "complete" || !writeupPart(fused.result).trim()) return;

    fused.reconciled = true;
    const verifyOutcome = await groundSynthesis(fused, topics.filter((t) => t.role === "research"), store);
    if (verifyOutcome) topics.push(verifyOutcome);
    const judged = validationRounds.at(-1);
    if (judged && standsAgainstAnswer(judged)) fused.result = appendValidation(fused.result, judged);
    emitTopic(fused);
  }

  function admitObjections(objections: Objection[]): PlannedAngle[] {
    const angles: PlannedAngle[] = [];
    for (const objection of objections) {
      const verdict = gate.admit({
        question: objection.followup,
        why: objection.statement,
        provoked_by: objection.lens,
        parent_id: "root",
      });
      if (verdict.verdict === "rejected") {
        emitRejectedQuestion("root", objection.followup, verdict.reason);
        continue;
      }
      announceObjection(verdict.inquiry, objection);
      admittedObjections.push(objection);
      angles.push(objectionAngle(verdict.inquiry, objection));
    }
    return angles;
  }

  function announceObjection(inquiry: AdmittedInquiry, objection: Objection): void {
    const filedBy = verdictThatFiled(objection.lens);
    bus.graphNode({
      id: inquiry.question_id, kind: "question", title: shorten(objection.followup),
      parent_ids: [filedBy], depth: inquiry.depth, round: currentRound,
      status: "approved", origin: "objection",
      meta: { lens: objection.lens, statement: objection.statement, severity: objection.severity,
              est_cost_usd: inquiry.est_cost_usd },
    });
    bus.graphEdge({ from: filedBy, to: inquiry.question_id, kind: "spawned", label: objection.lens });
  }

  function objectionAngle(inquiry: AdmittedInquiry, objection: Objection): PlannedAngle {
    inquiryDepth.set(inquiry.inquiry_id, inquiry.depth);
    const angle: PlannedAngle = {
      angle_id: inquiry.inquiry_id,
      title: shorten(objection.followup),
      prompt: foldPriorNotes(
        `${config.question}\n\nA validator read the answer drafted so far and objected: `
        + `${objection.statement}\n\nResearch ONLY the task that would settle that objection: `
        + `${objection.followup}`,
        config.priorNotesExcerpt),
    };
    emitInquiryNode(angle, inquiry.depth, currentRound + 1, "objection");
    bus.graphEdge({ from: inquiry.question_id, to: inquiry.inquiry_id, kind: "decomposes" });
    return angle;
  }

  let planningFailure: string | undefined;

  async function planWithModel(input: PlanInput): Promise<PlannedAngle[]> {
    const planner: PlannedAngle = {
      angle_id: PLANNER_ID,
      title: "Planning",
      prompt: planPrompt(input.question, input.angleCount, input.priorNotesExcerpt),
    };
    const outcome = await execTopic(planner, "plan", angleModel, Math.min(perTopicBudgetUsd, PLANNER_BUDGET_USD),
      planSystemPrompt(input.angleCount), angleEmitter(sink, PLANNER_ID), { effort: "low", maxTurns: 1 });
    planners.push(outcome);
    const angles = parsePlannedAngles(outcome.result, input.angleCount, input.nextAngleId)
      .map((angle) => ({ ...angle, prompt: foldPriorNotes(angle.prompt, input.priorNotesExcerpt) }));
    if (angles.length === 0) {
      planningFailure = `Planning failed: ${outcome.note ?? "the planner returned no usable angles"}.`;
      bus.line({ type: "error", error: planningFailure });
    }
    return angles;
  }

  liveness.phase("planning");
  const preApproved = (config.angles ?? []).filter((a) => a && a.prompt);
  let currentAngles: PlannedAngle[] =
    preApproved.length > 0
      ? preApproved.map((a) => ({
          angle_id: a.id?.trim() || nextAngleId(),
          title: a.title ?? "Angle",
          prompt: foldPriorNotes(a.prompt, config.priorNotesExcerpt),
        }))
      : await (deps.planAngles ?? planWithModel)({
          question: config.question, angleCount, priorNotesExcerpt: config.priorNotesExcerpt, template, nextAngleId,
        });
  bus.line({ type: "plan", angles: currentAngles.map((a) => ({ angle_id: a.angle_id, title: a.title, prompt: a.prompt })) });
  bus.graphNode({ id: "root", kind: "question", title: config.question, parent_ids: [],
                  depth: 0, round: 1, status: "approved", origin: "root" });
  gate.seed("root", config.question, 0);
  for (const angle of currentAngles) {
    gate.seed(angle.angle_id, angle.title, 1);
    inquiryDepth.set(angle.angle_id, 1);
    emitInquiryNode(angle, 1, 1, "planner");
    bus.graphEdge({ from: "root", to: angle.angle_id, kind: "decomposes" });
  }

  let lastSynthesis: TopicOutcome | undefined;

  if (signal.aborted) {
    runStatus = "halted";
    windDownNote = "Run halted during planning.";
  } else if (planningFailure) {
    runStatus = "inconclusive";
    windDownNote = refusal ? refusal.reason : planningFailure;
  }

  for (let round = 1; runStatus === "complete" && round <= roundCap; round++) {
    currentRound = round;
    filedObjections.length = 0;

    liveness.phase("researching");
    if (budgetExceeded()) {
      runStatus = "inconclusive";
      windDownNote = `Run budget of $${runBudgetUsd} reached before round ${round}; stopped launching angles.`;
      break;
    }

    const waveEnd = await researchWave(currentAngles);
    if (waveEnd === "budget") {
      runStatus = "inconclusive";
      windDownNote = `Run budget of $${runBudgetUsd} left no budget for round ${round}; stopped launching angles.`;
      break;
    }
    if (waveEnd === "refused") {
      runStatus = "inconclusive";
      windDownNote = refusal!.reason;
      break;
    }
    if (waveEnd === "aborted") {
      runStatus = "halted";
      windDownNote = "Run halted during research; skipped synthesis.";
      break;
    }

    liveness.phase("synthesizing");
    if (budgetExceeded()) {
      runStatus = "inconclusive";
      windDownNote = `Run budget of $${runBudgetUsd} reached after research; skipped synthesis.`;
      break;
    }
    const researchTopics = topics.filter((t) => t.role === "research");
    const synthAngle: PlannedAngle = {
      angle_id: "synthesis",
      title: "Synthesis",
      prompt: buildSynthesisContext(config.question, researchTopics, template, config.priorNotesExcerpt),
    };
    const synthesisBudgetUsd = Math.min(perTopicBudgetUsd, Math.max(0, runBudgetUsd - cost()));
    if (synthesisBudgetUsd <= 0) {
      runStatus = "inconclusive";
      windDownNote = `Run budget of $${runBudgetUsd} reached after research; skipped synthesis.`;
      break;
    }
    bus.line({ type: "angle_status", angle_id: "synthesis", status: "running" });
    announceSynthesis("synthesis", "Synthesis", researchTopics, round);
    const synthesisEvidence = angleEvidence();
    lastSynthesis = await execTopic(synthAngle, "synthesis", synthesisModel, synthesisBudgetUsd,
      SYNTHESIS_SYSTEM_PROMPT, angleEmitter(sink, "synthesis"), { evidence: synthesisEvidence });
    topics.push(lastSynthesis);
    if (cost() > runBudgetUsd) {
      settleUngrounded(lastSynthesis, "", citationIndex);
      emitTopic(lastSynthesis);
      runStatus = "inconclusive";
      windDownNote = `Run budget of $${runBudgetUsd} was exceeded by the synthesis backend.`;
      break;
    }

    liveness.phase("grounding");
    const verifyOutcome = await groundSynthesis(lastSynthesis, researchTopics, synthesisEvidence);
    if (verifyOutcome) topics.push(verifyOutcome);

    liveness.phase("validating");
    const judged = await validateRound(lastSynthesis, researchTopics, round);
    validationRounds.push(judged);
    announceVerdicts(judged, "synthesis");
    lastSynthesis.result = appendValidation(lastSynthesis.result, judged);
    emitTopic(lastSynthesis);
    dive.push({ synthesis: lastSynthesis.result, validation: judged });

    if (signal.aborted) {
      runStatus = "halted";
      break;
    }

    // Two things buy another round: an objection that says the answer is wrong, and a conflict the answer
    // itself could not settle. Only the first says anything about whether the answer holds.
    const standing = [...loopObjections(judged), ...conflictObjections(parseFencedJson(lastSynthesis.result))];
    if (standing.length === 0) break;
    const outstanding = `${standing.length} blocking objection(s) still stand against the answer`;
    if (round === roundCap) {
      windDownNote = `The round cap of ${roundCap} was reached with ${outstanding}.`;
      break;
    }
    if (budgetExceeded()) {
      windDownNote = `Run budget of $${runBudgetUsd} left nothing for another round; ${outstanding}.`;
      break;
    }
    if (pastDeadline()) {
      windDownNote = `The run deadline passed before another round could start; ${outstanding}.`;
      break;
    }
    const objectionAngles = admitObjections(standing);
    if (objectionAngles.length === 0) {
      windDownNote = `No further research could be admitted for the objections filed; ${outstanding}.`;
      break;
    }
    currentAngles = objectionAngles;
    bus.line({
      type: "round", round: round + 1,
      angles: currentAngles.map((a) => ({ angle_id: a.angle_id, title: a.title, prompt: a.prompt })),
    });
  }

  await reconcileDive();

  const validation = validationRounds.length > 0
    ? summarizeValidation(validationRounds, validationCost(), admittedObjections)
    : undefined;
  const failedAngles = topics.filter((t) => t.role === "research" && t.status !== "complete");

  if (runStatus === "complete" && lastSynthesis && lastSynthesis.status !== "complete") {
    runStatus = "inconclusive";
  }
  if (runStatus === "complete" && !lastSynthesis) {
    runStatus = "inconclusive";
    windDownNote = windDownNote ?? "No synthesis was produced.";
  }
  if (runStatus === "complete" && failedAngles.length > 0) {
    runStatus = "inconclusive";
    windDownNote = windDownNote
      ?? `${failedAngles.length} angle(s) failed, so the answer rests on less research than was planned.`;
  }
  if (runStatus === "complete" && validation && !validation.holds) runStatus = "inconclusive";
  if (runStatus === "complete" && refusal) {
    runStatus = "inconclusive";
    windDownNote = windDownNote ?? refusal.reason;
  }

  liveness.phase("done");
  liveness.stop();
  const runResult = {
    type: "run_result",
    status: runStatus,
    grounding,
    total_cost_usd: cost(),
    ...(windDownNote ? { note: windDownNote } : {}),
    ...(refusal ? { refusal } : {}),
    topics,
    documents: runEvidence.all(),
    capture_failures: runEvidence.captureFailures(),
    citation_orphans: citationOrphans,
    stripped_markers: strippedMarkers,
    ...(validation ? { validation } : {}),
  };
  const snapshot = JSON.parse(JSON.stringify(runResult));
  recorder.fold.apply(snapshot, at());
  const checks = checkRun({
    events: [...JSON.parse(JSON.stringify(log.events())), snapshot],
    evidenceDir,
    malformedLines: 0,
    record: recorder.fold.snapshot(),
    ...(layout && !layout.questionDir ? {} : { question }),
  });
  bus.line({ ...runResult, checks });
  recorder.finish();
  return { status: runStatus, ...(refusal ? { refusal } : {}) };
}

function angleStatus(status: TopicOutcome["status"]): "complete" | "halted" | "error" {
  if (status === "halted") return "halted";
  if (status === "error") return "error";
  return "complete";
}

export function buildSynthesisContext(question: string, researchTopics: TopicOutcome[],
                                      template?: string, priorNotes?: string): string {
  let s = `You are given ${researchTopics.length} INDEPENDENT research writeups, each investigating a `;
  s += "different angle of the same question. They did not see each other. Reconcile them into ONE ";
  s += "answer: state where they agree, flag conflicts and gaps, and synthesize — do not just ";
  s += "concatenate them.\n\n";
  s += `Keep the full writeup under ~${synthesisWordBudget(researchTopics.length)} `;
  s += "words — a tight, skimmable answer beats restating every angle.\n\n";
  const shape = templateInstructions(template);
  if (shape) s += shape + "\n\n";
  s += `Original question: ${question}\n\n`;
  const table = corroboration(researchTopics).filter((e) => e.count > 1);
  if (table.length > 0) {
    s += "Sources multiple angles independently cited (more angles = better corroborated):\n";
    for (const { url, count } of table) s += `- ${url} — ${count} of ${researchTopics.length} angles\n`;
    s += "\n";
  }
  researchTopics.forEach((t, i) => {
    const summary = parseFencedJson(t.result);
    s += `===== ANGLE ${i + 1}: ${summary?.headline ?? `Angle ${i + 1}`} (${t.status}) =====\n`;
    const findings: any[] = Array.isArray(summary?.findings) ? summary.findings : [];
    if (findings.length === 0) {
      s += "Findings: none reported.\n";
    } else {
      s += "Findings (claim · confidence · sources):\n";
      for (const f of findings) {
        const sources = Array.isArray(f?.sources) ? f.sources : [];
        s += `- ${f?.claim ?? ""} · ${f?.confidence ?? "unverified"} · ${sources.join(", ")}\n`;
      }
    }
    s += citationOffer(t.citations ?? []);
    s += "\n";
  });
  researchTopics.forEach((t, i) => {
    const body = writeupPart(t.result).trim();
    if (!body) return;
    s += `----- Writeup from angle ${i + 1}, in full -----\n${body}\n\n`;
  });
  return foldPriorNotes(s, priorNotes);
}

/// The angle's already-verified quotes, offered to the synthesis under their run-unique ids. Reusing an id
/// carries its verification over; renumbering would throw it away and force a re-check that can fail.
function citationOffer(citations: Citation[]): string {
  const verified = citations.filter((c) => c.match !== "unresolved").slice(0, CITATION_OFFER_LIMIT);
  if (verified.length === 0) return "";
  let s = "Verified quotes from this angle — cite one by writing its marker and reuse the id EXACTLY:\n";
  for (const c of verified) {
    s += `- [^${c.id}] source ${c.source_id}: "${trimQuote(c.quote)}"\n`;
  }
  return s;
}

function trimQuote(quote: string): string {
  const single = quote.replace(/\s+/g, " ").trim();
  return single.length > CITATION_QUOTE_CAP ? single.slice(0, CITATION_QUOTE_CAP) + "…" : single;
}

function corroboration(researchTopics: TopicOutcome[]): Array<{ url: string; count: number }> {
  const counts = new Map<string, number>();
  for (const t of researchTopics) {
    const summary = parseFencedJson(t.result);
    const urls = new Set(citedSources(summary ?? {}));
    for (const u of urls) counts.set(u, (counts.get(u) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([url, count]) => ({ url, count }))
    .sort((a, b) => (a.count !== b.count ? b.count - a.count : a.url < b.url ? -1 : 1));
}

function trustedSources(researchTopics: TopicOutcome[]): Set<string> {
  const trusted = new Set<string>();
  for (const t of researchTopics) {
    const summary = parseFencedJson(t.result);
    for (const u of citedSources(summary ?? {})) trusted.add(u);
    for (const u of writeupPart(t.result).match(/https?:\/\/[^\s)\]">]+/g) ?? []) {
      const normalized = normalizeSource(u.replace(/[.,;:!?]+$/, ""));
      if (normalized) trusted.add(normalized);
    }
  }
  return trusted;
}

function citedSources(summary: any): string[] {
  const findings: any[] = Array.isArray(summary?.findings) ? summary.findings : [];
  const urls = findings
    .flatMap((f) => (Array.isArray(f?.sources) ? f.sources : []))
    .map((u) => normalizeSource(String(u)))
    .filter(Boolean);
  return [...new Set(urls)];
}

/// One topic's claimed quotes, checked against the snapshots and renamed into run-unique ids. An id the run
/// already verified (the synthesis reusing an angle's `a2c1`) is carried over as-is rather than re-checked.
function resolveCitations(summary: any, evidence: EvidenceStore, prefix: string,
                         known: Map<string, Citation>): Citation[] {
  return citationRequests(summary).map((request) => {
    const id = prefix + request.id;
    const settled = known.get(id);
    return settled ? { ...settled, id } : { ...evidence.resolveCitation(request), id };
  });
}

interface GroundedOptions {
  citations: Citation[];
  prefix: string;
  floorUnverified: boolean;
  grounding: GroundingTier;
  untraceable?: string[];
  evidence?: EvidenceStore;
  known?: Map<string, Citation>;
}

interface Grounded {
  result: string;
  citations: Citation[];
  stripped: string[];
}

const UNVALIDATED_NOTICE =
  "> ⚠️ **Unvalidated — no evidence was captured for this run.** Its sources were read through built-in "
  + "web search, which keeps no snapshot, so no quote below has been checked against one.";

const UNVALIDATED_BADGE = "⚠️ unvalidated — no evidence was captured";

/// The writeup as the reader will get it: markers renamed to their run-unique ids, the fenced summary
/// carrying resolved citations, unsupported claims marked rather than dropped, and — when an evidence
/// registry is given — a portable `## Sources` list plus footnote definitions.
function composeGrounded(result: string, summary: any, options: GroundedOptions): Grounded {
  const { prefix } = options;
  const findings: any[] | undefined = Array.isArray(summary.findings)
    ? summary.findings.map((f: any) => prefixFinding(f, prefix))
    : undefined;
  const settled = settleMarkers(prefixMarkers(writeupPart(result).trimEnd(), prefix), findings ?? [],
    options.citations, options.known);
  const citations = settled.citations;
  let writeup = settled.writeup;

  if (citations.length > 0) summary.citations = citations;
  else if (summary.citations !== undefined) delete summary.citations;
  if (findings) {
    summary.findings = settled.findings.map((f: any) => floorFinding(f, citations, options.floorUnverified));
  }

  const untraceable = options.untraceable ?? [];
  if (untraceable.length > 0) {
    writeup += "\n\n## Citation check\n\n";
    writeup += `⚠️ ${untraceable.length} citation(s) in this synthesis could not be traced to any angle's `;
    writeup += "sources — treat them as unverified:\n\n";
    for (const u of untraceable) writeup += `- ${u}\n`;
    writeup = writeup.trimEnd();
  }
  if (options.evidence) {
    if (options.grounding === "none") writeup += `\n\n${UNVALIDATED_NOTICE}`;
    const sources = sourcesSection(citations, options.evidence, options.grounding);
    if (sources) writeup += `\n\n${sources}`;
  }
  return {
    result: `${writeup}\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\``,
    citations,
    stripped: settled.stripped,
  };
}

function prefixFinding(finding: any, prefix: string): any {
  const ids: string[] = (Array.isArray(finding?.citations) ? finding.citations : [])
    .map((id: unknown) => prefix + String(id));
  return ids.length > 0 ? { ...finding, citations: ids } : { ...finding };
}

function floorFinding(finding: any, citations: Citation[], floorUnverified: boolean): any {
  const ids: string[] = Array.isArray(finding?.citations) ? finding.citations : [];
  const supported = ids.some((id) => citations.some((c) => c.id === id && c.match !== "unresolved"));
  return floorUnverified && !supported ? { ...finding, confidence: "unverified" } : finding;
}

function prefixMarkers(writeup: string, prefix: string): string {
  return prefix ? writeup.replace(/\[\^([A-Za-z0-9_-]{1,32})\]/g, `[^${prefix}$1]`) : writeup;
}

/// A cited-sources list with a verification badge per document, then the markdown footnote definitions for
/// every marker — so the note still reads as a cited document in Obsidian or on GitHub, with no Quorum.
function sourcesSection(citations: Citation[], evidence: EvidenceStore, grounding: GroundingTier): string {
  if (citations.length === 0) return "";
  const order: string[] = [];
  const bySource = new Map<string, Citation[]>();
  for (const citation of citations) {
    const group = bySource.get(citation.source_id);
    if (group) group.push(citation);
    else {
      bySource.set(citation.source_id, [citation]);
      order.push(citation.source_id);
    }
  }
  let section = "## Sources\n\n";
  order.forEach((sourceId, index) => {
    const document = evidence.get(sourceId);
    section += `${index + 1}. ${sourceLink(document, sourceId)} — ${badge(bySource.get(sourceId)!, grounding)}\n`;
  });
  section += "\n";
  section += citations.map((c) => `[^${c.id}]: ${footnoteDefinition(c, evidence.get(c.source_id))}`).join("\n");
  return section;
}

function badge(citations: Citation[], grounding: GroundingTier): string {
  if (grounding === "none") return UNVALIDATED_BADGE;
  if (citations.some((c) => c.match === "exact" || c.match === "normalized")) return "✓ verified";
  if (citations.some((c) => c.match === "fuzzy")) return "≈ close match";
  return "⚠️ not verifiable";
}

function footnoteDefinition(citation: Citation, document: SourceDocument | undefined): string {
  const parts: string[] = [];
  if (document) parts.push(sourceLink(document, citation.source_id));
  if (citation.page !== undefined) parts.push(`p. ${citation.page}`);
  if (citation.quote) parts.push(`“${citation.quote.replace(/\s+/g, " ")}”`);
  if (citation.match === "unresolved") parts.push("(quote not verifiable against a stored snapshot)");
  return parts.length > 0 ? parts.join(" — ") : citation.id;
}

function sourceLink(document: SourceDocument | undefined, sourceId: string): string {
  if (!document) return sourceId;
  const title = displayTitle(document).replace(/]/g, "");
  return document.url ? `[${title}](${document.url})` : title;
}

function displayTitle(document: SourceDocument): string {
  const title = document.title.trim();
  if (title) return title;
  const host = /^[a-z]+:\/\/([^/?#]+)/i.exec(document.url)?.[1] ?? document.url;
  return host.startsWith("www.") ? host.slice(4) : host;
}

interface ClaimLink {
  claim: string;
  ids: string[];
}

interface KeptCitationLinks {
  findings: any[];
  orphans: CitationOrphan[];
}

const CLAIM_DICE_THRESHOLD = 0.6;
const CLAIM_ORDER_THRESHOLD = 0.5;

function keepCitationLinks(corrected: any[], original: unknown, stage: CitationOrphanStage): KeptCitationLinks {
  const links = claimLinks(original);
  const findings = corrected.map((finding) => {
    if (finding?.citations !== undefined) return finding;
    const claim = String(finding?.claim ?? "");
    const link = links.find((l) => l.claim === claim) ?? closestClaim(links, claim);
    return link ? { ...finding, citations: link.ids } : finding;
  });
  const carried = new Set(
    findings.flatMap((f) => (Array.isArray(f?.citations) ? f.citations.map((id: unknown) => String(id)) : [])),
  );
  const orphans: CitationOrphan[] = [];
  for (const link of links) {
    const lost = link.ids.filter((id) => !carried.has(id));
    if (lost.length > 0) orphans.push({ stage, claim: link.claim, citation_ids: lost });
  }
  return { findings, orphans };
}

function claimLinks(original: unknown): ClaimLink[] {
  if (!Array.isArray(original)) return [];
  const links: ClaimLink[] = [];
  for (const finding of original) {
    const ids = (Array.isArray(finding?.citations) ? finding.citations : [])
      .map((id: unknown) => String(id))
      .filter(Boolean);
    if (finding?.claim && ids.length > 0) links.push({ claim: String(finding.claim), ids });
  }
  return links;
}

function closestClaim(links: ClaimLink[], claim: string): ClaimLink | undefined {
  let best: { link: ClaimLink; score: number } | undefined;
  for (const link of links) {
    const { dice, order } = textSimilarity(link.claim, claim);
    if (dice < CLAIM_DICE_THRESHOLD || order < CLAIM_ORDER_THRESHOLD) continue;
    if (!best || dice + order > best.score) best = { link, score: dice + order };
  }
  return best?.link;
}

function writeupPart(result: string): string {
  const open = result.lastIndexOf("```json");
  return open === -1 ? result : result.slice(0, open);
}

function verifyContext(summary: any, trusted: Set<string>): string {
  let s = "Sources the underlying research actually cited (a citation not in this list is unsupported):\n";
  for (const u of [...trusted].sort()) if (u) s += `- ${u}\n`;
  s += "\nSynthesis findings to check:\n";
  const findings: any[] = Array.isArray(summary?.findings) ? summary.findings : [];
  for (const f of findings) {
    const sources = Array.isArray(f?.sources) ? f.sources : [];
    const ids = Array.isArray(f?.citations) ? f.citations : [];
    s += `- claim: ${f?.claim ?? ""}\n  confidence: ${f?.confidence ?? "unverified"}\n  sources: ${sources.join(", ")}\n`;
    if (ids.length > 0) s += `  citations: ${ids.join(", ")}\n`;
  }
  return s;
}

function backendOf(spec: string): TopicOutcome["backend"] {
  if (parseClaudeCodeSpec(spec)) return "cli";
  if (parseCodexSpec(spec)) return "codex";
  return "engine";
}

function providerOf(spec: string): string {
  return backendOf(spec) === "engine" ? spec.split("/")[0]! : backendOf(spec) === "cli" ? "claude-code" : "codex";
}

function errorOutcome(angleId: string, role: TopicOutcome["role"], spec: string, e: unknown): TopicOutcome {
  const note = e instanceof Error ? e.message : String(e);
  const summary = { headline: "Angle failed", status: "inconclusive", sourcesConsulted: 0, findings: [], note };
  return {
    angle_id: angleId,
    role,
    backend: backendOf(spec),
    provider: providerOf(spec),
    model: spec,
    session_id: `qeng-${randomUUID()}`,
    status: "error",
    result: "The angle failed to run.\n\n```json\n" + JSON.stringify(summary) + "\n```",
    usage: zeroUsage(spec),
    note,
  };
}

function zeroUsage(spec: string): UsageBlock {
  return {
    provider: providerOf(spec),
    model: spec,
    input_tokens: 0,
    output_tokens: 0,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    cost_usd: 0,
    search_calls: 0,
    fetch_calls: 0,
  };
}

function foldPriorNotes(prompt: string, priorNotes?: string): string {
  const notes = priorNotes?.trim();
  if (!notes) return prompt;
  return `Prior notes from earlier research (build on these; do not repeat what is already settled):\n${notes}\n\n${prompt}`;
}

function shorten(text: string): string {
  const clean = text.trim().replace(/\s+/g, " ");
  return clean.length > 60 ? clean.slice(0, 57) + "..." : clean;
}

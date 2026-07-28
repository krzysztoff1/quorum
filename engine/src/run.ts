import { randomUUID } from "node:crypto";
import { Emitter, PROTOCOL_VERSION, type Sink, type UsageBlock } from "./emitter.js";
import {
  buildSystemPrompt,
  SYNTHESIS_SYSTEM_PROMPT,
  VERIFY_SYSTEM_PROMPT,
  templateInstructions,
  synthesisWordBudget,
} from "./systemPrompt.js";
import { angleEmitter, runTopic, type RunBackendDeps, type RunTopicConfig, type TopicOutcome } from "./backend.js";
import { parseFencedJson } from "./agent.js";
import {
  citationRequests,
  EvidenceStore,
  normalizeSource,
  type Citation,
  type SourceDocument,
} from "./evidence.js";
import { makeSearchClient } from "./config.js";
import type { Env } from "./providers.js";

export interface PreApprovedAngle {
  title: string;
  prompt: string;
}

export interface RunConfig {
  question: string;
  angleCount?: number;
  angles?: PreApprovedAngle[];
  angleModel?: string;
  synthesisModel?: string;
  effort?: string;
  perTopicBudgetUSD?: number;
  runBudgetUSD?: number;
  perTopicTimeoutSec?: number;
  maxTurns?: number;
  priorNotesExcerpt?: string;
  template?: string;
  rounds?: number;
  autoresearch?: boolean;
  useProjectContext?: boolean;
  projectDir?: string;
  evidenceDir?: string;
}

export interface PlannedAngle {
  angle_id: string;
  title: string;
  prompt: string;
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
}

const DEFAULT_MODEL = "deepseek/deepseek-chat";
const DEFAULT_ANGLE_COUNT = 3;
const DEFAULT_PER_TOPIC_BUDGET = 0.25;
const DEFAULT_RUN_BUDGET = 1.0;
const DEFAULT_PER_TOPIC_TIMEOUT_SEC = 300;
const VERIFY_BUDGET_USD = 0.05;
const EXCERPT_CHAR_CAP = 1500;
const RUN_SEARCH_CONCURRENCY = 8;
const CITATION_OFFER_LIMIT = 24;
const CITATION_QUOTE_CAP = 300;

const FACETS = [
  "the core facts and current state of the art",
  "the strongest primary-source evidence and hard data",
  "counterarguments, risks, and failure modes",
  "the most recent developments and their credibility",
  "practical implications and what to do next",
  "who the key players are and their incentives",
];

export function defaultPlanAngles(input: PlanInput): PlannedAngle[] {
  const count = Math.max(1, input.angleCount);
  const angles: PlannedAngle[] = [];
  for (let i = 0; i < count; i++) {
    const facet = FACETS[i % FACETS.length]!;
    angles.push({
      angle_id: input.nextAngleId(),
      title: capitalize(facet),
      prompt: foldPriorNotes(`${input.question}\n\nResearch specifically: ${facet}.`, input.priorNotesExcerpt),
    });
  }
  return angles;
}

export async function runRun(config: RunConfig, env: Env, deps: RunDeps): Promise<void> {
  const bus = new Emitter(deps.sink);
  const now = deps.now ?? Date.now;
  const controller = deps.abortController ?? new AbortController();
  const signal = controller.signal;
  const sessionId = deps.sessionId ?? `qrun-${randomUUID()}`;
  const runTopicFn = deps.runTopic ?? runTopic;
  const planFn = deps.planAngles ?? defaultPlanAngles;
  const sharedSearch =
    deps.backendDeps?.search ??
    (deps.backendDeps?.makeSearchClient
      ? deps.backendDeps.makeSearchClient(env)
      : makeSearchClient(env, RUN_SEARCH_CONCURRENCY));
  const backendDeps: RunBackendDeps = { ...deps.backendDeps, search: sharedSearch, now };

  const angleModel = config.angleModel ?? DEFAULT_MODEL;
  const synthesisModel = config.synthesisModel ?? DEFAULT_MODEL;
  const effort = config.effort ?? "medium";
  const perTopicBudgetUsd = config.perTopicBudgetUSD ?? DEFAULT_PER_TOPIC_BUDGET;
  const runBudgetUsd = config.runBudgetUSD ?? DEFAULT_RUN_BUDGET;
  const perTopicTimeoutMs = (config.perTopicTimeoutSec ?? DEFAULT_PER_TOPIC_TIMEOUT_SEC) * 1000;
  const maxTurns = config.maxTurns ?? (config.autoresearch === false ? 4 : undefined);
  const angleCount = config.angleCount ?? DEFAULT_ANGLE_COUNT;
  const rounds = Math.max(1, config.rounds ?? 1);
  const template = config.template;
  const researchSystemPrompt = buildSystemPrompt();

  let angleSeq = 0;
  const nextAngleId = () => `a${++angleSeq}`;

  const evidenceDir = config.evidenceDir ?? env.QUORUM_EVIDENCE_DIR;
  const runEvidence = new EvidenceStore({ now });
  const citationIndex = new Map<string, Citation>();

  const topics: TopicOutcome[] = [];
  const cost = () => topics.reduce((sum, t) => sum + (t.usage?.cost_usd ?? 0), 0);
  const budgetExceeded = () => cost() >= runBudgetUsd;

  let runStatus: "complete" | "inconclusive" | "halted" = "complete";
  let windDownNote: string | null = null;

  bus.line({ type: "run_start", session_id: sessionId, protocol_version: PROTOCOL_VERSION });

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
      return await runTopicFn({
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
        ...(evidenceDir ? { evidenceDir } : {}),
        deps: backendDeps,
      });
    } catch (e) {
      return errorOutcome(angle.angle_id, role, spec, e);
    }
  }

  /// What a topic actually captured. A Claude Code angle fetches through the `mcp-serve` subprocess, which
  /// is a separate process and can only hand its captures over on disk.
  function capturedEvidence(outcome: TopicOutcome, store: EvidenceStore): EvidenceStore {
    return outcome.backend === "cli" && evidenceDir ? EvidenceStore.load(evidenceDir) : store;
  }

  function absorbCaptures(outcome: TopicOutcome, captured: EvidenceStore): void {
    const merged = runEvidence.merge(captured);
    if (outcome.backend === "cli") announceCaptures(merged, outcome.angle_id);
  }

  /// A CLI angle's fetches happened in the `mcp-serve` subprocess, so nothing has announced them live yet.
  function announceCaptures(documents: SourceDocument[], angleId: string): void {
    const emitter = angleEmitter(deps.sink, angleId);
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
    if (!summary) return;
    outcome.result = composeGrounded(outcome.result, summary, {
      citations,
      prefix: outcome.angle_id,
      floorUnverified: captured.hasSnapshots(),
    });
  }

  function emitTopic(outcome: TopicOutcome): void {
    bus.line({ type: "topic_result", ...outcome });
    bus.line({ type: "angle_status", angle_id: outcome.angle_id, status: angleStatus(outcome.status) });
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
      angleEmitter(deps.sink, angle.angle_id), { evidence: store });
    groundAngle(outcome, store);
    emitTopic(outcome);
    return outcome;
  }

  async function researchBatch(angles: PlannedAngle[], budgetPerAngleUsd: number): Promise<TopicOutcome[]> {
    return Promise.all(angles.map((a) => runOneAngle(a, "research", angleModel, budgetPerAngleUsd, researchSystemPrompt)));
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
    if (!summary) return undefined;

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
          new Emitter(() => {}), { effort: "low", maxTurns: 1 });
        const corrected = parseFencedJson(verifyOutcome.result);
        if (Array.isArray(corrected?.findings) && corrected.findings.length > 0) {
          summary.findings = keepCitationLinks(corrected.findings, summary.findings);
        }
      }
      untraceable = citedSources(summary).filter((u) => !trusted.has(u)).sort();
    }

    synthesis.result = composeGrounded(synthesis.result, summary, {
      citations,
      prefix: "",
      floorUnverified: runEvidence.hasSnapshots(),
      untraceable,
      evidence: runEvidence,
    });
    if (untraceable.length > 0 && !synthesis.note) {
      synthesis.note = `${untraceable.length} untraceable citation(s) — see Citation check.`;
    }
    return verifyOutcome;
  }

  bus.line({ type: "phase", phase: "planning" });
  const preApproved = (config.angles ?? []).filter((a) => a && a.prompt);
  let currentAngles: PlannedAngle[] =
    preApproved.length > 0
      ? preApproved.map((a) => ({
          angle_id: nextAngleId(),
          title: a.title ?? "Angle",
          prompt: foldPriorNotes(a.prompt, config.priorNotesExcerpt),
        }))
      : await planFn({ question: config.question, angleCount, priorNotesExcerpt: config.priorNotesExcerpt, template, nextAngleId });
  bus.line({ type: "plan", angles: currentAngles.map((a) => ({ angle_id: a.angle_id, title: a.title, prompt: a.prompt })) });

  let lastSynthesis: TopicOutcome | undefined;

  for (let round = 1; round <= rounds; round++) {
    if (round > 1) {
      if (signal.aborted) {
        runStatus = "halted";
        break;
      }
      bus.line({ type: "phase", phase: "reconciling" });
      currentAngles = planFollowups(lastSynthesis, config, nextAngleId);
      if (currentAngles.length === 0) break;
      bus.line({ type: "round", round, angles: currentAngles.map((a) => ({ angle_id: a.angle_id, title: a.title })) });
    }

    bus.line({ type: "phase", phase: "researching" });
    if (budgetExceeded()) {
      runStatus = "inconclusive";
      windDownNote = `Run budget of $${runBudgetUsd} reached before round ${round}; stopped launching angles.`;
      break;
    }
    // Reserve one equal slice for synthesis. Parallel agents can each spend their full assigned slice,
    // so the sum of all in-flight ceilings must fit inside the one remaining run budget.
    const remainingBeforeResearch = Math.max(0, runBudgetUsd - cost());
    const perAngleBudgetUsd = Math.min(perTopicBudgetUsd, remainingBeforeResearch / (currentAngles.length + 1));
    if (perAngleBudgetUsd <= 0) {
      runStatus = "inconclusive";
      windDownNote = `Run budget of $${runBudgetUsd} left no budget for round ${round}; stopped launching angles.`;
      break;
    }
    const batch = await researchBatch(currentAngles, perAngleBudgetUsd);
    topics.push(...batch);
    if (signal.aborted) {
      runStatus = "halted";
      windDownNote = "Run halted during research; skipped synthesis.";
      break;
    }

    bus.line({ type: "phase", phase: "synthesizing" });
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
    const synthesisEvidence = angleEvidence();
    lastSynthesis = await execTopic(synthAngle, "synthesis", synthesisModel, synthesisBudgetUsd,
      SYNTHESIS_SYSTEM_PROMPT, angleEmitter(deps.sink, "synthesis"), { evidence: synthesisEvidence });
    topics.push(lastSynthesis);
    if (cost() > runBudgetUsd) {
      emitTopic(lastSynthesis);
      runStatus = "inconclusive";
      windDownNote = `Run budget of $${runBudgetUsd} was exceeded by the synthesis backend.`;
      break;
    }

    bus.line({ type: "phase", phase: "grounding" });
    const verifyOutcome = await groundSynthesis(lastSynthesis, researchTopics, synthesisEvidence);
    if (verifyOutcome) topics.push(verifyOutcome);
    emitTopic(lastSynthesis);

    if (signal.aborted) {
      runStatus = "halted";
      break;
    }
  }

  if (runStatus === "complete" && lastSynthesis && lastSynthesis.status !== "complete") {
    runStatus = "inconclusive";
  }
  if (runStatus === "complete" && !lastSynthesis) {
    runStatus = "inconclusive";
    windDownNote = windDownNote ?? "No synthesis was produced.";
  }

  bus.line({ type: "phase", phase: "done" });
  bus.line({
    type: "run_result",
    status: runStatus,
    total_cost_usd: cost(),
    ...(windDownNote ? { note: windDownNote } : {}),
    topics,
    documents: runEvidence.all(),
  });
}

function angleStatus(status: TopicOutcome["status"]): "complete" | "halted" | "error" {
  if (status === "halted") return "halted";
  if (status === "error") return "error";
  return "complete";
}

function planFollowups(synthesis: TopicOutcome | undefined, config: RunConfig, nextAngleId: () => string): PlannedAngle[] {
  if (!synthesis) return [];
  const summary = parseFencedJson(synthesis.result);
  const conflicts: string[] = (summary?.conflicts ?? []).map((c: any) => c?.claim ?? c?.positions?.join(" vs ") ?? "").filter(Boolean);
  const gaps: string[] = (summary?.gaps ?? []).filter((g: any) => typeof g === "string" && g);
  const open = [...conflicts, ...gaps].slice(0, config.angleCount ?? DEFAULT_ANGLE_COUNT);
  return open.map((item) => ({
    angle_id: nextAngleId(),
    title: shorten(item),
    prompt: foldPriorNotes(`${config.question}\n\nResolve this specific open point from earlier rounds: ${item}`, config.priorNotesExcerpt),
  }));
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
    const body = writeupPart(t.result).trim();
    const excerpt = body.length > EXCERPT_CHAR_CAP ? body.slice(0, EXCERPT_CHAR_CAP) + "\n…(truncated)" : body;
    if (excerpt) s += `Writeup excerpt:\n${excerpt}\n`;
    s += citationOffer(t.citations ?? []);
    s += "\n";
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
  untraceable?: string[];
  evidence?: EvidenceStore;
}

/// The writeup as the reader will get it: markers renamed to their run-unique ids, the fenced summary
/// carrying resolved citations, unsupported claims marked rather than dropped, and — when an evidence
/// registry is given — a portable `## Sources` list plus footnote definitions.
function composeGrounded(result: string, summary: any, options: GroundedOptions): string {
  const { citations, prefix } = options;
  let writeup = prefixMarkers(writeupPart(result).trimEnd(), prefix);

  if (citations.length > 0) summary.citations = citations;
  else if (summary.citations !== undefined) delete summary.citations;
  if (Array.isArray(summary.findings)) {
    summary.findings = summary.findings.map((f: any) => groundFinding(f, citations, prefix, options.floorUnverified));
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
    const sources = sourcesSection(citations, options.evidence);
    if (sources) writeup += `\n\n${sources}`;
  }
  return `${writeup}\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\``;
}

function groundFinding(finding: any, citations: Citation[], prefix: string, floorUnverified: boolean): any {
  const ids: string[] = (Array.isArray(finding?.citations) ? finding.citations : [])
    .map((id: unknown) => prefix + String(id));
  const grounded = { ...finding };
  if (ids.length > 0) grounded.citations = ids;
  const supported = ids.some((id) => citations.some((c) => c.id === id && c.match !== "unresolved"));
  if (floorUnverified && !supported) grounded.confidence = "unverified";
  return grounded;
}

function prefixMarkers(writeup: string, prefix: string): string {
  return prefix ? writeup.replace(/\[\^([A-Za-z0-9_-]{1,32})\]/g, `[^${prefix}$1]`) : writeup;
}

/// A cited-sources list with a verification badge per document, then the markdown footnote definitions for
/// every marker — so the note still reads as a cited document in Obsidian or on GitHub, with no Quorum.
function sourcesSection(citations: Citation[], evidence: EvidenceStore): string {
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
    section += `${index + 1}. ${sourceLink(document, sourceId)} — ${badge(bySource.get(sourceId)!)}\n`;
  });
  section += "\n";
  section += citations.map((c) => `[^${c.id}]: ${footnoteDefinition(c, evidence.get(c.source_id))}`).join("\n");
  return section;
}

function badge(citations: Citation[]): string {
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

/// The verify pass returns claims and urls only; re-attach each finding's marker links so a corrected
/// finding keeps the evidence it was already standing on.
function keepCitationLinks(corrected: any[], original: unknown): any[] {
  const links = new Map<string, unknown>();
  if (Array.isArray(original)) {
    for (const finding of original) {
      if (finding?.claim && finding.citations !== undefined) links.set(String(finding.claim), finding.citations);
    }
  }
  return corrected.map((finding) => {
    const kept = links.get(String(finding?.claim ?? ""));
    return kept === undefined || finding?.citations !== undefined ? finding : { ...finding, citations: kept };
  });
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
    s += `- claim: ${f?.claim ?? ""}\n  confidence: ${f?.confidence ?? "unverified"}\n  sources: ${sources.join(", ")}\n`;
  }
  return s;
}

function errorOutcome(angleId: string, role: TopicOutcome["role"], spec: string, e: unknown): TopicOutcome {
  const note = e instanceof Error ? e.message : String(e);
  const summary = { headline: "Angle failed", status: "inconclusive", sourcesConsulted: 0, findings: [], note };
  return {
    angle_id: angleId,
    role,
    backend: spec.startsWith("claude-code") ? "cli" : "engine",
    provider: spec.startsWith("claude-code") ? "claude-code" : spec.split("/")[0]!,
    model: spec,
    session_id: `qeng-${randomUUID()}`,
    status: "error",
    result: "The angle failed to run.\n\n```json\n" + JSON.stringify(summary) + "\n```",
    usage: zeroUsage(spec),
    note,
  };
}

function zeroUsage(spec: string): UsageBlock {
  const provider = spec.startsWith("claude-code") ? "claude-code" : spec.split("/")[0]!;
  return {
    provider,
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

function capitalize(text: string): string {
  return text.length === 0 ? text : text[0]!.toUpperCase() + text.slice(1);
}

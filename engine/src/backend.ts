import { randomUUID } from "node:crypto";
import { Emitter, type Sink, type UsageBlock } from "./emitter.js";
import { Accountant, priceFor, type PriceTable } from "./pricing.js";
import { resolveModel, resolveEffort, splitModel, type Env, type ResolvedModel } from "./providers.js";
import { MissingKeyError } from "./errors.js";
import { runResearch, type SearchLike, type SpawnRequester } from "./agent.js";
import { EvidenceStore, type Citation } from "./evidence.js";
import { loadPriceTable, makeSearchClient, searchFee, fetchFee } from "./config.js";
import { runClaudeCode, parseClaudeCodeSpec, type SpawnFn } from "./claudeCode.js";
import { runCodex, parseCodexSpec } from "./codex.js";

export interface TopicOutcome {
  angle_id: string;
  role: "research" | "synthesis" | "verify" | "validate";
  backend: "cli" | "codex" | "engine";
  provider: string;
  model: string;
  session_id: string;
  status: "complete" | "inconclusive" | "halted" | "error";
  result: string;
  usage: UsageBlock;
  note: string | null;
  citations?: Citation[];
  reconciled?: boolean;
}

export interface RunBackendDeps {
  resolveModel?: (spec: string, env: Env) => ResolvedModel;
  search?: SearchLike;
  makeSearchClient?: (env: Env) => SearchLike;
  loadPriceTable?: (env: Env) => PriceTable;
  runClaudeCode?: typeof runClaudeCode;
  runCodex?: typeof runCodex;
  spawn?: SpawnFn;
  now?: () => number;
}

export interface RunTopicConfig {
  angleId: string;
  role: "research" | "synthesis" | "verify" | "validate";
  spec: string;
  prompt: string;
  systemPrompt: string;
  effort: string;
  perTopicBudgetUsd: number;
  timeoutMs: number;
  maxTurns?: number;
  env: Env;
  emitter: Emitter;
  signal?: AbortSignal;
  useProjectContext?: boolean;
  projectDir?: string;
  evidence?: EvidenceStore;
  evidenceDir?: string;
  spawnDir?: string;
  spawn?: SpawnRequester;
  deps: RunBackendDeps;
}

export function angleEmitter(sink: Sink, angleId: string): Emitter {
  return new (class extends Emitter {
    constructor() {
      super(sink, { angle_id: angleId });
    }
    result(): void {}
  })();
}

function zeroUsage(provider: string, model: string): UsageBlock {
  return {
    provider,
    model,
    input_tokens: 0,
    output_tokens: 0,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    cost_usd: 0,
    search_calls: 0,
    fetch_calls: 0,
  };
}

function inconclusiveResult(note: string): string {
  const summary = { headline: "Research incomplete", status: "inconclusive", sourcesConsulted: 0, findings: [], note };
  return "The engine could not complete this angle.\n\n```json\n" + JSON.stringify(summary) + "\n```";
}

export async function runTopic(cfg: RunTopicConfig): Promise<TopicOutcome> {
  const claudeSpec = parseClaudeCodeSpec(cfg.spec);
  if (claudeSpec) return runCliTopic(cfg, claudeSpec.alias);
  const codexSpec = parseCodexSpec(cfg.spec);
  if (codexSpec) return runCodexTopic(cfg, codexSpec.alias);
  return runEngineTopic(cfg);
}

async function runCodexTopic(cfg: RunTopicConfig, alias: string | undefined): Promise<TopicOutcome> {
  const cdx = await (cfg.deps.runCodex ?? runCodex)({
    prompt: cfg.prompt,
    systemPrompt: cfg.systemPrompt,
    role: cfg.role,
    effort: cfg.effort,
    alias,
    timeoutMs: cfg.timeoutMs,
    emitter: cfg.emitter,
    env: cfg.env,
    signal: cfg.signal,
    spawn: cfg.deps.spawn,
    useProjectContext: cfg.useProjectContext,
    projectDir: cfg.projectDir,
    ...(cfg.evidenceDir === undefined ? {} : { evidenceDir: cfg.evidenceDir }),
    ...(cfg.spawnDir === undefined ? {} : { spawnDir: cfg.spawnDir, angleID: cfg.angleId }),
    now: cfg.deps.now,
  });
  return {
    angle_id: cfg.angleId,
    role: cfg.role,
    backend: "codex",
    provider: "codex",
    model: cdx.model,
    session_id: cdx.sessionId,
    status: cdx.status,
    result: cdx.result,
    usage: cdx.usage,
    note: cdx.note,
  };
}

async function runCliTopic(cfg: RunTopicConfig, alias: string | undefined): Promise<TopicOutcome> {
  const cc = await (cfg.deps.runClaudeCode ?? runClaudeCode)({
    prompt: cfg.prompt,
    systemPrompt: cfg.systemPrompt,
    role: cfg.role,
    effort: cfg.effort,
    maxBudgetUsd: cfg.perTopicBudgetUsd,
    maxTurns: cfg.maxTurns ?? resolveEffort(cfg.effort).maxSteps,
    alias,
    timeoutMs: cfg.timeoutMs,
    emitter: cfg.emitter,
    env: cfg.env,
    signal: cfg.signal,
    spawn: cfg.deps.spawn,
    useProjectContext: cfg.useProjectContext,
    projectDir: cfg.projectDir,
    ...(cfg.evidenceDir === undefined ? {} : { evidenceDir: cfg.evidenceDir }),
    ...(cfg.spawnDir === undefined ? {} : { spawnDir: cfg.spawnDir, angleID: cfg.angleId }),
    now: cfg.deps.now,
  });
  return {
    angle_id: cfg.angleId,
    role: cfg.role,
    backend: "cli",
    provider: "claude-code",
    model: cc.model,
    session_id: cc.sessionId,
    status: cc.status,
    result: cc.result,
    usage: cc.usage,
    note: cc.note,
  };
}

async function runEngineTopic(cfg: RunTopicConfig): Promise<TopicOutcome> {
  const { provider, modelId } = splitModel(cfg.spec);
  const sessionId = `qeng-${randomUUID()}`;
  const priceTable = (cfg.deps.loadPriceTable ?? loadPriceTable)(cfg.env);
  const price = priceFor(priceTable, cfg.spec);

  if (!price) {
    const note = `No price table entry for model "${cfg.spec}" — refusing to run blind.`;
    cfg.emitter.error(note, provider);
    return {
      angle_id: cfg.angleId,
      role: cfg.role,
      backend: "engine",
      provider,
      model: modelId,
      session_id: sessionId,
      status: "inconclusive",
      result: inconclusiveResult(note),
      usage: zeroUsage(provider, modelId),
      note,
    };
  }

  let resolved: ResolvedModel;
  try {
    resolved = (cfg.deps.resolveModel ?? resolveModel)(cfg.spec, cfg.env);
  } catch (e) {
    const named = e instanceof MissingKeyError ? e.provider : provider;
    const note = e instanceof Error ? e.message : String(e);
    cfg.emitter.error(note, named);
    return {
      angle_id: cfg.angleId,
      role: cfg.role,
      backend: "engine",
      provider,
      model: modelId,
      session_id: sessionId,
      status: "inconclusive",
      result: inconclusiveResult(note),
      usage: zeroUsage(provider, modelId),
      note,
    };
  }

  const accountant = new Accountant(price, {
    searchFee: searchFee(priceTable, cfg.env),
    fetchFee: fetchFee(priceTable),
    budgetUsd: cfg.perTopicBudgetUsd,
  });
  const search = cfg.deps.search ?? (cfg.deps.makeSearchClient ?? makeSearchClient)(cfg.env);
  const effort = resolveEffort(cfg.effort);

  const outcome = await runResearch({
    model: resolved.model,
    provider: resolved.provider,
    modelId: resolved.modelId,
    systemPrompt: cfg.systemPrompt,
    prompt: cfg.prompt,
    effort,
    maxTurns: cfg.maxTurns ?? Number.MAX_SAFE_INTEGER,
    timeoutMs: cfg.timeoutMs,
    accountant,
    search,
    evidence: cfg.evidence ?? new EvidenceStore(),
    emitter: cfg.emitter,
    sessionId,
    now: cfg.deps.now,
    signal: cfg.signal,
    toolless: cfg.role === "validate",
    ...(cfg.spawn ? { spawn: cfg.spawn } : {}),
  });

  return {
    angle_id: cfg.angleId,
    role: cfg.role,
    backend: "engine",
    provider: resolved.provider,
    model: resolved.modelId,
    session_id: sessionId,
    status: outcome.status,
    result: outcome.result,
    usage: outcome.usage,
    note: outcome.note,
  };
}

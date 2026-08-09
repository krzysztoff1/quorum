import { randomUUID } from "node:crypto";
import type { ParsedArgs } from "./args.js";
import { Emitter } from "./emitter.js";
import { Accountant, priceFor, type PriceTable } from "./pricing.js";
import { resolveModel, resolveEffort, splitModel, type Env, type ResolvedModel } from "./providers.js";
import { MissingKeyError, UnpricedModelError } from "./errors.js";
import { runResearch, emitInconclusiveResult, type SearchLike } from "./agent.js";
import { EvidenceStore } from "./evidence.js";
import { buildSystemPrompt } from "./systemPrompt.js";
import { loadPriceTable, makeSearchClient, searchFee, fetchFee } from "./config.js";
import { runClaudeCode, parseClaudeCodeSpec, type SpawnFn } from "./claudeCode.js";
import { runCodex, parseCodexSpec, resolveCodexModel } from "./codex.js";

export interface EngineDeps {
  emitter: Emitter;
  resolveModel?: (spec: string, env: Env) => ResolvedModel;
  makeSearchClient?: (env: Env) => SearchLike;
  loadPriceTable?: (env: Env) => PriceTable;
  evidence?: EvidenceStore;
  now?: () => number;
  timeoutMs?: number;
  sessionId?: string;
  spawn?: SpawnFn;
}

function evidenceStore(env: Env, deps: EngineDeps): EvidenceStore {
  if (deps.evidence) return deps.evidence;
  const dir = env.QUORUM_EVIDENCE_DIR;
  return new EvidenceStore(dir ? { dir } : {});
}

const DEFAULT_MODEL = "deepseek/deepseek-chat";
const DEFAULT_BUDGET_USD = 0.25;
const DEFAULT_TIMEOUT_MS = 300_000;

function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

export async function runEngine(parsed: ParsedArgs, env: Env, deps: EngineDeps): Promise<void> {
  const { emitter } = deps;
  const sessionId = deps.sessionId ?? randomUUID();
  const modelSpec = parsed.model ?? DEFAULT_MODEL;
  emitter.init(sessionId, modelSpec);

  const claudeSpec = parseClaudeCodeSpec(modelSpec);
  if (claudeSpec) {
    if (!parsed.prompt) {
      const msg = 'No research prompt provided (pass -p "<topic>").';
      emitter.error(msg);
      emitInconclusiveResult(emitter, sessionId, "claude-code", claudeSpec.alias ?? "sonnet", msg);
      return;
    }
    await runClaudeCode({
      prompt: parsed.prompt,
      systemPrompt: buildSystemPrompt(parsed.appendSystemPrompt),
      role: "research",
      effort: parsed.effort ?? "medium",
      maxBudgetUsd: parsed.maxBudgetUsd ?? DEFAULT_BUDGET_USD,
      maxTurns: parsed.maxTurns ?? resolveEffort(parsed.effort).maxSteps,
      alias: claudeSpec.alias,
      timeoutMs: deps.timeoutMs ?? (Number(env.QUORUM_TIMEOUT_MS) || DEFAULT_TIMEOUT_MS),
      emitter,
      env,
      spawn: deps.spawn,
      now: deps.now,
    });
    return;
  }

  const codexSpec = parseCodexSpec(modelSpec);
  if (codexSpec) {
    const model = resolveCodexModel(codexSpec.alias);
    if (!parsed.prompt) {
      const msg = 'No research prompt provided (pass -p "<topic>").';
      emitter.error(msg);
      emitInconclusiveResult(emitter, sessionId, "codex", model, msg);
      return;
    }
    await runCodex({
      prompt: parsed.prompt,
      systemPrompt: buildSystemPrompt(parsed.appendSystemPrompt),
      role: "research",
      effort: parsed.effort ?? "medium",
      alias: codexSpec.alias,
      timeoutMs: deps.timeoutMs ?? (Number(env.QUORUM_TIMEOUT_MS) || DEFAULT_TIMEOUT_MS),
      emitter,
      env,
      spawn: deps.spawn,
      now: deps.now,
    });
    return;
  }

  const priceTable = (deps.loadPriceTable ?? loadPriceTable)(env);
  const { provider, modelId } = splitModel(modelSpec);

  const price = priceFor(priceTable, modelSpec);
  if (!price) {
    const err = new UnpricedModelError(modelSpec);
    emitter.error(err.message, provider);
    emitInconclusiveResult(emitter, sessionId, provider, modelId, err.message);
    return;
  }

  const accountant = new Accountant(price, {
    searchFee: searchFee(priceTable, env),
    fetchFee: fetchFee(priceTable),
    budgetUsd: parsed.maxBudgetUsd ?? DEFAULT_BUDGET_USD,
  });

  if (!parsed.prompt) {
    const msg = 'No research prompt provided (pass -p "<topic>").';
    emitter.error(msg);
    emitInconclusiveResult(emitter, sessionId, provider, modelId, msg, accountant);
    return;
  }

  let resolved: ResolvedModel;
  try {
    resolved = (deps.resolveModel ?? resolveModel)(modelSpec, env);
  } catch (e) {
    const named = e instanceof MissingKeyError ? e.provider : provider;
    emitter.error(errorMessage(e), named);
    emitInconclusiveResult(emitter, sessionId, provider, modelId, errorMessage(e), accountant);
    return;
  }

  const search = (deps.makeSearchClient ?? makeSearchClient)(env);

  await runResearch({
    model: resolved.model,
    provider: resolved.provider,
    modelId: resolved.modelId,
    systemPrompt: buildSystemPrompt(parsed.appendSystemPrompt),
    prompt: parsed.prompt,
    effort: resolveEffort(parsed.effort),
    maxTurns: parsed.maxTurns ?? Number.MAX_SAFE_INTEGER,
    timeoutMs: deps.timeoutMs ?? (Number(env.QUORUM_TIMEOUT_MS) || DEFAULT_TIMEOUT_MS),
    accountant,
    search,
    evidence: evidenceStore(env, deps),
    emitter,
    sessionId,
    now: deps.now,
  });
}

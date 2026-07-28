import { streamText, stepCountIs, tool, type LanguageModel, type ModelMessage, type StreamTextResult } from "ai";
import { z } from "zod";
import { Emitter, type UsageBlock } from "./emitter.js";
import { citationRequests, EvidenceStore, type Citation, type SourceContentType, type SourceDocument } from "./evidence.js";
import { Accountant, type Snapshot, type TokenUsage } from "./pricing.js";
import type { EffortConfig } from "./providers.js";

export interface SearchLike {
  search(query: string): Promise<{ results: Array<{ title: string; url: string; snippet: string }> }>;
  fetch(url: string): Promise<{
    url: string;
    markdown: string;
    title?: string;
    contentType?: SourceContentType;
    bytes?: Uint8Array;
  }>;
}

export interface ResearchConfig {
  model: LanguageModel;
  provider: string;
  modelId: string;
  systemPrompt: string;
  prompt: string;
  effort: EffortConfig;
  maxTurns: number;
  timeoutMs: number;
  accountant: Accountant;
  search: SearchLike;
  evidence: EvidenceStore;
  emitter: Emitter;
  sessionId: string;
  now?: () => number;
  signal?: AbortSignal;
  sleep?: (ms: number) => Promise<void>;
}

export interface ResearchOutcome {
  status: "complete" | "inconclusive" | "halted";
  result: string;
  note: string | null;
  usage: UsageBlock;
  documents: SourceDocument[];
  citations: Citation[];
}

const FETCH_CHAR_CAP = 12000;
const MODEL_CALL_ATTEMPTS = 3;
const MODEL_RETRY_BACKOFF_MS = 500;

export async function runResearch(cfg: ResearchConfig): Promise<ResearchOutcome> {
  const now = cfg.now ?? Date.now;
  const sleep = cfg.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const deadline = now() + cfg.timeoutMs;
  const maxSteps = Math.max(1, Math.min(cfg.maxTurns, cfg.effort.maxSteps));
  const { accountant, emitter } = cfg;

  const tools = buildTools(cfg.search, accountant, cfg.evidence, emitter);
  const providerOptions =
    cfg.provider === "anthropic" && cfg.effort.thinkingTokens > 0
      ? { anthropic: { thinking: { type: "enabled", budgetTokens: cfg.effort.thinkingTokens } } }
      : undefined;

  const messages: ModelMessage[] = [{ role: "user", content: cfg.prompt }];
  let finalText = "";
  let accumulatedText = "";
  let windDownNote: string | undefined;
  let halted = false;

  for (let turn = 0; turn < maxSteps; turn++) {
    if (cfg.signal?.aborted) {
      windDownNote = `Run halted after ${turn} step(s); returning partial findings.`;
      halted = true;
      break;
    }
    if (accountant.overBudget()) {
      windDownNote = `Budget cap of $${accountant.budgetUsd} reached after ${turn} step(s); returning partial findings.`;
      break;
    }
    if (now() >= deadline) {
      windDownNote = `Time limit reached after ${turn} step(s); returning partial findings.`;
      break;
    }

    const before = accountant.snapshot();
    if (cfg.provider === "anthropic") moveCacheBreakpoint(messages);

    async function streamOnce() {
      const res: StreamTextResult<ReturnType<typeof buildTools>, any, any> = streamText({
        model: cfg.model,
        instructions: cfg.systemPrompt,
        messages,
        tools,
        stopWhen: stepCountIs(1),
        ...(cfg.signal ? { abortSignal: cfg.signal } : {}),
        ...(providerOptions ? { providerOptions } : {}),
      });
      let stepText = "";
      let sawToolCall = false;
      for await (const part of res.fullStream) {
        if (part.type === "text-delta") {
          const t = (part as any).text ?? "";
          stepText += t;
          if (t) emitter.textDelta(t);
        } else if (part.type === "reasoning-delta") {
          const t = (part as any).text ?? "";
          if (t) emitter.thinkingDelta(t);
        } else if (part.type === "tool-call") {
          sawToolCall = true;
          emitter.toolUse((part as any).toolName, (part as any).input);
        } else if (part.type === "error") {
          throw (part as any).error ?? new Error("stream error");
        }
      }
      return { res, stepText, sawToolCall };
    }

    let streamed: Awaited<ReturnType<typeof streamOnce>> | undefined;
    for (let attempt = 0; attempt < MODEL_CALL_ATTEMPTS; attempt++) {
      try {
        streamed = await streamOnce();
        break;
      } catch (e) {
        const retriable = isTransient(e) && attempt < MODEL_CALL_ATTEMPTS - 1 && !cfg.signal?.aborted;
        if (!retriable) {
          emitter.error(errorMessage(e), cfg.provider);
          windDownNote = `Model call failed: ${errorMessage(e)}`;
          break;
        }
        await sleep(MODEL_RETRY_BACKOFF_MS * 2 ** attempt);
      }
    }
    if (!streamed) break;
    const { res, stepText, sawToolCall } = streamed;

    const usage = await res.usage;
    chargeAndEmitUsage(accountant, emitter, before, normalizeUsage(usage), cfg.provider, cfg.modelId);
    accumulatedText += stepText;

    messages.push(...(await res.response).messages);

    if (!sawToolCall) {
      finalText = stepText;
      break;
    }
  }

  const result = composeResult(finalText, accumulatedText, windDownNote, accountant);
  const usage = runTotals(accountant, cfg.provider, cfg.modelId);
  emitter.result(cfg.sessionId, accountant.totalCostUsd, result, usage);
  return {
    status: halted ? "halted" : windDownNote !== undefined ? "inconclusive" : "complete",
    result,
    note: windDownNote ?? null,
    usage,
    documents: cfg.evidence.all(),
    citations: cfg.evidence.resolveAll(citationRequests(parseFencedJson(result))),
  };
}

function buildTools(search: SearchLike, accountant: Accountant, evidence: EvidenceStore, emitter: Emitter) {
  const capture = (url: string, register: () => SourceDocument): SourceDocument => {
    const known = evidence.findByUrl(url);
    const document = register();
    if (document !== known) emitter.document(document);
    return document;
  };
  return {
    web_search: tool({
      description: "Search the web for authoritative sources. Returns titles, URLs, and snippets.",
      inputSchema: z.object({ query: z.string().describe("the search query") }),
      execute: async ({ query }) => {
        accountant.noteSearch();
        try {
          const { results } = await search.search(query);
          for (const hit of results) {
            if (hit.url) capture(hit.url, () => evidence.registerSearchResult(hit.url, hit.title));
          }
          return { results };
        } catch (e) {
          return { error: errorMessage(e), results: [] };
        }
      },
    }),
    web_fetch: tool({
      description:
        "Fetch a URL and return its main readable content as markdown, plus the source_id to cite it by.",
      inputSchema: z.object({ url: z.string().describe("the URL to fetch") }),
      execute: async ({ url }) => {
        accountant.noteFetch();
        try {
          const fetched = await search.fetch(url);
          const document = capture(url, () =>
            evidence.register({
              url: fetched.url || url,
              ...(fetched.title === undefined ? {} : { title: fetched.title }),
              ...(fetched.contentType === undefined ? {} : { contentType: fetched.contentType }),
              text: fetched.markdown,
              ...(fetched.bytes === undefined ? {} : { bytes: fetched.bytes }),
            }),
          );
          return {
            source_id: document.source_id,
            url,
            title: document.title,
            markdown: fetched.markdown.slice(0, FETCH_CHAR_CAP),
          };
        } catch (e) {
          return { url, error: errorMessage(e), markdown: "" };
        }
      },
    }),
  };
}

function normalizeUsage(usage: any): TokenUsage {
  return {
    inputTokens: usage?.inputTokens ?? 0,
    noCacheInputTokens: usage?.inputTokenDetails?.noCacheTokens,
    cacheReadTokens: usage?.inputTokenDetails?.cacheReadTokens ?? 0,
    cacheWriteTokens: usage?.inputTokenDetails?.cacheWriteTokens ?? 0,
    outputTokens: usage?.outputTokens ?? 0,
  };
}

function chargeAndEmitUsage(
  accountant: Accountant,
  emitter: Emitter,
  before: Snapshot,
  usage: TokenUsage,
  provider: string,
  modelId: string
): void {
  accountant.chargeTokens(usage);
  const after = accountant.snapshot();
  emitter.usage(after.costUsd, {
    provider,
    model: modelId,
    input_tokens: usage.inputTokens,
    output_tokens: usage.outputTokens,
    cache_read_tokens: usage.cacheReadTokens,
    cache_write_tokens: usage.cacheWriteTokens,
    cost_usd: after.costUsd - before.costUsd,
    search_calls: after.searchCalls - before.searchCalls,
    fetch_calls: after.fetchCalls - before.fetchCalls,
  });
}

function runTotals(accountant: Accountant, provider: string, modelId: string): UsageBlock {
  const s = accountant.snapshot();
  return {
    provider,
    model: modelId,
    input_tokens: s.inputTokens,
    output_tokens: s.outputTokens,
    cache_read_tokens: s.cacheReadTokens,
    cache_write_tokens: s.cacheWriteTokens,
    cost_usd: s.costUsd,
    search_calls: s.searchCalls,
    fetch_calls: s.fetchCalls,
  };
}

function composeResult(
  finalText: string,
  accumulatedText: string,
  windDownNote: string | undefined,
  accountant: Accountant
): string {
  const sourcesConsulted = accountant.fetchCalls > 0 ? accountant.fetchCalls : accountant.searchCalls;
  if (windDownNote !== undefined) {
    const body = accumulatedText.trim() || "The run stopped before completing its research.";
    return body + fencedSummary("inconclusive", sourcesConsulted, windDownNote);
  }
  if (hasFencedJson(finalText)) return finalText;
  const body = finalText.trim() || accumulatedText.trim() || "Research complete.";
  return body + fencedSummary("complete", sourcesConsulted);
}

function fencedSummary(status: "complete" | "inconclusive", sourcesConsulted: number, note?: string): string {
  const summary: Record<string, unknown> = {
    headline: status === "complete" ? "Research complete" : "Research incomplete",
    status,
    sourcesConsulted,
    findings: [],
  };
  if (note) summary.note = note;
  return "\n\n```json\n" + JSON.stringify(summary) + "\n```";
}

export function emitInconclusiveResult(
  emitter: Emitter,
  sessionId: string,
  provider: string,
  modelId: string,
  note: string,
  accountant?: Accountant
): void {
  const totals = accountant
    ? runTotals(accountant, provider, modelId)
    : { provider, model: modelId, input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, cost_usd: 0, search_calls: 0, fetch_calls: 0 };
  const sources = totals.fetch_calls > 0 ? totals.fetch_calls : totals.search_calls;
  const result = "The engine could not complete this run." + fencedSummary("inconclusive", sources, note);
  emitter.result(sessionId, totals.cost_usd, result, totals);
}

export function hasFencedJson(text: string): boolean {
  const open = text.lastIndexOf("```json");
  return open !== -1 && text.indexOf("```", open + 7) !== -1;
}

/// The trailing fenced summary object of a writeup, or undefined when it is missing or unparseable.
export function parseFencedJson(text: string): any | undefined {
  const open = text.lastIndexOf("```json");
  if (open === -1) return undefined;
  const close = text.indexOf("```", open + 7);
  if (close === -1) return undefined;
  try {
    return JSON.parse(text.slice(open + 7, close).trim());
  } catch {
    return undefined;
  }
}

function isTransient(e: unknown): boolean {
  const status = (e as any)?.statusCode ?? (e as any)?.status;
  if (typeof status === "number") return status === 429 || status >= 500;
  return /429|rate.?limit|overloaded|timed?.?out|econnreset|etimedout|fetch failed|socket|network|5\d\d/i
    .test(errorMessage(e));
}

function moveCacheBreakpoint(messages: ModelMessage[]): void {
  for (const message of messages) {
    const options = (message as any).providerOptions;
    if (!options?.anthropic?.cacheControl) continue;
    delete options.anthropic.cacheControl;
    if (Object.keys(options.anthropic).length === 0) delete options.anthropic;
    if (Object.keys(options).length === 0) delete (message as any).providerOptions;
  }
  const last = messages.at(-1) as any;
  if (!last) return;
  last.providerOptions = {
    ...last.providerOptions,
    anthropic: { ...last.providerOptions?.anthropic, cacheControl: { type: "ephemeral" } },
  };
}

function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

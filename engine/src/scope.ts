import { parseFencedJson } from "./agent.js";
import { runClaudeCode, type SpawnFn } from "./claudeCode.js";
import { Emitter } from "./emitter.js";
import type { Env } from "./providers.js";
import { briefFromQuestion } from "./record/brief.js";
import { detectLanguage } from "./record/language.js";
import type { Brief, Clarification, Tier } from "./record/schema.js";
import { titleFromQuestion, titleProblem } from "./record/title.js";
import { scopePrompt, scopeSystemPrompt } from "./systemPrompt.js";

const MAX_QUESTIONS = 3;
const MAX_OPTIONS = 4;
const SCOPE_MODEL = "claude-haiku-4-5";
const SCOPE_TIMEOUT_MS = 45_000;
const SCOPE_BUDGET_USD = 0.25;

export interface ScopeInput {
  question: string;
  clarifications?: Clarification[];
  parent_run_id?: string;
}

export interface ScopeQuestion {
  id: string;
  text: string;
  multi: boolean;
  options: { id: string; label: string }[];
}

export interface ScopeResult {
  needs_scoping: boolean;
  brief: Brief;
  questions?: ScopeQuestion[];
  fallback_reason?: string;
}

export type ModelReply = { ok: true; text: string } | { ok: false; reason: string };

export interface ScopeDeps {
  askModel: (request: { system: string; prompt: string }) => Promise<ModelReply>;
}

export function claudeScopeDeps(env: Env, spawn?: SpawnFn): ScopeDeps {
  return {
    askModel: async ({ system, prompt }) => {
      const outcome = await runClaudeCode({
        prompt, systemPrompt: system, role: "plan", effort: "low", maxBudgetUsd: SCOPE_BUDGET_USD, maxTurns: 1,
        alias: SCOPE_MODEL, timeoutMs: SCOPE_TIMEOUT_MS, emitter: new Emitter(() => {}), env, isolated: true,
        ...(spawn ? { spawn } : {}),
      });
      if (outcome.status === "complete" && outcome.result.trim()) return { ok: true, text: outcome.result };
      return { ok: false, reason: outcome.refusal?.reason ?? outcome.note ?? "the model returned nothing" };
    },
  };
}

export async function scopeQuestion(input: ScopeInput, deps: ScopeDeps): Promise<ScopeResult> {
  const asked = (input.question ?? "").trim();
  if (!asked) throw new Error("scope needs a question");
  const clarifications = input.clarifications ?? [];
  const final = clarifications.length > 0;
  const followUp = Boolean(input.parent_run_id);

  let reply: ModelReply;
  try {
    reply = await deps.askModel({ system: scopeSystemPrompt(final), prompt: scopePrompt(asked, clarifications) });
  } catch (error) {
    reply = { ok: false, reason: error instanceof Error ? error.message : String(error) };
  }
  if (!reply.ok) return fallback(asked, clarifications, reply.reason);

  const parsed = parseFencedJson(reply.text);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return fallback(asked, clarifications, "the scoper did not reply with JSON");
  }
  const raw = parsed as Record<string, unknown>;
  const resolved = text(raw.resolved);
  if (!resolved) return fallback(asked, clarifications, "the scoper did not give a resolved question");

  const suggested: Tier = followUp ? "quick" : raw.tier === "deep" ? "deep" : "quick";
  const brief: Brief = {
    asked,
    question: resolved,
    title: titleOf(text(raw.title), resolved),
    language: languageOf(raw.language, asked),
    tier: suggested,
    suggested_tier: suggested,
    tier_reason: followUp ? "" : text(raw.tier_reason),
    clarifications,
  };
  const questions = final ? [] : questionsOf(raw.questions);
  if (raw.clear === false && questions.length > 0) return { needs_scoping: true, brief, questions };
  return { needs_scoping: false, brief };
}

function fallback(asked: string, clarifications: Clarification[], reason: string): ScopeResult {
  return { needs_scoping: false, fallback_reason: reason, brief: briefFromQuestion(asked, clarifications) };
}

function text(value: unknown): string {
  return typeof value === "string" ? value.replace(/\s+/g, " ").trim() : "";
}

function titleOf(proposed: string, resolved: string): string {
  if (!proposed || titleProblem(proposed, "scope")) return titleFromQuestion(resolved);
  return titleFromQuestion(proposed);
}

function languageOf(proposed: unknown, asked: string): string {
  const code = typeof proposed === "string" ? proposed.trim().toLowerCase() : "";
  return /^[a-z]{2}$/.test(code) ? code : detectLanguage(asked);
}

function questionsOf(raw: unknown): ScopeQuestion[] {
  if (!Array.isArray(raw)) return [];
  const questions: ScopeQuestion[] = [];
  for (const item of raw) {
    if (questions.length >= MAX_QUESTIONS) break;
    if (!item || typeof item !== "object") continue;
    const entry = item as Record<string, unknown>;
    const asking = text(entry.text);
    const labels = (Array.isArray(entry.options) ? entry.options : []).map(text).filter(Boolean).slice(0, MAX_OPTIONS);
    if (!asking || labels.length < 2) continue;
    questions.push({
      id: text(entry.id) || `q${questions.length + 1}`,
      text: asking,
      multi: entry.multi === true,
      options: labels.map((label, i) => ({ id: String(i + 1), label })),
    });
  }
  return questions;
}

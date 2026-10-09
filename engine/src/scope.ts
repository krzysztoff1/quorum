import { detectLanguage } from "./record/language.js";
import { titleFromQuestion } from "./record/title.js";

export interface ScopeInput {
  question: string;
  answers?: Record<string, string[]>;
  parent_run_id?: string;
}

export interface Brief {
  question: string;
  language: string;
  title: string;
}

export interface ScopeResult {
  needs_scoping: false;
  brief: Brief;
}

export function scopeQuestion(input: ScopeInput): ScopeResult {
  const question = (input.question ?? "").trim();
  if (!question) throw new Error("scope needs a question");
  return {
    needs_scoping: false,
    brief: { question, language: detectLanguage(question), title: titleFromQuestion(question) },
  };
}

import { detectLanguage } from "./language.js";
import type { Brief, Clarification } from "./schema.js";
import { titleFromQuestion } from "./title.js";

export function briefFromQuestion(question: string, clarifications: Clarification[] = []): Brief {
  const asked = question.trim();
  return {
    asked, question: asked, title: titleFromQuestion(asked), language: detectLanguage(asked),
    tier: "quick", suggested_tier: "quick", tier_reason: "", clarifications,
  };
}

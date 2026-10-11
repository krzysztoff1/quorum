const MAX_LENGTH = 60;
const APOLOGY = /^(i(’|')?m sorry|sorry|unfortunately|i (cannot|can(’|')?t)|przepraszam|niestety|nie mogę)\b/i;
const CLARIFIER = /\b(clarify|could you|can you|do you mean|did you mean|what do you mean|please (specify|clarify)|sprecyzować|doprecyzować|czy chodzi|masz na myśli|zanim zacznę)\b/i;
const UNTITLED = "Untitled question";

export function titleFromQuestion(question: string): string {
  return trimEdges(cut(question.split(/\s+/).filter(Boolean).join(" "))) || UNTITLED;
}

export function clarifierProblem(text: string): string | undefined {
  const trimmed = text.trim();
  if (APOLOGY.test(trimmed)) return "it is an apology, not a question";
  if (CLARIFIER.test(trimmed)) return "it asks the user to clarify instead of being the question";
  return undefined;
}

export function titleProblem(title: string, source: "question" | "scope" = "scope"): string | undefined {
  const trimmed = title.trim();
  if (!trimmed) return "the title is empty";
  if (/\n/.test(trimmed)) return "the title spans more than one line";
  if (trimmed.length > MAX_LENGTH + 20) return "the title is too long to be a title";
  if (source === "question") return undefined;
  if (APOLOGY.test(trimmed)) return "the title is an apology, not a name for the question";
  if (CLARIFIER.test(trimmed)) return "the title asks to clarify instead of naming the question";
  if (/[?]\s*$/.test(trimmed)) return "the title is a question back to the user";
  return undefined;
}

function cut(text: string): string {
  if (text.length <= MAX_LENGTH) return text;
  const window = text.slice(0, MAX_LENGTH);
  const lastSpace = window.lastIndexOf(" ");
  return lastSpace === -1 ? window : window.slice(0, lastSpace);
}

function trimEdges(text: string): string {
  return text.replace(/^[\s\p{P}\p{S}]+|[\s\p{P}\p{S}]+$/gu, "");
}

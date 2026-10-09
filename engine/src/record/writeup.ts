const NARRATION_MAX_CHARS = 240;
const MARKER = /\[\^[A-Za-z0-9_-]{1,32}\]/;
const APPENDIX = /^##\s+(Sources|Citation check|Validation)\b/m;
const UNVALIDATED_NOTICE = /^> ⚠️ \*\*Unvalidated — no evidence was captured for this run\.\*\*.*$/m;

const NARRATION_OPENERS = [
  /^(ok(ay)?|alright|perfect|great|excellent|good|got it)\s*[!.,:;—–-]/u,
  /^(now )?i(’|')?(ve| have| ll| will| am| now| can)\b/u,
  /^(now )?let(’|')?(s| me| us)\b/u,
  /^based on (my|the|these) \w+/u,
  /^here(’|')?s (the|my|a) (final |full )?(report|answer|writeup|summary)\b/u,
  /^(mam już|mam wystarczając\p{L}*|teraz (napiszę|przygotuję|sporządzę|zestawię|skompiluję)|pozwól mi)(?![\p{L}\p{N}])/u,
  /^na podstawie (moich|zebranych) \p{L}+/u,
];

export function normalizeWriteup(result: string): string {
  return demoteTitles(dropNarration(stripAppendices(withoutFence(result)).trim()));
}

export function withoutFence(result: string): string {
  const open = result.lastIndexOf("```json");
  return open === -1 ? result : result.slice(0, open);
}

function stripAppendices(body: string): string {
  const appendix = body.search(APPENDIX);
  const kept = appendix === -1 ? body : body.slice(0, appendix);
  return kept.replace(UNVALIDATED_NOTICE, "");
}

function dropNarration(text: string): string {
  let rest = text;
  while (true) {
    const paragraph = leadingParagraph(rest);
    if (paragraph === undefined || !isNarration(paragraph.text)) return rest;
    const remainder = rest.slice(paragraph.end).replace(/^\n+/, "");
    if (!remainder) return rest;
    rest = remainder;
  }
}

function leadingParagraph(text: string): { text: string; end: number } | undefined {
  if (!text || text.startsWith("#") || text.startsWith("```")) return undefined;
  const end = text.indexOf("\n\n");
  const cut = end === -1 ? text.length : end;
  return { text: text.slice(0, cut).trim(), end: cut };
}

function isNarration(paragraph: string): boolean {
  if (paragraph.length > NARRATION_MAX_CHARS || MARKER.test(paragraph)) return false;
  const lowered = paragraph.toLowerCase();
  return NARRATION_OPENERS.some((opener) => opener.test(lowered));
}

function demoteTitles(text: string): string {
  let inFence = false;
  return text.split("\n").map((line) => {
    if (line.trim().startsWith("```")) {
      inFence = !inFence;
      return line;
    }
    return !inFence && line.startsWith("# ") ? `#${line}` : line;
  }).join("\n");
}

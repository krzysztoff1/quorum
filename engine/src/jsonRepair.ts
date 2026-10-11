type Token = { kind: "string"; raw: string; value: string } | { kind: "punctuation" | "literal"; raw: string };

const PUNCTUATION = new Set(["{", "}", "[", "]", ",", ":"]);
const STRAY_COMMA_STRING = ",";

function readString(text: string, start: number): { raw: string; end: number } | undefined {
  for (let i = start + 1; i < text.length; i++) {
    if (text[i] === "\\") i++;
    else if (text[i] === '"') return { raw: text.slice(start, i + 1), end: i + 1 };
  }
  return undefined;
}

function tokenize(text: string): Token[] | undefined {
  const tokens: Token[] = [];
  let i = 0;
  while (i < text.length) {
    const char = text[i]!;
    if (/\s/.test(char)) {
      i++;
    } else if (char === '"') {
      const read = readString(text, i);
      if (!read) return undefined;
      let value: string;
      try {
        value = JSON.parse(read.raw);
      } catch {
        return undefined;
      }
      tokens.push({ kind: "string", raw: read.raw, value });
      i = read.end;
    } else if (PUNCTUATION.has(char)) {
      tokens.push({ kind: "punctuation", raw: char });
      i++;
    } else {
      let end = i;
      while (end < text.length && !/\s/.test(text[end]!) && !PUNCTUATION.has(text[end]!) && text[end] !== '"') end++;
      tokens.push({ kind: "literal", raw: text.slice(i, end) });
      i = end;
    }
  }
  return tokens;
}

function isPunctuation(token: Token | undefined, ...marks: string[]): boolean {
  return token?.kind === "punctuation" && marks.includes(token.raw);
}

function withoutStrayCommaStrings(tokens: Token[]): Token[] {
  return tokens.filter((token, index) => {
    if (token.kind !== "string" || token.value !== STRAY_COMMA_STRING) return true;
    return isPunctuation(tokens[index + 1], ":") || isPunctuation(tokens[index - 1], ":");
  });
}

function withoutRedundantCommas(tokens: Token[]): Token[] {
  const kept: Token[] = [];
  tokens.forEach((token, index) => {
    if (!isPunctuation(token, ",")) return void kept.push(token);
    const previous = kept[kept.length - 1];
    const next = tokens[index + 1];
    const redundant = previous === undefined || isPunctuation(previous, ",", "[", "{")
      || isPunctuation(next, ",", "]", "}") || next === undefined;
    if (!redundant) kept.push(token);
  });
  return kept;
}

function withCommasBetweenAdjacentContainers(tokens: Token[]): Token[] {
  const joined: Token[] = [];
  tokens.forEach((token, index) => {
    const previous = tokens[index - 1];
    const closesThenOpens = (isPunctuation(previous, "}") && isPunctuation(token, "{"))
      || (isPunctuation(previous, "]") && isPunctuation(token, "["))
      || (isPunctuation(previous, "}", "]") && token.kind === "string")
      || (previous?.kind === "string" && isPunctuation(token, "{", "["));
    if (closesThenOpens) joined.push({ kind: "punctuation", raw: "," });
    joined.push(token);
  });
  return joined;
}

export function repairJson(text: string): string | undefined {
  const tokens = tokenize(text);
  if (!tokens) return undefined;
  const repaired = withCommasBetweenAdjacentContainers(withoutRedundantCommas(withoutStrayCommaStrings(tokens)));
  return repaired.map((token) => token.raw).join("");
}

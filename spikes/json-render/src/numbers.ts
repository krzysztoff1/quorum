// numberInQuote: does a datum's value appear in a cited quote, after unit normalisation?
// Handles 1–2% ≈ 1-2% ≈ "1 to 2 percent", $2.1B ≈ "$2.1 billion" ≈ "2,100 million", >$1B, "1,5%" (comma
// decimal), "1,500" vs "1.500" (ambiguous → both readings kept), "22/100", "4x".
import type { DatumT } from "./catalog";

export type NumToken = { values: number[]; pct: boolean; text: string };

const SCALE_MULT: Record<string, number> = {
  k: 1e3, K: 1e3, thousand: 1e3, M: 1e6, mn: 1e6, million: 1e6, B: 1e9, bn: 1e9, billion: 1e9,
};
const NUM = String.raw`\d+(?:[.,]\d+)*`;
const SCALE = String.raw`(?:thousand|million|billion|mn|bn|k|K|M|B)(?![A-Za-z])`;
const PCT = String.raw`(?:%|percent(?:age points?)?|pp(?![A-Za-z]))`;
const TOKEN = new RegExp(
  String.raw`[$€£]?\s?(${NUM})\s?(${SCALE})?(?:\s?(?:-|to)\s?[$€£]?\s?(${NUM})\s?(${SCALE})?)?\s?(${PCT})?`,
  "g",
);

export function normalizeText(s: string): string {
  return s
    .replace(/[   ]/g, " ")
    .replace(/[‐-―−]/g, "-")
    .replace(/per cent/gi, "percent")
    .replace(/\s+/g, " ");
}

/** All plausible readings of one numeric literal. Ambiguous separators yield both readings. */
export function parseNumberLiteral(s: string): number[] {
  if (/^\d+$/.test(s)) return [Number(s)];
  if (/^\d{1,3}(,\d{3})+(\.\d+)?$/.test(s)) {
    const us = Number(s.replace(/,/g, ""));
    // "2,100" could also be a European 2.1
    return /^\d+,\d{3}$/.test(s) ? [us, Number(s.replace(",", "."))] : [us];
  }
  if (/^\d{1,3}(\.\d{3})+(,\d+)?$/.test(s)) {
    const eu = Number(s.replace(/\./g, "").replace(",", "."));
    return /^\d+\.\d{3}$/.test(s) ? [Number(s), eu] : [eu];
  }
  if (/^\d+,\d+$/.test(s)) return [Number(s.replace(",", "."))];
  if (/^\d+\.\d+$/.test(s)) return [Number(s)];
  return [Number(s.replace(/,/g, ""))].filter(Number.isFinite);
}

export function extractNumbers(text: string): NumToken[] {
  const out: NumToken[] = [];
  for (const m of normalizeText(text).matchAll(TOKEN)) {
    const [whole, a, sa, b, sb, pct] = m;
    const scaleA = sa ?? sb; // "1-2 billion": the trailing scale covers both ends
    const push = (lit: string, sc?: string) =>
      out.push({ values: parseNumberLiteral(lit).map((x) => x * (sc ? SCALE_MULT[sc]! : 1)), pct: !!pct, text: whole.trim() });
    push(a!, scaleA);
    if (b) push(b, sb ?? sa);
  }
  return out;
}

const SCALE_OF: Record<string, number> = { k: 1e3, M: 1e6, B: 1e9 };
const eq = (a: number, b: number) => Math.abs(a - b) <= 1e-9 * Math.max(1, Math.abs(a), Math.abs(b));

export function valueInTokens(x: number, d: Pick<DatumT, "unit" | "scale">, toks: NumToken[]): boolean {
  const percentish = d.unit === "pct" || d.unit === "pp";
  const target = percentish ? x : x * (d.scale ? SCALE_OF[d.scale]! : 1);
  return toks.some((t) => t.pct === percentish && t.values.some((v) => eq(v, target)));
}

/** Every number the datum draws (v, or lo and hi) must appear in at least one cited quote. */
export function datumInQuotes(d: DatumT, quotes: string[]): boolean {
  const toks = quotes.flatMap(extractNumbers);
  const xs = d.v !== undefined ? [d.v] : [d.lo!, d.hi!];
  return xs.every((x) => valueInTokens(x, d, toks));
}

/** Timeline: the event's year must be in a cited quote. Returns undefined when `at` carries no year. */
export function yearInQuotes(at: string, quotes: string[]): boolean | undefined {
  const y = at.match(/\b(1[89]|20)\d{2}\b/)?.[0];
  if (!y) return undefined;
  return quotes.some((q) => new RegExp(String.raw`\b${y}\b`).test(q));
}

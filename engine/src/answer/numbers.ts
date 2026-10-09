export interface NumberToken {
  values: number[];
  pct: boolean;
}

export interface NumberedDatum {
  v?: number;
  lo?: number;
  hi?: number;
  unit: string;
  scale?: "k" | "M" | "B";
  cmp?: "gt" | "lt" | "approx";
  suffix?: string;
}

const SCALE_WORDS: Record<string, number> = {
  k: 1e3, K: 1e3, thousand: 1e3, tys: 1e3, M: 1e6, mn: 1e6, mln: 1e6, million: 1e6, millions: 1e6,
  B: 1e9, bn: 1e9, mld: 1e9, billion: 1e9, billions: 1e9,
};
const SCALE_OF: Record<string, number> = { k: 1e3, M: 1e6, B: 1e9 };
const PERCENTISH = new Set(["pct", "pp"]);
const CURRENCY_SIGNS: Record<string, string> = { usd: "$", eur: "€", gbp: "£" };
const UNIT_WORDS: Record<string, string> = { days: "days", months: "months", years: "years", items: "items" };

const NUM = String.raw`\d+(?:[.,]\d+)*`;
const SCALE = String.raw`(?:thousand|millions?|billions?|tys|mln|mld|mn|bn|k|K|M|B)(?![A-Za-z])`;
const PCT = String.raw`(?:%|percent(?:age points?)?|procent\w*|pp(?![A-Za-z]))`;
const CURRENCY = String.raw`[$€£]?`;
const TOKEN = new RegExp(
  String.raw`${CURRENCY}\s?(${NUM})\s?(${SCALE})?(?:\s?(?:-|to|do)\s?${CURRENCY}\s?(${NUM})\s?(${SCALE})?)?\s?(${PCT})?`,
  "g",
);

export function normalizeText(text: string): string {
  return text
    .replace(/[   ]/g, " ")
    .replace(/[‐-―−]/g, "-")
    .replace(/per cent/gi, "percent")
    .replace(/\s+/g, " ");
}

export function parseNumberLiteral(literal: string): number[] {
  if (/^\d+$/.test(literal)) return [Number(literal)];
  if (/^\d{1,3}(,\d{3})+(\.\d+)?$/.test(literal)) {
    const us = Number(literal.replace(/,/g, ""));
    return /^\d+,\d{3}$/.test(literal) ? [us, Number(literal.replace(",", "."))] : [us];
  }
  if (/^\d{1,3}(\.\d{3})+(,\d+)?$/.test(literal)) {
    const european = Number(literal.replace(/\./g, "").replace(",", "."));
    return /^\d+\.\d{3}$/.test(literal) ? [Number(literal), european] : [european];
  }
  if (/^\d+,\d+$/.test(literal)) return [Number(literal.replace(",", "."))];
  if (/^\d+\.\d+$/.test(literal)) return [Number(literal)];
  return [Number(literal.replace(/,/g, ""))].filter(Number.isFinite);
}

export function extractNumbers(text: string): NumberToken[] {
  const tokens: NumberToken[] = [];
  for (const match of normalizeText(text).matchAll(TOKEN)) {
    const [, first, firstScale, second, secondScale, percent] = match;
    const shared = firstScale ?? secondScale;
    const push = (literal: string, scale: string | undefined) =>
      tokens.push({
        values: parseNumberLiteral(literal).map((value) => value * (scale ? SCALE_WORDS[scale]! : 1)),
        pct: Boolean(percent),
      });
    push(first!, shared);
    if (second) push(second, secondScale ?? firstScale);
  }
  return tokens;
}

function sameNumber(a: number, b: number): boolean {
  return Math.abs(a - b) <= 1e-9 * Math.max(1, Math.abs(a), Math.abs(b));
}

export function numbersOf(datum: NumberedDatum): number[] {
  return datum.v !== undefined ? [datum.v] : [datum.lo!, datum.hi!];
}

function valueInTokens(value: number, datum: NumberedDatum, tokens: NumberToken[]): boolean {
  const percentish = PERCENTISH.has(datum.unit);
  const target = percentish ? value : value * (datum.scale ? SCALE_OF[datum.scale]! : 1);
  return tokens.some((token) => token.pct === percentish && token.values.some((v) => sameNumber(v, target)));
}

export function datumInQuotes(datum: NumberedDatum, quotes: string[]): boolean {
  const tokens = quotes.flatMap(extractNumbers);
  return numbersOf(datum).every((value) => valueInTokens(value, datum, tokens));
}

export function formatNumber(value: number): string {
  const rounded = Math.round(value * 1000) / 1000;
  const [whole, fraction] = String(Math.abs(rounded)).split(".");
  const grouped = whole!.length > 3 ? whole!.replace(/\B(?=(\d{3})+(?!\d))/g, ",") : whole!;
  return (rounded < 0 ? "-" : "") + grouped + (fraction ? `.${fraction}` : "");
}

export function formatDatum(datum: NumberedDatum): string {
  const scale = datum.scale ?? "";
  const one = (value: number) => {
    const number = formatNumber(value) + scale;
    const sign = CURRENCY_SIGNS[datum.unit];
    if (sign) return sign + number;
    if (datum.unit === "pct") return `${number}%`;
    if (datum.unit === "pp") return `${number} pp`;
    if (datum.unit === "ratio") return `${number}×`;
    const word = datum.suffix?.trim() || UNIT_WORDS[datum.unit];
    return word ? `${number} ${word}` : number;
  };
  const body = datum.v !== undefined ? one(datum.v) : rangeText(datum, one);
  const hedge = datum.cmp === "gt" ? ">" : datum.cmp === "lt" ? "<" : datum.cmp === "approx" ? "~" : "";
  return hedge + body;
}

function rangeText(datum: NumberedDatum, one: (value: number) => string): string {
  if (datum.unit === "pct") return `${formatNumber(datum.lo!)}–${formatNumber(datum.hi!)}${datum.scale ?? ""}%`;
  return `${one(datum.lo!)}–${one(datum.hi!)}`;
}

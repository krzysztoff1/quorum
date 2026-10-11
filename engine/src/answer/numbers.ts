export interface NumberToken {
  values: number[];
  pct: boolean;
  negative: boolean;
  currency?: string;
  yearLike: boolean;
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
  k: 1e3, thousand: 1e3, tys: 1e3,
  m: 1e6, mn: 1e6, mln: 1e6, million: 1e6, millions: 1e6,
  b: 1e9, bn: 1e9, mld: 1e9, billion: 1e9, billions: 1e9,
  t: 1e12, tn: 1e12, bln: 1e12, trillion: 1e12, trillions: 1e12,
};
const SCALE_OF: Record<string, number> = { k: 1e3, M: 1e6, B: 1e9 };
const PERCENTISH = new Set(["pct", "pp"]);
const CURRENCY_SIGNS: Record<string, string> = { usd: "$", eur: "€", gbp: "£" };
const UNIT_WORDS: Record<string, string> = { days: "days", months: "months", years: "years", items: "items" };
const CURRENCY_UNITS = new Set(["usd", "eur", "gbp"]);
const AMBIGUOUS_STRING = /^-?[1-9]\d{0,2}[.,]\d{3}$/;
const PLAIN_DECIMAL_STRING = /^-?(?:\d+|\d*[.,]\d+)$/;
const CURRENCY_OF_SYMBOL: Record<string, string> = {
  "$": "usd", "us$": "usd", usd: "usd", dollar: "usd", dollars: "usd",
  "€": "eur", eur: "eur", euro: "eur", euros: "eur",
  "£": "gbp", gbp: "gbp", pound: "gbp", pounds: "gbp",
  "zł": "pln", zl: "pln", pln: "pln",
};
const SINGLE_LETTER_SCALES = new Set(["m", "b", "t"]);
const BARE_SCALES_WITHOUT_CURRENCY = new Set(["M", "B"]);

const GROUPED = String.raw`\d{1,3}(?: \d{3})+(?![\d ]\d)(?:[.,]\d+)?`;
const NUM = String.raw`(?:${GROUPED}|\d+(?:[.,]\d+)*|\.\d+)`;
const SCALE = String.raw`(?:thousand|millions?|billions?|trillions?|tys|mln|mld|bln|mn|bn|tn|k|m|b|t)(?!\p{L})`;
const PCT = String.raw`(?:%|percent(?:age points?)?|procent\p{L}*|punkt\p{L}*\s+procent\p{L}*|pkt\.?\s?proc\.?|proc(?!\p{L})\.?|p\.p\.|pp(?!\p{L}))`;
const CURRENCY_PREFIX = String.raw`(?:US\$|[$€£]|(?:USD|EUR|GBP|PLN)(?=\s?[\d.]))`;
const CURRENCY_SUFFIX = String.raw`(?:dollars?|euros?|pounds?|USD|EUR|GBP|PLN|zł|zl)(?!\p{L})`;
const SIGN_AHEAD = String.raw`(?=\s?(?:US\$|[$€£]|\.?\d))`;
const NEGATIVE = String.raw`(?<![\w%.,)])-${SIGN_AHEAD}`;
const NEGATIVE_AFTER_CONNECTOR = String.raw`-${SIGN_AHEAD}`;
const RANGE = String.raw`(?:-|to|do|and)`;
const TOKEN = new RegExp(
  String.raw`(?<!\p{L})(${NEGATIVE})?\s?(${CURRENCY_PREFIX})?\s?(${NUM})\s?(${SCALE})?` +
  String.raw`(?:\s?${RANGE}\s?(${NEGATIVE_AFTER_CONNECTOR})?\s?(${CURRENCY_PREFIX})?\s?(${NUM})\s?(${SCALE})?)?` +
  String.raw`\s?(${PCT})?(?:\s?(${CURRENCY_SUFFIX}))?`,
  "giu",
);
const TEMPORAL_BEFORE = /\b(?:in|since|by|during|until|from|before|after|through|w|od|za|rok\w*|fy|fiscal)\s$/i;
const TEMPORAL_AFTER = /^\s?(?:r\.|roku|years?\b)/i;

export function normalizeText(text: string): string {
  return text
    .replace(/[\u00a0\u202f\u2009]/g, " ")
    .replace(/[‐-―−]/g, "-")
    .replace(/per cent/gi, "percent")
    .replace(/\s+/g, " ");
}

export function numericStringValue(text: string): number | undefined {
  const trimmed = text.trim();
  if (AMBIGUOUS_STRING.test(trimmed) || !PLAIN_DECIMAL_STRING.test(trimmed)) return undefined;
  return Number(trimmed.replace(",", "."));
}

export function parseNumberLiteral(literal: string): number[] {
  if (literal.includes(" ")) return parseNumberLiteral(literal.replace(/ /g, ""));
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

function scaleFactor(scale: string | undefined, currency: string | undefined): number {
  if (!scale) return 1;
  const isLoose = SINGLE_LETTER_SCALES.has(scale.toLowerCase()) && !BARE_SCALES_WITHOUT_CURRENCY.has(scale);
  return isLoose && !currency ? 1 : SCALE_WORDS[scale.toLowerCase()]!;
}

export function extractNumbers(text: string): NumberToken[] {
  const normalized = normalizeText(text);
  const tokens: NumberToken[] = [];
  for (const match of normalized.matchAll(TOKEN)) {
    const [whole, negative, prefix, first, firstScale, secondNegative, secondPrefix, second, secondScale, percent, suffix] = match;
    const currency = CURRENCY_OF_SYMBOL[(prefix ?? secondPrefix ?? suffix ?? "").toLowerCase()];
    const sharedScale = firstScale ?? secondScale;
    const push = (literal: string, scale: string | undefined, isNegative: boolean) => {
      const factor = scaleFactor(scale, currency);
      const sign = isNegative ? -1 : 1;
      tokens.push({
        values: parseNumberLiteral(literal).map((value) => sign * value * factor),
        pct: Boolean(percent),
        negative: isNegative,
        ...(currency ? { currency } : {}),
        yearLike: !second && isYearLike(normalized, match.index + whole.indexOf(first!), literal, factor === 1 && !percent && !currency),
      });
    };
    push(first!, sharedScale, Boolean(negative));
    if (second) push(second, secondScale ?? firstScale, Boolean(secondNegative));
  }
  return tokens;
}

function isYearLike(text: string, start: number, literal: string, bare: boolean): boolean {
  if (!bare || !/^(?:19|20)\d{2}$/.test(literal)) return false;
  return TEMPORAL_BEFORE.test(text.slice(0, start)) || TEMPORAL_AFTER.test(text.slice(start + literal.length));
}

function sameNumber(a: number, b: number): boolean {
  return Math.abs(a - b) <= 1e-9 * Math.max(1, Math.abs(a), Math.abs(b));
}

export function numbersOf(datum: NumberedDatum): number[] {
  return datum.v !== undefined ? [datum.v] : [datum.lo!, datum.hi!];
}

function tokenHoldsValue(token: NumberToken, target: number): boolean {
  return token.values.some((v) => sameNumber(v, target) || (target < 0 && !token.negative && sameNumber(v, -target)));
}

function valueInTokens(value: number, datum: NumberedDatum, tokens: NumberToken[]): boolean {
  const percentish = PERCENTISH.has(datum.unit);
  const target = percentish ? value : value * (datum.scale ? SCALE_OF[datum.scale]! : 1);
  const currency = CURRENCY_UNITS.has(datum.unit) ? datum.unit : undefined;
  return tokens.some((token) =>
    token.pct === percentish
    && (!currency || !token.currency || token.currency === currency)
    && (!token.yearLike || datum.unit === "years")
    && tokenHoldsValue(token, target));
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

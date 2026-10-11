import { describe, expect, it } from "vitest";
import { datumInQuotes, extractNumbers, formatDatum, numericStringValue, parseNumberLiteral } from "../src/answer/numbers.js";

const reported = (shape: object) => ({ basis: "reported", cite: ["x"], ...shape }) as any;

describe("a datum's number is found in its quote after unit normalisation", () => {
  it.each([
    ["1–2%", { lo: 1, hi: 2, unit: "pct" }],
    ["1-2%", { lo: 1, hi: 2, unit: "pct" }],
    ["1 to 2 percent", { lo: 1, hi: 2, unit: "pct" }],
    ["lift revenues by 5 to 15 per cent", { lo: 5, hi: 15, unit: "pct" }],
    ["$2.1B", { v: 2.1, unit: "usd", scale: "B" }],
    ["$2.1 billion", { v: 2.1, unit: "usd", scale: "B" }],
    ["2,100 million dollars", { v: 2.1, unit: "usd", scale: "B" }],
    [">$1B in ads", { v: 1, unit: "usd", scale: "B", cmp: "gt" }],
    ["a $2B annualized run rate", { v: 2000, unit: "usd", scale: "M" }],
    ["69% retention", { v: 69, unit: "pct" }],
    ["wzrost o 1,5%", { v: 1.5, unit: "pct" }],
    ["1.500 Nutzer", { v: 1500, unit: "count" }],
    ["150 million accounts", { v: 150000000, unit: "count" }],
    ["150M accounts", { v: 150, unit: "count", scale: "M" }],
    ["a privacy score of 22/100", { v: 22, unit: "score" }],
    ["4x the sales uplift", { v: 4, unit: "ratio" }],
    ["€35 million in fines", { v: 35, unit: "eur", scale: "M" }],
    ["fines of up to 3% of turnover", { v: 3, unit: "pct", cmp: "lt" }],
    ["producing 3.15 MJ from 2.05 MJ", { v: 3.15, unit: "other", suffix: "MJ" }],
  ])("%s holds %j", (quote, datum) => expect(datumInQuotes(reported(datum), [quote])).toBe(true));

  it.each([
    ["69% retention", { v: 6.9, unit: "pct" }],
    ["$2.1 billion", { v: 2.1, unit: "usd", scale: "M" }],
    ["50 restaurants", { v: 50, unit: "pct" }],
    ["80% had zero", { v: 80, unit: "count" }],
    ["1-2% of sales", { lo: 1, hi: 3, unit: "pct" }],
    ["DoorDash built advertising into a revenue line", { v: 1, unit: "usd", scale: "B" }],
    ["nearly 70% stayed", { v: 69, unit: "pct" }],
  ])("%s does not hold %j", (quote, datum) => expect(datumInQuotes(reported(datum), [quote])).toBe(false));

  it.each([
    ["69 proc. klientów", { v: 69, unit: "pct" }],
    ["wzrost o 5 punktów procentowych", { v: 5, unit: "pp" }],
    ["spadek o 2 pkt proc.", { v: 2, unit: "pp" }],
    ["1 234 567 użytkowników", { v: 1234567, unit: "count" }],
    ["1\u00a0234\u00a0567 użytkowników", { v: 1234567, unit: "count" }],
    ["cena 1 234,5 zł", { v: 1234.5, unit: "other", suffix: "zł" }],
    ["a $1.5m round", { v: 1.5, unit: "usd", scale: "M" }],
    ["worth $1.5T", { v: 1500, unit: "usd", scale: "B" }],
    ["a 2 trillion market", { v: 2000, unit: "count", scale: "B" }],
    ["PKB 3 bln zł", { v: 3000, unit: "other", scale: "B", suffix: "zł" }],
    ["margins fell -3% in 2024", { v: -3, unit: "pct" }],
    ["margins fell 3% in 2024", { v: -3, unit: "pct" }],
    ["a drop of (-3%)", { v: -3, unit: "pct" }],
    ["sales dropped 3% year on year", { v: -3, unit: "pct" }],
    ["conversion declined by 3 percent", { v: -3, unit: "pct" }],
    ["costs were down 3%", { v: -3, unit: "pct" }],
    ["a 3% decrease in orders", { v: -3, unit: "pct" }],
    ["marże spadły o 3%", { v: -3, unit: "pct" }],
    ["spadek o 3% rok do roku", { v: -3, unit: "pct" }],
    ["sprzedaż obniżyła się o 3 proc.", { v: -3, unit: "pct" }],
    ["revenue of 3 bln dollars", { v: 3, unit: "usd", scale: "B" }],
    ["conversion rose by .5% overall", { v: 0.5, unit: "pct" }],
    ["between 1 and 2% of sales", { lo: 1, hi: 2, unit: "pct" }],
    ["opening 2024 stores", { v: 2024, unit: "count" }],
    ["revenue of $5 billion", { v: 5, unit: "usd", scale: "B" }],
    ["revenue of US$5 billion", { v: 5, unit: "usd", scale: "B" }],
    ["revenue of 5 billion dollars", { v: 5, unit: "usd", scale: "B" }],
    ["revenue of 5 billion", { v: 5, unit: "usd", scale: "B" }],
    ["founded in 2019", { v: 2019, unit: "years" }],
  ])("%s holds %j", (quote, datum) => expect(datumInQuotes(reported(datum), [quote])).toBe(true));

  it.each([
    ["revenue of €5 billion", { v: 5, unit: "usd", scale: "B" }],
    ["revenue of 5 billion euros", { v: 5, unit: "usd", scale: "B" }],
    ["revenue of 5 billion zł", { v: 5, unit: "usd", scale: "B" }],
    ["revenue of $5 billion", { v: 5, unit: "gbp", scale: "B" }],
    ["Q3 was strong", { v: 3, unit: "count" }],
    ["H1 grew 10%", { v: 1, unit: "count" }],
    ["revenue rose in 2024", { v: 2024, unit: "count" }],
    ["since 2024 we grew", { v: 2024, unit: "count" }],
    ["margins fell -3% in 2024", { v: 3, unit: "pct" }],
    ["margins fell 3% in 2024", { v: 4, unit: "pct" }],
    ["a 5m walk", { v: 5, unit: "count", scale: "M" }],
    ["margins rose 3% in 2024", { v: -3, unit: "pct" }],
    ["conversion was 3% in 2024", { v: -3, unit: "pct" }],
    ["marże wzrosły o 3% w 2024", { v: -3, unit: "pct" }],
    ["PKB 3 bln zł", { v: 3, unit: "other", scale: "B", suffix: "zł" }],
    ["revenue of 3 bln dollars", { v: 3000, unit: "usd", scale: "B" }],
  ])("%s does not hold %j", (quote, datum) => expect(datumInQuotes(reported(datum), [quote])).toBe(false));

  it("keeps both readings of an ambiguous separator", () => {
    expect(parseNumberLiteral("2,100")).toEqual([2100, 2.1]);
    expect(parseNumberLiteral("1.500")).toEqual([1.5, 1500]);
    expect(parseNumberLiteral("1,234,567.5")).toEqual([1234567.5]);
    expect(parseNumberLiteral("1.234.567,5")).toEqual([1234567.5]);
  });

  it("carries a range's trailing scale and percent to both ends", () => {
    const [low, high] = extractNumbers("1-2 billion");
    expect([low!.values[0], high!.values[0]]).toEqual([1e9, 2e9]);
    expect(extractNumbers("5 to 15 percent").every((t) => t.pct)).toBe(true);
  });
});

describe("a numeric string is only a number when it cannot be read two ways", () => {
  it.each([
    ["12", 12], ["12.5", 12.5], ["12,5", 12.5], ["-3,25", -3.25], ["0.125", 0.125], ["0,125", 0.125], [" 7 ", 7],
  ])("%j is %d", (text, value) => expect(numericStringValue(text)).toBe(value));

  it.each(["12,500", "1,500", "1.500", "12.500", "1,234,567", "1.234.567,5", "abc", "", "5%"])(
    "%j is left for the repair call", (text) => expect(numericStringValue(text)).toBeUndefined());
});

describe("a datum reads as the quote's own number", () => {
  it.each([
    [{ lo: 1, hi: 2, unit: "pct" }, "1–2%"],
    [{ v: 2.1, unit: "usd", scale: "B" }, "$2.1B"],
    [{ v: 1, unit: "usd", scale: "B", cmp: "gt" }, ">$1B"],
    [{ v: 20, unit: "pct", cmp: "approx" }, "~20%"],
    [{ v: 3, unit: "pp" }, "3 pp"],
    [{ v: 35, unit: "eur", scale: "M" }, "€35M"],
    [{ v: 4, unit: "ratio" }, "4×"],
    [{ v: 50, unit: "count" }, "50"],
    [{ v: 12, unit: "months" }, "12 months"],
    [{ v: 1500, unit: "count" }, "1,500"],
    [{ v: 3.15, unit: "other", suffix: "MJ" }, "3.15 MJ"],
  ])("%j reads %s", (datum, text) => expect(formatDatum(reported(datum))).toBe(text));
});

describe("a decline word only speaks for the number in its own clause", () => {
  const holds = (quote: string, datum: object, language?: string) => datumInQuotes(reported(datum), [quote], language);

  it("reads the fall and the rise in one sentence for what each one is", () => {
    expect(holds("Revenue fell 2% while profit rose 3%", { v: -2, unit: "pct" })).toBe(true);
    expect(holds("Revenue fell 2% while profit rose 3%", { v: -3, unit: "pct" })).toBe(false);
    expect(holds("Revenue fell 2% while profit rose 3%", { v: 3, unit: "pct" })).toBe(true);
  });

  it("does not carry a decline word across a comma, a semicolon or a conjunction", () => {
    expect(holds("a tax cut, then GDP grew 3%", { v: -3, unit: "pct" })).toBe(false);
    expect(holds("sales fell; margins grew 3%", { v: -3, unit: "pct" })).toBe(false);
    expect(holds("costs fell but exports grew 3%", { v: -3, unit: "pct" })).toBe(false);
    expect(holds("imports fell whereas exports grew 3%", { v: -3, unit: "pct" })).toBe(false);
    expect(holds("sprzedaż spadła, ale marże wzrosły o 3%", { v: -3, unit: "pct" })).toBe(false);
    expect(holds("koszty spadły natomiast marże wzrosły o 3%", { v: -3, unit: "pct" })).toBe(false);
  });

  it("lets a rise word in the clause veto the decline", () => {
    expect(holds("costs fell back as sales grew 3%", { v: -3, unit: "pct" })).toBe(false);
  });

  it("still reads a decline inside its own clause", () => {
    expect(holds("Last year, revenue fell 3%", { v: -3, unit: "pct" })).toBe(true);
    expect(holds("there was a drop of 3% in orders", { v: -3, unit: "pct" })).toBe(true);
    expect(holds("firma straciła 3% udziału w rynku", { v: -3, unit: "pct" })).toBe(true);
    expect(holds("straty sięgnęły 3%", { v: -3, unit: "pct" })).toBe(true);
  });

  it("does not take a Polish word that merely starts like a loss for one", () => {
    expect(holds("Nowa strategia obejmuje 3% rynku", { v: -3, unit: "pct" })).toBe(false);
    expect(holds("strategiczny cel to 3%", { v: -3, unit: "pct" })).toBe(false);
  });
});

describe("a billion is Polish only when the text says so", () => {
  const holds = (quote: string, datum: object, language?: string) => datumInQuotes(reported(datum), [quote], language);
  const billion = { v: 1.2, unit: "usd", scale: "B" };
  const polishBillion = { v: 1200, unit: "usd", scale: "B" };

  it("does not read a diacritic anywhere in the quote as Polish", () => {
    expect(holds("$1.2 bln in funding for a firm from Kraków", billion)).toBe(true);
    expect(holds("$1.2 bln in funding for a firm from Kraków", polishBillion)).toBe(false);
  });

  it("reads a Polish unit beside the number as Polish", () => {
    expect(holds("PKB 3 bln zł", { v: 3000, unit: "other", scale: "B", suffix: "zł" })).toBe(true);
    expect(holds("PKB 3 bln zł", { v: 3, unit: "other", scale: "B", suffix: "zł" })).toBe(false);
  });

  it("follows the answer's language when it is known", () => {
    expect(holds("wartość 3 bln", { v: 3000, unit: "count", scale: "B" }, "pl")).toBe(true);
    expect(holds("worth 3 bln, says Kraków", { v: 3, unit: "count", scale: "B" }, "en")).toBe(true);
    expect(holds("worth 3 bln, says Kraków", { v: 3000, unit: "count", scale: "B" }, "en")).toBe(false);
    expect(holds("PKB 3 bln zł", { v: 3, unit: "other", scale: "B", suffix: "zł" }, "en")).toBe(true);
  });
});


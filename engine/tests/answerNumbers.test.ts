import { describe, expect, it } from "vitest";
import { datumInQuotes, extractNumbers, formatDatum, parseNumberLiteral } from "../src/answer/numbers.js";

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

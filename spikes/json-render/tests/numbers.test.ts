import { describe, expect, test } from "bun:test";
import { datumInQuotes, extractNumbers, parseNumberLiteral, yearInQuotes } from "../src/numbers";

const d = (x: object) => ({ basis: "reported", cite: ["x"], ...x }) as any;

describe("number normalisation", () => {
  test.each([
    ["1–2%", { lo: 1, hi: 2, unit: "pct" }],
    ["1-2%", { lo: 1, hi: 2, unit: "pct" }],
    ["1 to 2 percent", { lo: 1, hi: 2, unit: "pct" }],
    ["lift revenues by 5 to 15 per cent", { lo: 5, hi: 15, unit: "pct" }],
    ["$2.1B", { v: 2.1, unit: "usd", scale: "B" }],
    ["$2.1 billion", { v: 2.1, unit: "usd", scale: "B" }],
    ["2,100 million dollars", { v: 2.1, unit: "usd", scale: "B" }],
    [">$1B in ads", { v: 1, unit: "usd", scale: "B", cmp: "gt" }],
    ["topped $1 billion", { v: 1, unit: "usd", scale: "B" }],
    ["a $2B annualized run rate", { v: 2000, unit: "usd", scale: "M" }],
    ["69% retention", { v: 69, unit: "pct" }],
    ["wzrost o 1,5%", { v: 1.5, unit: "pct" }],
    ["1.500 Nutzer", { v: 1500, unit: "count" }],
    ["150M accounts", { v: 150, unit: "count", scale: "M" }],
    ["150 million accounts", { v: 150000000, unit: "count" }],
    ["a privacy score of 22/100", { v: 22, unit: "score" }],
    ["4x the sales uplift", { v: 4, unit: "ratio" }],
    ["3.5 million users", { v: 3.5, unit: "count", scale: "M" }],
  ])("%p contains %p", (quote, datum) => expect(datumInQuotes(d(datum), [quote])).toBe(true));

  test.each([
    ["69% retention", { v: 6.9, unit: "pct" }],
    ["$2.1 billion", { v: 2.1, unit: "usd", scale: "M" }],       // wrong scale
    ["50 restaurants", { v: 50, unit: "pct" }],                   // a count is not a percent
    ["80% had zero", { v: 80, unit: "count" }],                   // a percent is not a count
    ["1-2% of sales", { lo: 1, hi: 3, unit: "pct" }],             // hi missing
    ["DoorDash has built advertising into a revenue line", { v: 1, unit: "usd", scale: "B" }],
  ])("%p does not contain %p", (quote, datum) => expect(datumInQuotes(d(datum), [quote])).toBe(false));

  test("ambiguous separators keep both readings", () => {
    expect(parseNumberLiteral("2,100")).toEqual([2100, 2.1]);
    expect(parseNumberLiteral("1.500")).toEqual([1.5, 1500]);
    expect(parseNumberLiteral("1,234,567.5")).toEqual([1234567.5]);
    expect(parseNumberLiteral("1.234.567,5")).toEqual([1234567.5]);
  });

  test("range scale and percent carry to both ends", () => {
    const [a, b] = extractNumbers("1-2 billion");
    expect([a!.values[0], b!.values[0]]).toEqual([1e9, 2e9]);
    expect(extractNumbers("5 to 15 percent").every((t) => t.pct)).toBe(true);
  });

  test("timeline year check", () => {
    expect(yearInQuotes("2022-03", ["On March 4, 2022 the FTC"])).toBe(true);
    expect(yearInQuotes("2021", ["On March 4, 2022 the FTC"])).toBe(false);
    expect(yearInQuotes("Store2Vec", ["…"])).toBeUndefined();
  });
});

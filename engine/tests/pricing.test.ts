import { describe, it, expect } from "vitest";
import { DEFAULT_PRICES, priceFor, costForUsage, mergePrices, Accountant } from "../src/pricing.js";

describe("price table", () => {
  it("bundles cheap and Claude models keyed by provider/model-id", () => {
    expect(priceFor(DEFAULT_PRICES, "deepseek/deepseek-chat")).toBeDefined();
    expect(priceFor(DEFAULT_PRICES, "anthropic/claude-haiku-4-5")).toBeDefined();
  });

  it("returns undefined for an unpriced model (so the engine can refuse to run blind)", () => {
    expect(priceFor(DEFAULT_PRICES, "mystery/model-x")).toBeUndefined();
  });

  it("user override merges over the bundled defaults", () => {
    const merged = mergePrices(DEFAULT_PRICES, {
      models: { "mystery/model-x": { in: 1, out: 2, cacheRead: 0, cacheWrite: 0 } },
      search: { tavily: 0.02 },
    });
    expect(priceFor(merged, "mystery/model-x")).toEqual({ in: 1, out: 2, cacheRead: 0, cacheWrite: 0 });
    expect(merged.search.tavily).toBe(0.02);
    expect(priceFor(merged, "deepseek/deepseek-chat")).toBeDefined();
  });
});

describe("costForUsage", () => {
  it("prices non-cached input, output, and cache tokens at their own rates ($/MTok)", () => {
    const price = { in: 3, out: 15, cacheRead: 0.3, cacheWrite: 3.75 };
    const cost = costForUsage(price, {
      inputTokens: 1200,
      noCacheInputTokens: 200,
      cacheReadTokens: 1000,
      cacheWriteTokens: 400,
      outputTokens: 100,
    });
    expect(cost).toBeCloseTo(0.0039, 10);
  });

  it("falls back to total input when the no-cache breakdown is absent", () => {
    const price = { in: 0.27, out: 1.1, cacheRead: 0.07, cacheWrite: 0 };
    const cost = costForUsage(price, {
      inputTokens: 10000,
      noCacheInputTokens: undefined,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      outputTokens: 2000,
    });
    expect(cost).toBeCloseTo(0.0049, 10);
  });
});

describe("Accountant", () => {
  const price = { in: 0.27, out: 1.1, cacheRead: 0.07, cacheWrite: 0 };

  it("accumulates token cost, search and fetch fees monotonically", () => {
    const acc = new Accountant(price, { searchFee: 0.008, fetchFee: 0, budgetUsd: 1 });
    const before = acc.totalCostUsd;
    acc.chargeTokens({ inputTokens: 10000, noCacheInputTokens: 10000, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 2000 });
    expect(acc.totalCostUsd).toBeCloseTo(0.0049, 10);
    acc.noteSearch();
    acc.noteFetch();
    expect(acc.totalCostUsd).toBeCloseTo(0.0129, 10);
    expect(acc.totalCostUsd).toBeGreaterThan(before);
    expect(acc.searchCalls).toBe(1);
    expect(acc.fetchCalls).toBe(1);
  });

  it("flips overBudget once cumulative cost reaches the cap", () => {
    const acc = new Accountant(price, { searchFee: 0.008, fetchFee: 0, budgetUsd: 0.05 });
    expect(acc.overBudget()).toBe(false);
    for (let i = 0; i < 4; i++) {
      acc.chargeTokens({ inputTokens: 10000, noCacheInputTokens: 10000, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 2000 });
      acc.noteSearch();
    }
    expect(acc.totalCostUsd).toBeGreaterThan(0.05);
    expect(acc.overBudget()).toBe(true);
  });

  it("snapshot exposes per-step deltas for usage events", () => {
    const acc = new Accountant(price, { searchFee: 0.008, fetchFee: 0, budgetUsd: 1 });
    const s0 = acc.snapshot();
    acc.chargeTokens({ inputTokens: 100, noCacheInputTokens: 100, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 50 });
    acc.noteSearch();
    const s1 = acc.snapshot();
    expect(s1.searchCalls - s0.searchCalls).toBe(1);
    expect(s1.inputTokens - s0.inputTokens).toBe(100);
    expect(s1.costUsd).toBeGreaterThan(s0.costUsd);
  });
});

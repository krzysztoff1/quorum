import { describe, it, expect } from "vitest";
import { resolveEffort } from "../src/providers.js";

describe("resolveEffort", () => {
  it("maps known efforts to a step budget and thinking-token budget", () => {
    expect(resolveEffort("low").maxSteps).toBeLessThan(resolveEffort("high").maxSteps);
    expect(resolveEffort("max").maxSteps).toBeGreaterThanOrEqual(resolveEffort("xhigh").maxSteps);
    expect(resolveEffort("high").thinkingTokens).toBeGreaterThan(0);
  });
  it("degrades unknown or missing effort to medium defaults, never throwing", () => {
    expect(resolveEffort("banana")).toEqual(resolveEffort("medium"));
    expect(resolveEffort(undefined)).toEqual(resolveEffort("medium"));
  });
});

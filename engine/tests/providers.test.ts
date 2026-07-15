import { describe, it, expect } from "vitest";
import { splitModel, resolveModel, resolveEffort } from "../src/providers.js";
import { MissingKeyError } from "../src/errors.js";

describe("splitModel", () => {
  it("splits provider/model-id on the first slash", () => {
    expect(splitModel("deepseek/deepseek-chat")).toEqual({ provider: "deepseek", modelId: "deepseek-chat" });
  });
  it("keeps slashes inside the model id (openrouter long tail)", () => {
    expect(splitModel("openrouter/anthropic/claude-3.5")).toEqual({
      provider: "openrouter",
      modelId: "anthropic/claude-3.5",
    });
  });
});

describe("resolveModel", () => {
  it("throws MissingKeyError naming the provider when the key is absent", () => {
    expect(() => resolveModel("anthropic/claude-haiku-4-5", {})).toThrow(MissingKeyError);
    try {
      resolveModel("anthropic/claude-haiku-4-5", {});
    } catch (e) {
      expect((e as MissingKeyError).provider).toBe("anthropic");
    }
  });

  it("builds an Anthropic model from QUORUM_ANTHROPIC_KEY", () => {
    const { model, provider, modelId } = resolveModel("anthropic/claude-haiku-4-5", { QUORUM_ANTHROPIC_KEY: "k" });
    expect(provider).toBe("anthropic");
    expect(modelId).toBe("claude-haiku-4-5");
    expect(model.modelId).toBe("claude-haiku-4-5");
  });

  it("builds an openai-compatible model (deepseek) from its key", () => {
    const { model, provider } = resolveModel("deepseek/deepseek-chat", { QUORUM_DEEPSEEK_KEY: "k" });
    expect(provider).toBe("deepseek");
    expect(model.modelId).toBe("deepseek-chat");
  });

  it("accepts the generic openai-compatible key as a fallback", () => {
    const { model } = resolveModel("groq/llama-3.3-70b", { QUORUM_OPENAI_COMPATIBLE_KEY: "k" });
    expect(model.modelId).toBe("llama-3.3-70b");
  });

  it("routes an unknown provider through a generic base url when configured", () => {
    const { provider, modelId } = resolveModel("acme/model-1", {
      QUORUM_OPENAI_COMPATIBLE_KEY: "k",
      QUORUM_OPENAI_COMPATIBLE_BASE_URL: "https://acme.example/v1",
    });
    expect(provider).toBe("acme");
    expect(modelId).toBe("model-1");
  });

  it("errors on an unknown provider with no generic base url", () => {
    expect(() => resolveModel("acme/model-1", { QUORUM_OPENAI_COMPATIBLE_KEY: "k" })).toThrow();
  });

  it("builds an OpenRouter model from QUORUM_OPENROUTER_KEY", () => {
    const { provider, modelId } = resolveModel("openrouter/meta-llama/llama-3.1-8b", { QUORUM_OPENROUTER_KEY: "k" });
    expect(provider).toBe("openrouter");
    expect(modelId).toBe("meta-llama/llama-3.1-8b");
  });
});

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

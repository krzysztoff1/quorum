import { createAnthropic } from "@ai-sdk/anthropic";
import { createOpenAICompatible } from "@ai-sdk/openai-compatible";
import { createOpenRouter } from "@openrouter/ai-sdk-provider";
import type { LanguageModel } from "ai";
import { MissingKeyError } from "./errors.js";

export type Env = Record<string, string | undefined>;

export interface ResolvedModel {
  model: LanguageModel;
  provider: string;
  modelId: string;
}

export function splitModel(spec: string): { provider: string; modelId: string } {
  const slash = spec.indexOf("/");
  if (slash === -1) return { provider: spec, modelId: spec };
  return { provider: spec.slice(0, slash), modelId: spec.slice(slash + 1) };
}

const OPENAI_COMPATIBLE: Record<string, { baseURL: string; keyEnv: string }> = {
  deepseek: { baseURL: "https://api.deepseek.com/v1", keyEnv: "QUORUM_DEEPSEEK_KEY" },
  glm: { baseURL: "https://open.bigmodel.cn/api/paas/v4", keyEnv: "QUORUM_GLM_KEY" },
  kimi: { baseURL: "https://api.moonshot.cn/v1", keyEnv: "QUORUM_KIMI_KEY" },
  groq: { baseURL: "https://api.groq.com/openai/v1", keyEnv: "QUORUM_GROQ_KEY" },
};

export function resolveModel(spec: string, env: Env): ResolvedModel {
  const { provider, modelId } = splitModel(spec);

  if (provider === "anthropic") {
    const apiKey = env.QUORUM_ANTHROPIC_KEY;
    if (!apiKey) throw new MissingKeyError("anthropic", "QUORUM_ANTHROPIC_KEY");
    return { model: createAnthropic({ apiKey })(modelId), provider, modelId };
  }

  if (provider === "openrouter") {
    const apiKey = env.QUORUM_OPENROUTER_KEY;
    if (!apiKey) throw new MissingKeyError("openrouter", "QUORUM_OPENROUTER_KEY");
    return { model: createOpenRouter({ apiKey })(modelId) as unknown as LanguageModel, provider, modelId };
  }

  const known = OPENAI_COMPATIBLE[provider];
  const baseURL = known?.baseURL ?? env.QUORUM_OPENAI_COMPATIBLE_BASE_URL;
  if (!baseURL) {
    throw new Error(
      `Unknown provider "${provider}". Use anthropic/openrouter/deepseek/glm/kimi/groq, or set QUORUM_OPENAI_COMPATIBLE_BASE_URL.`
    );
  }
  const keyEnv = known?.keyEnv ?? "QUORUM_OPENAI_COMPATIBLE_KEY";
  const apiKey = env[keyEnv] ?? env.QUORUM_OPENAI_COMPATIBLE_KEY;
  if (!apiKey) throw new MissingKeyError(provider, keyEnv);
  return { model: createOpenAICompatible({ name: provider, baseURL, apiKey })(modelId), provider, modelId };
}

export interface EffortConfig {
  maxSteps: number;
  thinkingTokens: number;
}

const EFFORT: Record<string, EffortConfig> = {
  low: { maxSteps: 4, thinkingTokens: 0 },
  medium: { maxSteps: 8, thinkingTokens: 2000 },
  high: { maxSteps: 12, thinkingTokens: 6000 },
  xhigh: { maxSteps: 16, thinkingTokens: 10000 },
  max: { maxSteps: 20, thinkingTokens: 16000 },
};

export function resolveEffort(effort: string | undefined): EffortConfig {
  return EFFORT[(effort ?? "").toLowerCase()] ?? EFFORT.medium!;
}

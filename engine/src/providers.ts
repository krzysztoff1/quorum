export type Env = Record<string, string | undefined>;

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

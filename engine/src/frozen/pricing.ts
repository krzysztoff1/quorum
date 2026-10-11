export interface ModelPrice {
  in: number;
  out: number;
  cacheRead: number;
  cacheWrite: number;
}

export interface PriceTable {
  models: Record<string, ModelPrice>;
  search: Record<string, number>;
  fetch: Record<string, number>;
}

export interface TokenUsage {
  inputTokens: number;
  noCacheInputTokens: number | undefined;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  outputTokens: number;
}

// $/MTok in / out / cache-read / cache-write. ponytail: bundled list prices — override via
// QUORUM_PRICE_TABLE_PATH (JSON) when a provider's rates change.
export const DEFAULT_PRICES: PriceTable = {
  models: {
    "anthropic/claude-haiku-4-5": { in: 1, out: 5, cacheRead: 0.1, cacheWrite: 1.25 },
    "anthropic/claude-sonnet-5": { in: 3, out: 15, cacheRead: 0.3, cacheWrite: 3.75 },
    "anthropic/claude-opus-4-8": { in: 5, out: 25, cacheRead: 0.5, cacheWrite: 6.25 },
    "deepseek/deepseek-chat": { in: 0.27, out: 1.1, cacheRead: 0.07, cacheWrite: 0 },
    "deepseek/deepseek-reasoner": { in: 0.55, out: 2.19, cacheRead: 0.14, cacheWrite: 0 },
    "glm/glm-4.6": { in: 0.6, out: 2.2, cacheRead: 0.11, cacheWrite: 0 },
    "kimi/kimi-k2": { in: 0.6, out: 2.5, cacheRead: 0.15, cacheWrite: 0 },
    "groq/llama-3.3-70b": { in: 0.59, out: 0.79, cacheRead: 0, cacheWrite: 0 },
  },
  search: { tavily: 0.008, brave: 0.004 },
  fetch: { jina: 0 },
};

export function priceFor(table: PriceTable, modelKey: string): ModelPrice | undefined {
  return table.models[modelKey];
}

export function mergePrices(base: PriceTable, override: Partial<PriceTable>): PriceTable {
  return {
    models: { ...base.models, ...(override.models ?? {}) },
    search: { ...base.search, ...(override.search ?? {}) },
    fetch: { ...base.fetch, ...(override.fetch ?? {}) },
  };
}

export function costForUsage(price: ModelPrice, u: TokenUsage): number {
  const noCache = u.noCacheInputTokens ?? u.inputTokens;
  return (
    (noCache * price.in +
      u.cacheReadTokens * price.cacheRead +
      u.cacheWriteTokens * price.cacheWrite +
      u.outputTokens * price.out) /
    1_000_000
  );
}

export interface AccountantConfig {
  searchFee: number;
  fetchFee: number;
  budgetUsd: number;
}

export interface Snapshot {
  costUsd: number;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  searchCalls: number;
  fetchCalls: number;
}

export class Accountant {
  totalCostUsd = 0;
  inputTokens = 0;
  outputTokens = 0;
  cacheReadTokens = 0;
  cacheWriteTokens = 0;
  searchCalls = 0;
  fetchCalls = 0;
  readonly budgetUsd: number;

  constructor(private readonly price: ModelPrice, private readonly config: AccountantConfig) {
    this.budgetUsd = config.budgetUsd;
  }

  chargeTokens(u: TokenUsage): number {
    const cost = costForUsage(this.price, u);
    this.totalCostUsd += cost;
    this.inputTokens += u.inputTokens;
    this.outputTokens += u.outputTokens;
    this.cacheReadTokens += u.cacheReadTokens;
    this.cacheWriteTokens += u.cacheWriteTokens;
    return cost;
  }

  noteSearch(): void {
    this.searchCalls += 1;
    this.totalCostUsd += this.config.searchFee;
  }

  noteFetch(): void {
    this.fetchCalls += 1;
    this.totalCostUsd += this.config.fetchFee;
  }

  overBudget(): boolean {
    return this.totalCostUsd >= this.config.budgetUsd;
  }

  snapshot(): Snapshot {
    return {
      costUsd: this.totalCostUsd,
      inputTokens: this.inputTokens,
      outputTokens: this.outputTokens,
      cacheReadTokens: this.cacheReadTokens,
      cacheWriteTokens: this.cacheWriteTokens,
      searchCalls: this.searchCalls,
      fetchCalls: this.fetchCalls,
    };
  }
}

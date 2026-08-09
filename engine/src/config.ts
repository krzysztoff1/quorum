import { readFileSync } from "node:fs";
import { SearchClient } from "./search.js";
import { DEFAULT_PRICES, mergePrices, type PriceTable } from "./pricing.js";
import type { Env } from "./providers.js";

/// What a run can promise about its evidence. Without a search key the run has no own-search tools, so its
/// angles read through the CLI's built-in web search: content the model saw and nobody kept. Nothing in
/// such a run can be checked against a snapshot, and it says so rather than letting the reader assume.
export type GroundingTier = "captured" | "none";

export function hasSearchKey(env: Env): boolean {
  return Boolean(env.QUORUM_TAVILY_KEY || env.QUORUM_BRAVE_KEY);
}

export function groundingTier(env: Env): GroundingTier {
  return hasSearchKey(env) ? "captured" : "none";
}

export function searchProviderName(env: Env): "tavily" | "brave" {
  return !env.QUORUM_TAVILY_KEY && env.QUORUM_BRAVE_KEY ? "brave" : "tavily";
}

export function makeSearchClient(env: Env, concurrency?: number): SearchClient {
  return new SearchClient({
    provider: searchProviderName(env),
    tavilyKey: env.QUORUM_TAVILY_KEY,
    braveKey: env.QUORUM_BRAVE_KEY,
    ...(concurrency === undefined ? {} : { concurrency }),
  });
}

export function loadPriceTable(env: Env): PriceTable {
  const path = env.QUORUM_PRICE_TABLE_PATH;
  if (!path) return DEFAULT_PRICES;
  try {
    return mergePrices(DEFAULT_PRICES, JSON.parse(readFileSync(path, "utf8")));
  } catch {
    // ponytail: unreadable/invalid override → fall back to bundled defaults rather than crash.
    return DEFAULT_PRICES;
  }
}

export function searchFee(table: PriceTable, env: Env): number {
  return table.search[searchProviderName(env)] ?? 0;
}

export function fetchFee(table: PriceTable): number {
  return table.fetch.jina ?? 0;
}

import { SearchClient } from "./search.js";
import type { Env } from "./providers.js";

export type GroundingTier = "captured" | "none";

export function hasSearchKey(env: Env): boolean {
  return Boolean(env.QUORUM_TAVILY_KEY || env.QUORUM_BRAVE_KEY);
}

export function groundingTier(env: Env, fetchesWithoutKey = false): GroundingTier {
  return fetchesWithoutKey || hasSearchKey(env) ? "captured" : "none";
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

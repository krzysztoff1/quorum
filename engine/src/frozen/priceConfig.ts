import { readFileSync } from "node:fs";
import { DEFAULT_PRICES, mergePrices, type PriceTable } from "./pricing.js";
import { searchProviderName } from "../config.js";
import type { Env } from "../providers.js";

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

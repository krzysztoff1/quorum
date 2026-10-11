import { scanStore } from "./runStore.js";
import { STAGE_ORDER } from "./tiers.js";
import type { ProgressStage } from "./liveness.js";
import type { Tier } from "./record/schema.js";

const RECENT_RUNS = 9;

export function stageMedians(storeDir: string, tier: Tier, fallback: Record<ProgressStage, number>): Record<ProgressStage, number> {
  const recent = scanStore(storeDir)
    .map((entry) => entry.record)
    .filter((record) => record?.status === "complete" && record.brief?.tier === tier && record.stats?.stage_s)
    .sort((a, b) => (a.created_at < b.created_at ? 1 : -1))
    .slice(0, RECENT_RUNS);
  if (recent.length === 0) return fallback;
  return Object.fromEntries(STAGE_ORDER.map((stage) => [stage, median(recent.map((record) => Number(record.stats.stage_s[stage] ?? 0)))])) as Record<ProgressStage, number>;
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2;
}

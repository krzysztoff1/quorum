import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { RUN_FILE } from "./record/store.js";
import { STAGE_ORDER } from "./tiers.js";
import type { ProgressStage } from "./liveness.js";
import type { Tier } from "./record/schema.js";

const RECENT_RUNS = 9;
const SCAN_LIMIT = 40;
const COUNTED = new Set(["complete", "partial"]);

export function stageMedians(
  storeDir: string, tier: Tier, fallback: Record<ProgressStage, number>, options: { scanLimit?: number } = {},
): Record<ProgressStage, number> {
  const recent = recentRecords(storeDir, options.scanLimit ?? SCAN_LIMIT)
    .filter((record) => COUNTED.has(record?.status) && record.brief?.tier === tier && record.stats?.stage_s)
    .sort((a, b) => (a.created_at < b.created_at ? 1 : -1))
    .slice(0, RECENT_RUNS);
  return Object.fromEntries(STAGE_ORDER.map((stage) => {
    const seen = recent.map((record) => record.stats.stage_s[stage]).filter((value): value is number => Number.isFinite(value));
    return [stage, seen.length > 0 ? median(seen) : fallback[stage]];
  })) as Record<ProgressStage, number>;
}

function recentRecords(storeDir: string, limit: number): any[] {
  const questionsDir = join(storeDir, "questions");
  if (!existsSync(questionsDir)) return [];
  const files: { path: string; touched: number }[] = [];
  for (const question of readdirSync(questionsDir)) {
    const runsDir = join(questionsDir, question, "runs");
    if (!existsSync(runsDir)) continue;
    for (const run of readdirSync(runsDir)) {
      const path = join(runsDir, run, RUN_FILE);
      try {
        files.push({ path, touched: statSync(path).mtimeMs });
      } catch {
        // no record yet
      }
    }
  }
  return files
    .sort((a, b) => b.touched - a.touched)
    .slice(0, limit)
    .flatMap((file) => {
      try {
        return [JSON.parse(readFileSync(file.path, "utf8"))];
      } catch {
        return [];
      }
    });
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2;
}

import type { Env } from "./providers.js";
import type { ProgressStage } from "./liveness.js";
import type { Tier } from "./record/schema.js";
import type { RunConfig } from "./run.js";

export type TopicRole = "plan" | "research" | "synthesis" | "verify" | "validate";

export interface WallRecipe {
  hardSec: number;
  windDownSec: number;
  tailSec: Record<TopicRole, number>;
}

export interface TierRecipe {
  angleCount: number;
  angleConcurrency: number;
  rounds: number;
  critics: boolean;
  effort: string;
  maxTurns: number;
  perTopicBudgetUSD: number;
  runBudgetUSD: number;
  models: { planner: string; research: string; synthesis: string; validator: string };
  timeoutSec: Record<TopicRole, number>;
  wall: WallRecipe | null;
  stageEstimateSec: Record<ProgressStage, number>;
}

export const QUICK_HARD_WALL_SEC = 270;
export const SALVAGE_RESERVE_SEC = 15;

export const TIER_RECIPES: Record<Tier, TierRecipe> = {
  quick: {
    angleCount: 3,
    angleConcurrency: 3,
    rounds: 1,
    critics: false,
    effort: "medium",
    maxTurns: 10,
    perTopicBudgetUSD: 1,
    runBudgetUSD: 3,
    models: {
      planner: "claude-code/haiku",
      research: "claude-code/sonnet",
      synthesis: "claude-code/sonnet",
      validator: "claude-code/haiku",
    },
    timeoutSec: { plan: 20, research: 140, synthesis: 55, verify: 15, validate: 25 },
    wall: {
      hardSec: QUICK_HARD_WALL_SEC,
      windDownSec: 220,
      tailSec: { plan: 235, research: 95, synthesis: 40, verify: 40, validate: SALVAGE_RESERVE_SEC },
    },
    stageEstimateSec: { research: 150, draft: 55, check: 40, answer: 5 },
  },
  deep: {
    angleCount: 4,
    angleConcurrency: 4,
    rounds: 3,
    critics: true,
    effort: "high",
    maxTurns: 25,
    perTopicBudgetUSD: 4,
    runBudgetUSD: 20,
    models: {
      planner: "claude-code/sonnet",
      research: "claude-code/sonnet",
      synthesis: "claude-code/opus",
      validator: "claude-code/haiku",
    },
    timeoutSec: { plan: 60, research: 480, synthesis: 300, verify: 60, validate: 120 },
    wall: null,
    stageEstimateSec: { research: 600, draft: 150, check: 300, answer: 5 },
  },
};

export const STAGE_ORDER: ProgressStage[] = ["research", "draft", "check", "answer"];

export function tierOf(config: Pick<RunConfig, "tier" | "brief">): Tier | undefined {
  return config.tier ?? config.brief?.tier;
}

export interface ResolvedTier {
  tier: Tier;
  recipe: TierRecipe;
  config: RunConfig;
}

export function resolveTier(config: RunConfig, env: Env): ResolvedTier | undefined {
  const tier = tierOf(config);
  if (!tier) return undefined;
  const recipe = scaled(TIER_RECIPES[tier], timeScale(env));
  const filled: RunConfig = {
    ...config,
    tier,
    angleCount: config.angleCount ?? recipe.angleCount,
    angleConcurrency: config.angleConcurrency ?? recipe.angleConcurrency,
    rounds: config.rounds ?? recipe.rounds,
    angleModel: config.angleModel ?? recipe.models.research,
    plannerModel: config.plannerModel ?? recipe.models.planner,
    synthesisModel: config.synthesisModel ?? recipe.models.synthesis,
    validatorModel: config.validatorModel ?? recipe.models.validator,
    effort: config.effort ?? recipe.effort,
    maxTurns: config.maxTurns ?? recipe.maxTurns,
    perTopicBudgetUSD: config.perTopicBudgetUSD ?? recipe.perTopicBudgetUSD,
    runBudgetUSD: config.runBudgetUSD ?? recipe.runBudgetUSD,
    perTopicTimeoutSec: config.perTopicTimeoutSec ?? recipe.timeoutSec.research,
    critics: config.critics ?? recipe.critics,
    ...(recipe.wall && config.runDeadlineSec === undefined ? { runDeadlineSec: recipe.wall.hardSec } : {}),
  };
  return { tier, recipe, config: filled };
}

export function remainingEstimateSec(medians: Record<ProgressStage, number>, stage: ProgressStage, elapsedInStageSec: number): number {
  const at = STAGE_ORDER.indexOf(stage);
  const later = STAGE_ORDER.slice(at + 1).reduce((sum, next) => sum + medians[next], 0);
  return Math.max(0, medians[stage] - elapsedInStageSec) + later;
}

function timeScale(env: Env): number {
  const scale = Number(env.QUORUM_WALL_SCALE);
  return Number.isFinite(scale) && scale > 0 ? scale : 1;
}

function scaled(recipe: TierRecipe, scale: number): TierRecipe {
  if (scale === 1) return recipe;
  const times = (record: Record<TopicRole, number>) =>
    Object.fromEntries(Object.entries(record).map(([role, sec]) => [role, sec * scale])) as Record<TopicRole, number>;
  return {
    ...recipe,
    timeoutSec: times(recipe.timeoutSec),
    wall: recipe.wall && {
      hardSec: recipe.wall.hardSec * scale,
      windDownSec: recipe.wall.windDownSec * scale,
      tailSec: times(recipe.wall.tailSec),
    },
  };
}

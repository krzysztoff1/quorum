import { describe, expect, it } from "vitest";
import {
  QUICK_HARD_WALL_SEC,
  SALVAGE_RESERVE_SEC,
  TIER_RECIPES,
  remainingEstimateSec,
  resolveTier,
  tierOf,
  type TopicRole,
} from "../src/tiers.js";

const ROLES: TopicRole[] = ["plan", "research", "synthesis", "verify", "validate"];

describe("the tier table", () => {
  it("has exactly two tiers, quick and deep, and leaves wide unbuilt", () => {
    expect(Object.keys(TIER_RECIPES).sort()).toEqual(["deep", "quick"]);
  });

  it("makes quick small: up to three angles, one round, no critics, no concurrency beyond the angles", () => {
    const quick = TIER_RECIPES.quick;
    expect(quick.angleCount).toBeGreaterThanOrEqual(2);
    expect(quick.angleCount).toBeLessThanOrEqual(3);
    expect(quick.rounds).toBe(1);
    expect(quick.critics).toBe(false);
    expect(quick.angleConcurrency).toBe(quick.angleCount);
  });

  it("makes deep the full crew: a looping validator, critics, and no wall", () => {
    const deep = TIER_RECIPES.deep;
    expect(deep.rounds).toBeGreaterThanOrEqual(3);
    expect(deep.critics).toBe(true);
    expect(deep.wall).toBeNull();
    expect(deep.angleCount).toBeGreaterThanOrEqual(3);
    expect(deep.angleCount).toBeLessThanOrEqual(5);
  });

  it("walls quick at 4:30 and winds down before the wall", () => {
    const wall = TIER_RECIPES.quick.wall!;
    expect(QUICK_HARD_WALL_SEC).toBe(270);
    expect(wall.hardSec).toBe(270);
    expect(wall.windDownSec).toBeLessThan(wall.hardSec);
    expect(wall.windDownSec).toBeGreaterThan(0);
  });

  it("fits quick's sequential stages inside its wall by construction, with room to salvage", () => {
    const { timeoutSec, wall } = TIER_RECIPES.quick;
    const sequential = timeoutSec.plan + timeoutSec.research + timeoutSec.synthesis + timeoutSec.validate;
    expect(sequential + SALVAGE_RESERVE_SEC).toBeLessThanOrEqual(wall!.hardSec);
  });

  it("lets every stage after research still finish when research uses all of its time", () => {
    const { timeoutSec, wall } = TIER_RECIPES.quick;
    const afterPlanning = wall!.hardSec - timeoutSec.plan;
    expect(timeoutSec.research).toBeLessThanOrEqual(afterPlanning - wall!.tailSec.research);
  });

  it("gives every role a timeout and a tail in every tier that has a wall", () => {
    for (const tier of Object.values(TIER_RECIPES)) {
      for (const role of ROLES) expect(tier.timeoutSec[role]).toBeGreaterThan(0);
      if (tier.wall) for (const role of ROLES) expect(tier.wall.tailSec[role]).toBeGreaterThanOrEqual(0);
    }
  });

  it("runs quick on the Claude subscription CLI alone", () => {
    for (const tier of Object.values(TIER_RECIPES)) {
      for (const model of Object.values(tier.models)) expect(model.startsWith("claude-code/")).toBe(true);
    }
  });
});

describe("resolving a run's tier into its config", () => {
  const base = { question: "q" };

  it("takes the tier from the config, then from the brief", () => {
    expect(tierOf({ ...base, tier: "deep" })).toBe("deep");
    expect(tierOf({ ...base, brief: { question: "q", language: "en", tier: "deep" } })).toBe("deep");
    expect(tierOf({ ...base, tier: "quick", brief: { question: "q", language: "en", tier: "deep" } })).toBe("quick");
    expect(tierOf(base)).toBeUndefined();
  });

  it("fills a run's knobs from the tier's recipe", () => {
    const { config, recipe } = resolveTier({ ...base, tier: "quick" }, {})!;
    expect(recipe).toBe(TIER_RECIPES.quick);
    expect(config).toMatchObject({
      angleCount: TIER_RECIPES.quick.angleCount,
      rounds: 1,
      angleConcurrency: TIER_RECIPES.quick.angleConcurrency,
      angleModel: TIER_RECIPES.quick.models.research,
      synthesisModel: TIER_RECIPES.quick.models.synthesis,
      validatorModel: TIER_RECIPES.quick.models.validator,
      effort: TIER_RECIPES.quick.effort,
      maxTurns: TIER_RECIPES.quick.maxTurns,
      runBudgetUSD: TIER_RECIPES.quick.runBudgetUSD,
      runDeadlineSec: 270,
    });
  });

  it("lets an explicit config value win, since overrides are a dev affordance", () => {
    const { config } = resolveTier({ ...base, tier: "quick", angleCount: 1, rounds: 2, angleModel: "claude-code/haiku" }, {})!;
    expect(config).toMatchObject({ angleCount: 1, rounds: 2, angleModel: "claude-code/haiku" });
  });

  it("gives deep no deadline", () => {
    expect(resolveTier({ ...base, tier: "deep" }, {})!.config.runDeadlineSec).toBeUndefined();
  });

  it("resolves nothing for a run with no tier, leaving the legacy config alone", () => {
    expect(resolveTier(base, {})).toBeUndefined();
  });

  it("scales every time budget with the dev override QUORUM_WALL_SCALE, and nothing else", () => {
    const { recipe } = resolveTier({ ...base, tier: "quick" }, { QUORUM_WALL_SCALE: "0.1" })!;
    expect(recipe.wall!.hardSec).toBeCloseTo(27);
    expect(recipe.wall!.windDownSec).toBeCloseTo(TIER_RECIPES.quick.wall!.windDownSec * 0.1);
    expect(recipe.timeoutSec.research).toBeCloseTo(TIER_RECIPES.quick.timeoutSec.research * 0.1);
    expect(recipe.wall!.tailSec.research).toBeCloseTo(TIER_RECIPES.quick.wall!.tailSec.research * 0.1);
    expect(recipe.angleCount).toBe(TIER_RECIPES.quick.angleCount);
  });

  it("ignores a nonsense scale", () => {
    for (const scale of ["0", "-1", "abc", ""]) {
      expect(resolveTier({ ...base, tier: "quick" }, { QUORUM_WALL_SCALE: scale })!.recipe.wall!.hardSec).toBe(270);
    }
  });
});

describe("the time left, estimated from past runs", () => {
  const medians = { research: 100, draft: 50, check: 30, answer: 5 };

  it("is the rest of the current stage plus every later stage", () => {
    expect(remainingEstimateSec(medians, "research", 40)).toBe(60 + 50 + 30 + 5);
    expect(remainingEstimateSec(medians, "draft", 0)).toBe(50 + 30 + 5);
    expect(remainingEstimateSec(medians, "answer", 0)).toBe(5);
  });

  it("never goes negative when a stage runs past its median, but keeps the stages after it", () => {
    expect(remainingEstimateSec(medians, "research", 500)).toBe(0 + 50 + 30 + 5);
  });
});

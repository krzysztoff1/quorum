import { describe, expect, it } from "vitest";
import { RunWall } from "../src/wall.js";
import { TIER_RECIPES } from "../src/tiers.js";

const quick = TIER_RECIPES.quick;

function wallAt(elapsedSec: number) {
  let clock = 1_000_000;
  const wall = new RunWall(quick.wall!, quick.timeoutSec, clock, () => clock);
  clock += elapsedSec * 1000;
  return wall;
}

describe("the wall clock of a tier", () => {
  it("lets a stage have its full timeout while there is room for everything after it", () => {
    expect(wallAt(0).timeoutMs("research")).toBe(quick.timeoutSec.research * 1000);
    expect(wallAt(10).timeoutMs("synthesis")).toBe(quick.timeoutSec.synthesis * 1000);
  });

  it("clamps a stage's timeout so the stages after it still fit before the wall", () => {
    const late = wallAt(150);
    const room = (quick.wall!.hardSec - 150 - quick.wall!.tailSec.research) * 1000;
    expect(late.timeoutMs("research")).toBe(room);
    expect(late.timeoutMs("research")).toBeLessThan(quick.timeoutSec.research * 1000);
  });

  it("refuses to start a stage that no longer has any room, rather than start it and kill it", () => {
    const late = wallAt(quick.wall!.hardSec - quick.wall!.tailSec.synthesis);
    expect(late.timeoutMs("synthesis")).toBe(0);
    expect(late.canStart("synthesis")).toBe(false);
    expect(late.canStart("validate")).toBe(true);
  });

  it("never reports a negative timeout after the wall", () => {
    expect(wallAt(400).timeoutMs("validate")).toBe(0);
  });

  it("starts winding down before the wall and stops there for optional work only", () => {
    expect(wallAt(quick.wall!.windDownSec - 1).windingDown()).toBe(false);
    expect(wallAt(quick.wall!.windDownSec).windingDown()).toBe(true);
    expect(wallAt(quick.wall!.windDownSec).hardReached()).toBe(false);
  });

  it("reaches the hard wall at its hard second and says how long is left", () => {
    expect(wallAt(quick.wall!.hardSec - 1).hardReached()).toBe(false);
    expect(wallAt(quick.wall!.hardSec).hardReached()).toBe(true);
    expect(wallAt(100).remainingMs()).toBe((quick.wall!.hardSec - 100) * 1000);
    expect(wallAt(999).remainingMs()).toBe(0);
  });
});

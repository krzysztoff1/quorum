import type { TopicRole, WallRecipe } from "./tiers.js";

const MS = 1000;

export class RunWall {
  readonly windDownAt: number;
  readonly hardAt: number;

  constructor(
    private readonly recipe: WallRecipe,
    private readonly timeoutSec: Record<TopicRole, number>,
    startedAt: number,
    private readonly now: () => number,
  ) {
    this.windDownAt = startedAt + recipe.windDownSec * MS;
    this.hardAt = startedAt + recipe.hardSec * MS;
  }

  timeoutMs(role: TopicRole): number {
    const room = this.hardAt - this.now() - this.recipe.tailSec[role] * MS;
    return Math.max(0, Math.min(this.timeoutSec[role] * MS, room));
  }

  canStart(role: TopicRole): boolean {
    return this.timeoutMs(role) > 0;
  }

  windingDown(): boolean {
    return this.now() >= this.windDownAt;
  }

  hardReached(): boolean {
    return this.now() >= this.hardAt;
  }

  remainingMs(): number {
    return Math.max(0, this.hardAt - this.now());
  }
}

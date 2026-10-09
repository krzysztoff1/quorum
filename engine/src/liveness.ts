import type { Emitter } from "./emitter.js";

export const STAGE_COUNT = 5;
export const HEARTBEAT_INTERVAL_MS = 5000;

export type ProgressStage = "research" | "draft" | "check" | "answer";

const STAGES: Record<string, { stage: ProgressStage; stage_index: number }> = {
  planning: { stage: "research", stage_index: 2 },
  researching: { stage: "research", stage_index: 2 },
  synthesizing: { stage: "draft", stage_index: 3 },
  grounding: { stage: "check", stage_index: 4 },
  validating: { stage: "check", stage_index: 4 },
  reconciling: { stage: "check", stage_index: 4 },
  done: { stage: "answer", stage_index: 5 },
};

export function stageForPhase(phase: string): { stage: ProgressStage; stage_index: number } | undefined {
  return STAGES[phase];
}

export interface RunLivenessDeps {
  bus: Emitter;
  pid?: number;
  sourcesRead: () => number;
}

export class RunLiveness {
  private stage: { stage: ProgressStage; stage_index: number } | undefined;
  private tasksDone = 0;
  private tasksTotal = 0;
  private timer: ReturnType<typeof setInterval> | undefined;

  constructor(private readonly deps: RunLivenessDeps) {}

  phase(phase: string): void {
    this.deps.bus.line({ type: "phase", phase });
    const stage = stageForPhase(phase);
    if (!stage) return;
    this.stage = stage;
    this.progress();
  }

  taskQueued(): void {
    this.tasksTotal += 1;
  }

  taskFinished(): void {
    this.tasksDone += 1;
    this.progress();
  }

  start(): void {
    if (this.deps.pid === undefined) return;
    this.timer = setInterval(() => this.beat(), HEARTBEAT_INTERVAL_MS);
    this.timer.unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  private beat(): void {
    this.deps.bus.line({ type: "heartbeat", pid: this.deps.pid });
    this.progress();
  }

  private progress(): void {
    if (!this.stage) return;
    this.deps.bus.line({
      type: "run.progress",
      ...this.stage,
      stage_count: STAGE_COUNT,
      tasks_done: this.tasksDone,
      tasks_total: this.tasksTotal,
      sources_read: this.deps.sourcesRead(),
    });
  }
}

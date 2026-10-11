import { findRun } from "./runStore.js";
import type { RunConfig } from "./run.js";
import type { Brief, Tier } from "./record/schema.js";

export type RunInput = Omit<RunConfig, "kind"> & { kind?: RunConfig["kind"] | "run"; question_id?: string; parent_run_id?: string };

export type ThreadResolution = { ok: true; config: RunConfig } | { ok: false; error: string };

export function normalizeRunInput(input: RunInput): RunConfig {
  const { question_id, parent_run_id, kind, ...rest } = input;
  const config: RunConfig = { ...rest, ...(kind ? { kind: kind === "run" ? "initial" : kind } : {}) };
  const questionId = config.questionId ?? question_id;
  const parentRunId = config.parentRunId ?? parent_run_id;
  return {
    ...config,
    ...(questionId ? { questionId } : {}),
    ...(parentRunId ? { parentRunId } : {}),
  };
}

export function resolveThread(config: RunConfig, storeDir: string | undefined): ThreadResolution {
  const kind = config.kind ?? "initial";
  if (kind === "initial") return { ok: true, config };
  if (!config.parentRunId) return { ok: false, error: `a ${kind} needs parent_run_id, the run it continues` };
  const parent = storeDir ? findRun(storeDir, config.parentRunId) : undefined;
  if (!parent?.record) return { ok: false, error: `no run ${config.parentRunId} in this store to continue` };
  if (config.questionId && config.questionId !== parent.questionId) {
    return { ok: false, error: `run ${config.parentRunId} belongs to question ${parent.questionId}, not ${config.questionId}` };
  }
  const tier: Tier = config.tier ?? config.brief?.tier ?? (kind === "rerun" ? "deep" : "quick");
  const brief: Brief | undefined = config.brief ?? (kind === "rerun" ? { ...parent.record.brief, tier } : undefined);
  return {
    ok: true,
    config: {
      ...config,
      kind,
      questionId: parent.questionId,
      tier,
      question: config.question || brief?.question || "",
      ...(brief ? { brief } : {}),
      priorNotesExcerpt: config.priorNotesExcerpt ?? notesFromParent(parent.record),
    },
  };
}

function notesFromParent(record: any): string {
  const lines = [`The earlier answer to this question (run ${record.id}) said: ${record.answer?.headline ?? "nothing conclusive"}.`];
  const open: string[] = [
    ...(record.validation?.objections_open ?? []).map((o: any) => `an objection stood: ${o.statement} (to settle it: ${o.followup})`),
    ...(record.conflicts ?? []).filter((c: any) => c.status === "open").map((c: any) => `a conflict was unsettled: ${c.statement}`),
    ...(record.gaps ?? []).map((g: any) => `a gap: ${g.text}`),
  ];
  if (open.length > 0) lines.push("Still open from it:", ...open.map((item) => `- ${item}`));
  return lines.join("\n");
}

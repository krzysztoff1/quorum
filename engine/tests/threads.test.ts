import { describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveThread, normalizeRunInput } from "../src/thread.js";
import { openRecording } from "../src/record/store.js";
import { briefFromQuestion } from "../src/record/brief.js";

function storeWithParent(): string {
  const store = mkdtempSync(join(tmpdir(), "quorum-thread-"));
  const questionDir = join(store, "questions", "Q1");
  const runDir = join(questionDir, "runs", "R1");
  mkdirSync(runDir, { recursive: true });
  writeFileSync(join(questionDir, "question.json"), JSON.stringify({
    schema: "quorum.question/1", id: "Q1", created_at: "2026-10-09T10:00:00.000Z", original_text: "ask",
    resolved_text: "What does the AI Act require?", language: "en", title: "AI Act duties", title_source: "scope", run_ids: ["R1"],
  }));
  writeFileSync(join(runDir, "run.json"), JSON.stringify({
    id: "R1", question_id: "Q1", kind: "initial", status: "complete",
    brief: { question: "What does the AI Act require?", asked: "ask", title: "AI Act duties", language: "en", tier: "quick" },
    answer: { headline: "Providers must document their models" },
    conflicts: [{ id: "k1", statement: "Whether fine-tuners count as providers", positions: ["yes", "no"], status: "open", task_id: "t" }],
    gaps: [{ id: "g1", text: "No guidance on open-source exemptions", task_id: "t" }],
    validation: { objections_open: [{ id: "o1", lens: "coverage", statement: "No 2026 dates", severity: "blocking", followup: "find the 2026 application dates" }] },
  }));
  return store;
}

describe("a run that continues a question", () => {
  it("appends to the question instead of replacing it, and records where it came from", () => {
    const store = storeWithParent();
    const recording = openRecording({
      brief: briefFromQuestion("a follow-up"), brainDir: store, ids: { questionId: "Q1", runId: "R2" },
      kind: "followup", parentRunId: "R1", models: { planner: "p", research: "r", synthesis: "s", validator: "v" },
      limits: {}, now: () => 0,
    });
    const question = JSON.parse(readFileSync(join(store, "questions", "Q1", "question.json"), "utf8"));

    expect(question).toMatchObject({ id: "Q1", title: "AI Act duties", original_text: "ask", run_ids: ["R1", "R2"] });
    expect(recording.question.run_ids).toEqual(["R1", "R2"]);
    expect(recording.recorder.fold.snapshot()).toMatchObject({ kind: "followup", parent_run_id: "R1", question_id: "Q1" });
  });

  it("gives a new question exactly its own run", () => {
    const store = mkdtempSync(join(tmpdir(), "quorum-thread-"));
    const recording = openRecording({
      brief: briefFromQuestion("fresh"), brainDir: store, ids: { questionId: "QN", runId: "RN" },
      models: { planner: "p", research: "r", synthesis: "s", validator: "v" }, limits: {}, now: () => 0,
    });
    expect(recording.question.run_ids).toEqual(["RN"]);
    expect(recording.recorder.fold.snapshot().kind).toBe("initial");
  });
});

describe("the input a thread's run arrives with", () => {
  it("reads question_id and parent_run_id as the app spells them", () => {
    expect(normalizeRunInput({ question: "q", question_id: "Q1", parent_run_id: "R1", kind: "rerun" } as any))
      .toMatchObject({ questionId: "Q1", parentRunId: "R1", kind: "rerun" });
  });

  it("prefers the engine's own spelling when both arrive", () => {
    expect(normalizeRunInput({ question: "q", questionId: "A", question_id: "B" } as any).questionId).toBe("A");
  });
});

describe("resolving a follow-up or a Go deeper into a run", () => {
  it("leaves a first run alone", () => {
    const resolved = resolveThread({ question: "q" }, storeWithParent());
    expect(resolved).toEqual({ ok: true, config: { question: "q" } });
  });

  it("needs a parent for a follow-up or a rerun", () => {
    for (const kind of ["followup", "rerun"] as const) {
      expect(resolveThread({ question: "q", kind }, storeWithParent())).toEqual({
        ok: false, error: `a ${kind} needs parent_run_id, the run it continues`,
      });
    }
  });

  it("refuses a parent the store does not have", () => {
    expect(resolveThread({ question: "q", kind: "rerun", parentRunId: "NOPE" }, storeWithParent())).toEqual({
      ok: false, error: "no run NOPE in this store to continue",
    });
  });

  it("refuses a question_id that is not the parent's question", () => {
    const resolved = resolveThread({ question: "q", kind: "followup", parentRunId: "R1", questionId: "OTHER" }, storeWithParent());
    expect(resolved).toMatchObject({ ok: false, error: expect.stringContaining("belongs to question Q1") });
  });

  it("takes a Go deeper from the parent: its question, at Deep, starting from what it left open", () => {
    const resolved = resolveThread({ question: "", kind: "rerun", parentRunId: "R1" }, storeWithParent());
    expect(resolved.ok).toBe(true);
    if (!resolved.ok) return;
    expect(resolved.config).toMatchObject({
      kind: "rerun", parentRunId: "R1", questionId: "Q1", tier: "deep",
      question: "What does the AI Act require?",
      brief: { question: "What does the AI Act require?", title: "AI Act duties", tier: "deep" },
    });
    const notes = resolved.config.priorNotesExcerpt!;
    expect(notes).toContain("Providers must document their models");
    expect(notes).toContain("No 2026 dates");
    expect(notes).toContain("Whether fine-tuners count as providers");
    expect(notes).toContain("No guidance on open-source exemptions");
  });

  it("runs a follow-up at Quick unless it says otherwise, on its own question, with the parent as context", () => {
    const resolved = resolveThread({ question: "And what about fines?", kind: "followup", parentRunId: "R1" }, storeWithParent());
    expect(resolved).toMatchObject({ ok: true, config: { kind: "followup", tier: "quick", questionId: "Q1", question: "And what about fines?" } });
    if (resolved.ok) expect(resolved.config.priorNotesExcerpt).toContain("Providers must document their models");

    const deeper = resolveThread({ question: "q", kind: "followup", parentRunId: "R1", tier: "deep" }, storeWithParent());
    expect(deeper).toMatchObject({ ok: true, config: { tier: "deep" } });
  });

  it("keeps a brief, tier and notes the caller supplied", () => {
    const brief = { question: "scoped", language: "en", tier: "deep" as const };
    const resolved = resolveThread({ question: "scoped", kind: "rerun", parentRunId: "R1", brief, priorNotesExcerpt: "mine" }, storeWithParent());
    expect(resolved).toMatchObject({ ok: true, config: { brief, priorNotesExcerpt: "mine", tier: "deep" } });
  });

  it("resolves to the same thing a second time, so the detached child can run it again", () => {
    const store = storeWithParent();
    const first = resolveThread({ question: "", kind: "rerun", parentRunId: "R1" }, store);
    expect(first.ok).toBe(true);
    if (first.ok) expect(resolveThread(first.config, store)).toEqual(first);
  });
});

describe("a run that continues nothing", () => {
  it.each([undefined, "run", "initial"] as const)("starts fresh when its kind is %s, and is recorded as the initial run", (kind) => {
    const resolved = resolveThread(normalizeRunInput({ question: "q", ...(kind ? { kind } : {}) }), mkdtempSync(join(tmpdir(), "quorum-thread-")));
    expect(resolved).toMatchObject({ ok: true, config: { question: "q" } });
    if (resolved.ok) expect(resolved.config.kind ?? "initial").toBe("initial");
  });

  it("is told it needs a parent when it claims to continue one", () => {
    expect(resolveThread({ question: "q", kind: "followup" }, mkdtempSync(join(tmpdir(), "quorum-thread-")))).toMatchObject({ ok: false, error: expect.stringMatching(/parent_run_id/) });
  });
});


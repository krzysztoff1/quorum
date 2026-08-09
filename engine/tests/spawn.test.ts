import { describe, it, expect } from "vitest";
import { SpawnGate, questionSimilarity, DEFAULT_SPAWN_LIMITS, type SpawnGateDeps } from "../src/spawn.js";

function gate(overrides: Partial<SpawnGateDeps> = {}): SpawnGate {
  let spent = 0;
  return new SpawnGate({
    perTopicBudgetUsd: 10,
    runBudgetUsd: 40,
    synthesisReserveUsd: 10,
    spentUsd: () => spent,
    elapsedFraction: () => 0,
    ...overrides,
  });
}

function seededWithAngles(g: SpawnGate, count = 3): SpawnGate {
  for (let i = 1; i <= count; i++) g.seed(`a${i}`, `angle ${i} about fusion reactors`, 1);
  return g;
}

const ask = { question: "What did the 2024 filing say about renewals?", why: "angle 2 hit a paywall",
              provoked_by: "s3f9a1c2", parent_id: "a1" };

describe("spawn admission — stage 1 machine gates", () => {
  it("admits a well-formed request from a planned angle", () => {
    const g = seededWithAngles(gate());
    const verdict = g.request(ask);

    expect(verdict.verdict).toBe("pending");
    expect(verdict.verdict === "pending" && verdict.inquiry_id).toBeTruthy();
  });

  it("rejects a request with nothing named as its provocation", () => {
    const g = seededWithAngles(gate());
    const verdict = g.request({ ...ask, provoked_by: "" });

    expect(verdict).toMatchObject({ verdict: "rejected" });
    expect(verdict.verdict === "rejected" && verdict.reason).toMatch(/provoked/i);
  });

  it("rejects a request from an unknown parent", () => {
    const verdict = gate().request(ask);

    expect(verdict).toMatchObject({ verdict: "rejected" });
  });

  // depth: L1 angles, L2 spawn, L3 spawn — an L3 inquiry's child would be L4
  it("rejects a spawn that would land below the depth limit", () => {
    const g = gate();
    g.seed("a1", "angle one", 1);
    g.seed("b1", "second generation", 2);
    g.seed("c1", "third generation", 3);

    expect(g.request({ ...ask, parent_id: "b1" })).toMatchObject({ verdict: "pending" });
    expect(g.request({ ...ask, question: "a different thing entirely", parent_id: "c1" }))
      .toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/depth/i) });
  });

  it("rejects a parent's third child", () => {
    const g = seededWithAngles(gate());
    g.approve((g.request({ ...ask, question: "first child question" }) as any).inquiry_id);
    g.approve((g.request({ ...ask, question: "second unrelated child topic" }) as any).inquiry_id);

    expect(g.request({ ...ask, question: "third distinct child subject" }))
      .toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/children|branch/i) });
  });

  it("rejects a question the run is already asking", () => {
    const g = seededWithAngles(gate());
    g.request(ask);

    expect(g.request({ ...ask, question: "What did the 2024 filing say about renewals" }))
      .toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/duplicate/i) });
  });

  it("rejects a question that merely restates a planned angle", () => {
    const g = gate();
    g.seed("a1", "How has fusion breakeven progressed since 2022?", 1);

    expect(g.request({ ...ask, question: "How has fusion breakeven progressed since 2022?" }))
      .toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/duplicate/i) });
  });

  it("rejects once the run already holds its full count of inquiries", () => {
    const g = gate();
    for (let i = 1; i <= DEFAULT_SPAWN_LIMITS.maxInquiriesPerRun; i++) g.seed(`a${i}`, `angle ${i}`, 1);

    expect(g.request(ask)).toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/12|cap|count/i) });
  });

  it("counts still-pending requests against the cap, so approving them all cannot overrun it", () => {
    const g = gate();
    for (let i = 1; i <= 10; i++) g.seed(`a${i}`, `angle ${i}`, 1);
    g.request({ ...ask, question: "first pending question about filings" });
    g.request({ ...ask, question: "second pending question about disclosures" });

    expect(g.request({ ...ask, question: "third pending question about auditors" }))
      .toMatchObject({ verdict: "rejected" });
  });

  it("rejects everything once the run passes its spawn freeze", () => {
    const g = seededWithAngles(gate({ elapsedFraction: () => 0.8 }));

    expect(g.request(ask)).toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/freeze|late/i) });
  });
});

describe("spawn admission — budget", () => {
  it("charges a deeper inquiry a smaller ceiling", () => {
    const g = gate();

    expect(g.ceilingFor(1)).toBe(10);
    expect(g.ceilingFor(2)).toBe(5);
    expect(g.ceilingFor(3)).toBe(2.5);
  });

  /// The reason spawning works at all: reserving three $10 ceilings plus a $10 synthesis commits the whole
  /// $40 before the first angle runs, so a gate reading reservations would refuse every spawn forever.
  it("gates on what the run has actually spent, not on what its angles could spend", () => {
    const g = seededWithAngles(gate({ spentUsd: () => 6 }));

    expect(g.request(ask)).toMatchObject({ verdict: "pending" });
  });

  it("refuses a child the remaining budget cannot cover once the synthesis is reserved", () => {
    const g = seededWithAngles(gate({ spentUsd: () => 34 }));

    expect(g.request(ask)).toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/budget/i) });
  });

  it("counts pending ceilings as committed, so two pending spawns cannot both overdraw", () => {
    const g = seededWithAngles(gate({ spentUsd: () => 22 }));

    expect(g.request({ ...ask, question: "first question about the filing" })).toMatchObject({ verdict: "pending" });
    expect(g.request({ ...ask, question: "second question about the auditor" }))
      .toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/budget/i) });
  });
});

describe("pending lifecycle", () => {
  it("an approved request becomes an inquiry that counts against its parent and the run", () => {
    const g = seededWithAngles(gate());
    const id = (g.request(ask) as any).inquiry_id;
    const approved = g.approve(id);

    expect(approved?.question).toBe(ask.question);
    expect(g.inquiryCount()).toBe(4);
    expect(g.childCount("a1")).toBe(1);
  });

  it("a rejected request frees the slot it was holding", () => {
    const g = seededWithAngles(gate());
    const id = (g.request(ask) as any).inquiry_id;
    g.reject(id);

    expect(g.inquiryCount()).toBe(3);
    expect(g.pendingCount()).toBe(0);
  });

  it("approving the same request twice does not double count it", () => {
    const g = seededWithAngles(gate());
    const id = (g.request(ask) as any).inquiry_id;
    g.approve(id);

    expect(g.approve(id)).toBeUndefined();
    expect(g.inquiryCount()).toBe(4);
  });

  it("the freeze expires everything still pending so the run can synthesize", () => {
    const g = seededWithAngles(gate());
    g.request({ ...ask, question: "first question about the filing" });
    g.request({ ...ask, question: "second question about the auditor", parent_id: "a2" });

    const expired = g.expirePending();

    expect(expired.map((p) => p.question)).toEqual([
      "first question about the filing",
      "second question about the auditor",
    ]);
    expect(g.pendingCount()).toBe(0);
  });

  it("auto mode approves what stage 1 admits, with no human in the loop", () => {
    const g = seededWithAngles(gate({ mode: "auto" }));
    const verdict = g.request(ask);

    expect(verdict).toMatchObject({ verdict: "approved" });
    expect(g.inquiryCount()).toBe(4);
    expect(g.pendingCount()).toBe(0);
  });

  it("off mode refuses to spawn at all", () => {
    const g = seededWithAngles(gate({ mode: "off" }));

    expect(g.request(ask)).toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/off|disabled/i) });
  });
});

describe("question similarity", () => {
  it("scores a restatement high and an unrelated question low", () => {
    expect(questionSimilarity("What did the 2024 filing say about renewals?",
                              "What did the 2024 filing say about renewals")).toBeGreaterThan(0.9);
    expect(questionSimilarity("How much did revenue grow?",
                              "Who sits on the audit committee?")).toBeLessThan(0.3);
  });

  it("ignores filler words so two phrasings of one question still collide", () => {
    expect(questionSimilarity("What is the effect of the tariff on prices?",
                              "Effect of tariffs on prices")).toBeGreaterThan(0.6);
  });

  it("treats two empty questions as unrelated rather than identical", () => {
    expect(questionSimilarity("", "")).toBe(0);
  });
});

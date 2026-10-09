import { describe, it, expect } from "vitest";
import { AdmissionGate, questionSimilarity, DEFAULT_ADMISSION_LIMITS, type AdmissionGateDeps } from "../src/admission.js";

function gate(overrides: Partial<AdmissionGateDeps> = {}): AdmissionGate {
  return new AdmissionGate({
    perTopicBudgetUsd: 10,
    runBudgetUsd: 40,
    synthesisReserveUsd: 10,
    spentUsd: () => 0,
    elapsedFraction: () => 0,
    ...overrides,
  });
}

function seededWithAngles(g: AdmissionGate, count = 3): AdmissionGate {
  g.seed("root", "the question", 0);
  for (let i = 1; i <= count; i++) g.seed(`a${i}`, `angle ${i} about fusion reactors`, 1);
  return g;
}

const objection = {
  question: "What did the 2024 filing say about renewals?",
  why: "the coverage critic found no source for renewals",
  provoked_by: "coverage",
  parent_id: "root",
};

describe("objection admission, machine gates", () => {
  it("admits a well-formed follow-up under the question and counts it", () => {
    const g = seededWithAngles(gate());
    const verdict = g.admit(objection);

    expect(verdict.verdict).toBe("approved");
    expect(verdict.verdict === "approved" && verdict.inquiry.depth).toBe(1);
    expect(g.inquiryCount()).toBe(5);
  });

  it("rejects a follow-up under a parent it has never heard of", () => {
    expect(gate().admit({ ...objection, parent_id: "missing" })).toMatchObject({ verdict: "rejected" });
  });

  it("rejects a follow-up without a question", () => {
    const g = seededWithAngles(gate());

    expect(g.admit({ ...objection, question: "  " })).toMatchObject({ verdict: "rejected" });
  });

  it("rejects a follow-up that would land below the depth limit", () => {
    const g = gate();
    g.seed("a1", "angle one", 1);
    g.seed("b1", "second generation", 2);
    g.seed("c1", "third generation", 3);

    expect(g.admit({ ...objection, parent_id: "b1" })).toMatchObject({ verdict: "approved" });
    expect(g.admit({ ...objection, question: "a different thing entirely", parent_id: "c1" }))
      .toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/depth/i) });
  });

  it("rejects a question the run is already asking", () => {
    const g = seededWithAngles(gate());
    g.admit(objection);

    expect(g.admit({ ...objection, question: "What did the 2024 filing say about renewals" }))
      .toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/duplicate/i) });
  });

  it("rejects a question that merely restates a planned angle", () => {
    const g = gate();
    g.seed("root", "the question", 0);
    g.seed("a1", "How has fusion breakeven progressed since 2022?", 1);

    expect(g.admit({ ...objection, question: "How has fusion breakeven progressed since 2022?" }))
      .toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/duplicate/i) });
  });

  it("rejects once the run already holds its full count of inquiries", () => {
    const g = gate();
    g.seed("root", "the question", 0);
    for (let i = 1; i <= DEFAULT_ADMISSION_LIMITS.maxInquiriesPerRun; i++) g.seed(`a${i}`, `angle ${i}`, 1);

    expect(g.admit(objection)).toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/12|cap|count/i) });
  });

  it("rejects everything once the run passes its freeze", () => {
    const g = seededWithAngles(gate({ elapsedFraction: () => 0.8 }));

    expect(g.admit(objection)).toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/freeze/i) });
    expect(g.frozen()).toBe(true);
  });
});

describe("objection admission, budget", () => {
  it("charges a deeper inquiry a smaller ceiling", () => {
    const g = gate();

    expect(g.ceilingFor(1)).toBe(10);
    expect(g.ceilingFor(2)).toBe(5);
    expect(g.ceilingFor(3)).toBe(2.5);
  });

  it("gates on what the run has actually spent, not on what its angles could spend", () => {
    const g = seededWithAngles(gate({ spentUsd: () => 6 }));

    expect(g.admit(objection)).toMatchObject({ verdict: "approved" });
  });

  it("refuses a follow-up the remaining budget cannot cover once the synthesis is reserved", () => {
    const g = seededWithAngles(gate({ spentUsd: () => 34 }));

    expect(g.admit(objection)).toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/budget/i) });
  });

  it("refuses a follow-up that would leave the validation reserve unfunded", () => {
    const spent = { usd: 24 };
    const g = seededWithAngles(gate({ spentUsd: () => spent.usd, validationReserveUsd: 6 }));

    expect(g.admit(objection)).toMatchObject({ verdict: "rejected", reason: expect.stringMatching(/validation/i) });
    spent.usd = 12;
    expect(g.admit(objection)).toMatchObject({ verdict: "approved" });
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

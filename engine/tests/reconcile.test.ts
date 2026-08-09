import { describe, it, expect } from "vitest";
import { divergedAcrossRounds, reconciliationContext } from "../src/reconcile.js";
import type { ValidationRound } from "../src/validate.js";

function round(body: string, summary: Record<string, unknown> = {}): string {
  const fenced = {
    headline: "Round headline", status: "complete", sourcesConsulted: 1,
    findings: [], conflicts: [], gaps: [], ...summary,
  };
  return `${body}\n\n\`\`\`json\n${JSON.stringify(fenced)}\n\`\`\``;
}

function finding(claim: string) {
  return { claim, sources: ["https://example.org"], confidence: "high" };
}

describe("whether a dive needs fusing at all", () => {
  it("reads one round as nothing to reconcile", () => {
    expect(divergedAcrossRounds([round("Only pass", { findings: [finding("a")] })])).toBe(false);
  });

  it("fuses when a round surfaced a conflict", () => {
    const rounds = [
      round("First", { findings: [finding("a")], conflicts: [{ claim: "a", positions: ["x", "y"] }] }),
      round("Second", { findings: [finding("a")] }),
    ];
    expect(divergedAcrossRounds(rounds)).toBe(true);
  });

  it("fuses when a later round introduced a claim no earlier round carried", () => {
    const rounds = [
      round("First", { findings: [finding("fusion has not reached the grid")] }),
      round("Second", { findings: [finding("one plant is scheduled for 2035")] }),
    ];
    expect(divergedAcrossRounds(rounds)).toBe(true);
  });

  it("leaves rounds that only restated each other alone, so the fuse is never pure reformatting", () => {
    const rounds = [
      round("First", { findings: [finding("Fusion has not reached the grid")] }),
      round("Second", { findings: [finding("fusion has not reached the grid ")] }),
    ];
    expect(divergedAcrossRounds(rounds)).toBe(false);
  });

  it("reads an unreadable round as divergence rather than assuming agreement", () => {
    expect(divergedAcrossRounds(["no fenced summary at all", round("Second", { findings: [finding("a")] })]))
      .toBe(true);
  });
});

describe("what the reconciler is given", () => {
  const judged: ValidationRound = {
    round: 1, sweep: "run", critics: "run", claims_found: 1, claims_checked: 1,
    verdicts: [], discarded_objections: 0, holds: false,
    objections: [{ lens: "coverage", statement: "the answer never states 2025 pricing",
                   severity: "blocking", followup: "find the 2025 pricing page" }],
  };

  const context = () => reconciliationContext("Where does fusion energy stand?", [
    { synthesis: round("Round one said X.\n\n## Validation\n\nfiled, not fixed",
                       { headline: "First pass", findings: [finding("X holds")] }),
      validation: judged },
    { synthesis: round("Round two corrected it to Y.", { headline: "Second pass", findings: [finding("Y holds")] }) },
  ]);

  it("hands it every round in order, as rounds and not as siblings", () => {
    const s = context();
    expect(s).toContain("Where does fusion energy stand?");
    expect(s).toContain("ROUND 1: First pass");
    expect(s).toContain("ROUND 2: Second pass");
    expect(s.indexOf("ROUND 1")).toBeLessThan(s.indexOf("ROUND 2"));
    expect(s).toContain("Round one said X.");
    expect(s).toContain("Round two corrected it to Y.");
  });

  it("asks for the standing answer rather than a log of what each round believed", () => {
    expect(context()).toMatch(/one clean current answer/i);
    expect(context()).toMatch(/superseded/i);
  });

  it("carries what the validators filed, so a fused answer cannot bury a standing objection", () => {
    expect(context()).toContain("the answer never states 2025 pricing");
  });

  it("leaves the apparatus the run appended out of the material it reads", () => {
    expect(context()).not.toContain("filed, not fixed");
  });
});

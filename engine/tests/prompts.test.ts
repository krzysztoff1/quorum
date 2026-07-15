import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  RESEARCH_SYSTEM_PROMPT,
  SYNTHESIS_SYSTEM_PROMPT,
  VERIFY_SYSTEM_PROMPT,
  templateInstructions,
  synthesisWordBudget,
} from "../src/systemPrompt.js";
import { buildSynthesisContext } from "../src/run.js";
import type { TopicOutcome } from "../src/backend.js";

const contract = JSON.parse(
  readFileSync(join(import.meta.dirname, "..", "..", "Tests", "QuorumCoreTests", "Fixtures", "prompt-contract.json"), "utf8")
);

function researchTopic(id: string, body: string, sources: string[]): TopicOutcome {
  const summary = {
    headline: `h-${id}`, status: "complete", sourcesConsulted: sources.length,
    findings: [{ claim: `claim ${id}`, sources, confidence: "high" }],
  };
  return {
    angle_id: id, role: "research", backend: "engine", provider: "deepseek", model: "deepseek-chat",
    session_id: `qeng-${id}`, status: "complete",
    result: `${body}\n\n\`\`\`json\n${JSON.stringify(summary)}\n\`\`\``,
    usage: {
      provider: "deepseek", model: "deepseek-chat", input_tokens: 0, output_tokens: 0,
      cache_read_tokens: 0, cache_write_tokens: 0, cost_usd: 0, search_calls: 0, fetch_calls: 0,
    },
    note: null,
  };
}

describe("prompt contract shared with the Swift ResearchPrompts (Tests/QuorumCoreTests/Fixtures/prompt-contract.json)", () => {
  it("research system prompt carries the contract fragments", () => {
    for (const fragment of contract.research) expect(RESEARCH_SYSTEM_PROMPT).toContain(fragment);
  });

  it("synthesis system prompt carries the contract fragments", () => {
    for (const fragment of contract.synthesis) expect(SYNTHESIS_SYSTEM_PROMPT).toContain(fragment);
  });

  it("verify system prompt carries the contract fragments", () => {
    for (const fragment of contract.verify) expect(VERIFY_SYSTEM_PROMPT).toContain(fragment);
  });

  it("template instructions match the Swift synthesisInstructions shapes", () => {
    expect(templateInstructions("general")).toBe("");
    expect(templateInstructions(undefined)).toBe("");
    for (const [name, fragment] of Object.entries(contract.templates)) {
      expect(templateInstructions(name)).toContain(fragment as string);
    }
  });

  it("the synthesis word budget matches the Swift formula", () => {
    for (const [count, budget] of Object.entries(contract.wordBudget)) {
      expect(synthesisWordBudget(Number(count))).toBe(budget);
    }
  });
});

describe("buildSynthesisContext (port of the Swift synthesisContext)", () => {
  it("bounds each angle to findings plus a trimmed excerpt and carries the scaled word budget", () => {
    const long = "x".repeat(5000);
    const topics = [
      researchTopic("a1", long, ["https://shared.example/paper"]),
      researchTopic("a2", "short body", ["https://shared.example/paper", "https://solo.example"]),
    ];
    const ctx = buildSynthesisContext("Q?", topics, "general");
    for (const fragment of contract.synthesisContext) expect(ctx).toContain(fragment);
    expect(ctx).toContain("under ~900 words");
    expect(ctx).toContain("claim a1");
    expect(ctx).toContain("…(truncated)");
    expect(ctx).not.toContain("x".repeat(1600));
  });

  it("lists only sources cited by more than one angle as corroboration", () => {
    const topics = [
      researchTopic("a1", "b1", ["https://shared.example/paper"]),
      researchTopic("a2", "b2", ["https://shared.example/paper/", "https://solo.example"]),
    ];
    const ctx = buildSynthesisContext("Q?", topics, "general");
    expect(ctx).toContain("2 of 2 angles");
    expect(ctx).not.toContain("https://solo.example — 1");
  });

  it("injects the template shape for non-general templates", () => {
    const topics = [researchTopic("a1", "b", ["https://s.example"])];
    const ctx = buildSynthesisContext("Q?", topics, "comparisonMatrix");
    expect(ctx).toContain("COMPARISON MATRIX");
    expect(buildSynthesisContext("Q?", topics, "general")).not.toContain("COMPARISON MATRIX");
  });
});

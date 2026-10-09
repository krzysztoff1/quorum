import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  RESEARCH_SYSTEM_PROMPT,
  SYNTHESIS_SYSTEM_PROMPT,
  VERIFY_SYSTEM_PROMPT,
  templateInstructions,
  synthesisWordBudget,
  answerLanguage,
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
  it("tells an angle to answer in the language of the user's original question, word for word as Swift does", () => {
    expect(answerLanguage(contract.answerLanguage.question)).toBe(contract.answerLanguage.line);
  });

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

describe("evidence contract (PRD 03): a marker per sourced sentence, a verbatim quote per marker", () => {
  it("research prompt asks for markers backed by character-for-character quotes against a fetched source", () => {
    expect(RESEARCH_SYSTEM_PROMPT).toContain("[^c1]");
    expect(RESEARCH_SYSTEM_PROMPT).toContain("source_id");
    expect(RESEARCH_SYSTEM_PROMPT).toContain("10–300 characters character-for-character");
    expect(RESEARCH_SYSTEM_PROMPT).toContain('"citations":[{"id":"c1","source":"s3","quote":');
    expect(RESEARCH_SYSTEM_PROMPT).toContain('"citations":["c1"]');
    expect(RESEARCH_SYSTEM_PROMPT).toContain("paraphrase makes the claim unverifiable");
  });

  it("research prompt keeps the writeup and findings contract it already had", () => {
    expect(RESEARCH_SYSTEM_PROMPT).toContain('{"headline":"one-line takeaway","status":"complete|inconclusive","sourcesConsulted":<int>,"findings":[{"claim":"...","sources":["url"],"confidence":"high|medium|low|unverified"}],"note":"optional one-line caveat"}');
    expect(RESEARCH_SYSTEM_PROMPT).toContain('"## Sources"');
  });

  it("synthesis prompt reuses the globally-unique ids it is handed instead of renumbering them", () => {
    expect(SYNTHESIS_SYSTEM_PROMPT).toContain("[^a2c1]");
    expect(SYNTHESIS_SYSTEM_PROMPT).toContain("REUSE the citation ids");
    expect(SYNTHESIS_SYSTEM_PROMPT).toContain("A reused id is already verified");
    expect(SYNTHESIS_SYSTEM_PROMPT).toContain('"citations":[{"id":"a2c1","source":"s3","quote":');
    expect(SYNTHESIS_SYSTEM_PROMPT).toContain('"conflicts":[{"claim":"the disputed point"');
  });

  it("verify prompt stays about untraceable urls — quotes are checked by string search, not by a model", () => {
    expect(VERIFY_SYSTEM_PROMPT).toContain("You are a citation checker.");
    expect(VERIFY_SYSTEM_PROMPT).toContain("each cited URL must appear in the provided source list");
    expect(VERIFY_SYSTEM_PROMPT).not.toContain("quote");
  });

  it("verify prompt requires the pass that rewrites a claim to carry that claim's markers with it", () => {
    expect(VERIFY_SYSTEM_PROMPT).toContain("Carry every finding's markers");
    expect(VERIFY_SYSTEM_PROMPT).toContain('"citations":["a2c1"]');
    expect(VERIFY_SYSTEM_PROMPT).toContain("never an id you were not given");
  });
});

describe("buildSynthesisContext (port of the Swift synthesisContext)", () => {
  it("leads with every angle's findings, carries the writeups whole, and scales the word budget", () => {
    const long = "x".repeat(5000);
    const topics = [
      researchTopic("a1", long, ["https://shared.example/paper"]),
      researchTopic("a2", "short body", ["https://shared.example/paper", "https://solo.example"]),
    ];
    const ctx = buildSynthesisContext("Q?", topics, "general");
    for (const fragment of contract.synthesisContext) expect(ctx).toContain(fragment);
    expect(ctx).toContain("under ~900 words");
    expect(ctx).toContain("claim a1");
    expect(ctx).toContain(long);
    expect(ctx).not.toContain("truncated");
    expect(ctx.indexOf("claim a2"), "the findings of every angle come before any writeup")
      .toBeLessThan(ctx.indexOf(long));
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

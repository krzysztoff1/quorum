import { describe, it, expect } from "vitest";
import {
  RESEARCH_SYSTEM_PROMPT,
  SYNTHESIS_SYSTEM_PROMPT,
  VERIFY_SYSTEM_PROMPT,
  templateInstructions,
  synthesisWordBudget,
  answerLanguage,
  planSystemPrompt,
  scopeSystemPrompt,
} from "../src/systemPrompt.js";
import { buildSynthesisContext } from "../src/run.js";
import type { TopicOutcome } from "../src/backend.js";


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

const RESEARCH_FRAGMENTS = [
  "You are an unattended research engine.",
  "Write in the language the question is written in",
  "A revenue, ROI, market-size or growth figure must come from a primary disclosure",
  "Name a source by the site you actually fetched it from, never by a brand named inside the text",
  "Source quality matters more than search rank: prefer primary and authoritative sources",
  "Trust is the product. A claim you cannot corroborate must be marked \"unverified\" or dropped",
  "keep it focused and under ~700 words",
  "Cite at the sentence level.",
  "copy 10–300 characters character-for-character out of its text",
  "Quotes are checked by string search against the stored copy of the page",
  "Only cite a page you actually fetched",
  "{\"headline\":\"one-line takeaway\",\"status\":\"complete|inconclusive\",\"sourcesConsulted\":<int>,\"findings\":[{\"claim\":\"...\",\"sources\":[\"url\"],\"confidence\":\"high|medium|low|unverified\"}],\"note\":\"optional one-line caveat\"}",
  "\"citations\":[{\"id\":\"c1\",\"source\":\"s3\",\"quote\":\"10–300 characters copied character-for-character from s3\"}]"
];

const SYNTHESIS_FRAGMENTS = [
  "You are a synthesis engine, given several INDEPENDENT research writeups",
  "Write in the language the question is written in",
  "Reconcile them into ONE cited answer",
  "Write to be SKIMMED — clarity is judged. Open with the direct answer",
  "Put a comparison in EITHER a table OR prose",
  "Record conflicts and gaps in the JSON below",
  "Cite at the sentence level, and REUSE the citation ids you are handed.",
  "keep such an id exactly as given",
  "A reused id is already verified against the stored source; renumbering it throws that away.",
  "{\"headline\":\"one-line takeaway\",\"status\":\"complete|inconclusive\",\"sourcesConsulted\":<int>,\"findings\":[{\"claim\":\"...\",\"sources\":[\"url\"],\"confidence\":\"high|medium|low|unverified\"}],\"conflicts\":[{\"claim\":\"the disputed point\",\"positions\":[\"angle 1: says X\",\"angle 3: says Y\"]}],\"gaps\":[\"specific unresolved question worth another round\",\"...\"],\"note\":\"optional one-line caveat\"}"
];

const VERIFY_FRAGMENTS = [
  "You are a citation checker.",
  "If a citation is not in the list, drop it.",
  "Carry every finding's markers back unchanged.",
  "repeat exactly the ids you were given for that claim, never an id you were not given",
  "{\"findings\":[{\"claim\":\"...\",\"sources\":[\"url\"],\"citations\":[\"a2c1\"],\"confidence\":\"high|medium|low|unverified\"}]}"
];

const SYNTHESIS_CONTEXT_FRAGMENTS = [
  "INDEPENDENT research writeups, each investigating a different angle of the same question. They did not see each other.",
  "Keep the full writeup under ~",
  "Sources multiple angles independently cited (more angles = better corroborated):",
  "Findings (claim · confidence · sources):"
];

const TEMPLATE_FRAGMENTS: Record<string, string> = {
  "comparisonMatrix": "Shape the answer as a COMPARISON MATRIX.",
  "decisionBrief": "Shape the answer as a DECISION BRIEF, recommendation-first.",
  "litReview": "Shape the answer as a LITERATURE REVIEW, organized by THEME (not by angle)."
};

const WORD_BUDGETS: Record<string, number> = {
  "2": 900,
  "5": 1200,
  "8": 1500,
  "20": 1500
};

const POLISH_QUESTION = "Zrób reaserch systemów personalizacji w food tech";
const POLISH_LANGUAGE_LINE = "Write your report — headline, prose, every claim and every gap — in the language of the user's original question, even where this prompt or your sources use another language. The user asked: «Zrób reaserch systemów personalizacji w food tech»";

describe("the one prompt set", () => {
  it("tells an angle to answer in the language of the user's original question", () => {
    expect(answerLanguage(POLISH_QUESTION)).toBe(POLISH_LANGUAGE_LINE);
  });

  it("research system prompt carries its fragments", () => {
    for (const fragment of RESEARCH_FRAGMENTS) expect(RESEARCH_SYSTEM_PROMPT).toContain(fragment);
  });

  it("synthesis system prompt carries its fragments", () => {
    for (const fragment of SYNTHESIS_FRAGMENTS) expect(SYNTHESIS_SYSTEM_PROMPT).toContain(fragment);
  });

  it("verify system prompt carries its fragments", () => {
    for (const fragment of VERIFY_FRAGMENTS) expect(VERIFY_SYSTEM_PROMPT).toContain(fragment);
  });

  it("template instructions shape the deliverable", () => {
    expect(templateInstructions("general")).toBe("");
    expect(templateInstructions(undefined)).toBe("");
    for (const [name, fragment] of Object.entries(TEMPLATE_FRAGMENTS)) {
      expect(templateInstructions(name)).toContain(fragment);
    }
  });

  it("the synthesis word budget grows with the angle count and stops at a ceiling", () => {
    for (const [count, budget] of Object.entries(WORD_BUDGETS)) {
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

describe("buildSynthesisContext", () => {
  it("leads with every angle's findings, carries the writeups whole, and scales the word budget", () => {
    const long = "x".repeat(5000);
    const topics = [
      researchTopic("a1", long, ["https://shared.example/paper"]),
      researchTopic("a2", "short body", ["https://shared.example/paper", "https://solo.example"]),
    ];
    const ctx = buildSynthesisContext("Q?", topics, "general");
    for (const fragment of SYNTHESIS_CONTEXT_FRAGMENTS) expect(ctx).toContain(fragment);
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

describe("the don't-ask contract (M7)", () => {
  const FIXED_SCOPE = "The scope is fixed and nobody is there to answer. Never ask the user a question, never ask for clarification, never offer options to choose from";
  const STATE_ASSUMPTION = "state the assumption you are making in one line and carry on";

  it("is carried by the research, synthesis and planning prompts", () => {
    for (const prompt of [RESEARCH_SYSTEM_PROMPT, SYNTHESIS_SYSTEM_PROMPT, planSystemPrompt(3)]) {
      expect(prompt).toContain(FIXED_SCOPE);
      expect(prompt).toContain(STATE_ASSUMPTION);
    }
  });

  it("names the language code beside the question when it is known", () => {
    expect(answerLanguage(POLISH_QUESTION, "pl")).toBe(`${POLISH_LANGUAGE_LINE} The language code is "pl".`);
    expect(answerLanguage(POLISH_QUESTION, "und")).toBe(POLISH_LANGUAGE_LINE);
  });
});

describe("the scoping prompts", () => {
  it("scope the question in the user's language without researching", () => {
    const prompt = scopeSystemPrompt(false);
    expect(prompt).toContain("You scope research questions");
    expect(prompt).toContain("same language as the user's question");
    expect(prompt).toContain("use no tools");
    expect(prompt).toContain("at most 3");
  });

  it("forbid a further question on the second call", () => {
    expect(scopeSystemPrompt(true)).toContain("Do not ask anything further");
    expect(scopeSystemPrompt(true)).not.toContain("at most 3");
  });
});

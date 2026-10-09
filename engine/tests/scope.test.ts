import { describe, expect, it } from "vitest";
import { scopeQuestion, type ModelReply, type ScopeDeps } from "../src/scope.js";

function model(...replies: (ModelReply | object)[]): { deps: ScopeDeps; requests: { system: string; prompt: string }[] } {
  const requests: { system: string; prompt: string }[] = [];
  const queue = [...replies];
  return {
    requests,
    deps: {
      askModel: async (request) => {
        requests.push(request);
        const next = queue.shift();
        if (!next) throw new Error("the scoper was asked more often than the test scripted");
        return "ok" in next ? (next as ModelReply) : { ok: true, text: "```json\n" + JSON.stringify(next) + "\n```" };
      },
    },
  };
}

const CLEAR_ENGLISH = {
  clear: true,
  resolved: "What do the EU AI Act's obligations for general-purpose AI models require, and from when do they apply?",
  title: "EU AI Act obligations for general-purpose AI",
  language: "en",
  tier: "quick",
  tier_reason: "A single, well-bounded regulatory question.",
};

describe("scope: a clear question", () => {
  it("returns the brief at once, with no questions", async () => {
    const { deps } = model(CLEAR_ENGLISH);

    const scoped = await scopeQuestion({ question: "What does the EU AI Act require of GPAI models and from when?" }, deps);

    expect(scoped).toEqual({
      needs_scoping: false,
      brief: {
        asked: "What does the EU AI Act require of GPAI models and from when?",
        question: CLEAR_ENGLISH.resolved,
        title: "EU AI Act obligations for general-purpose AI",
        language: "en",
        tier: "quick",
        suggested_tier: "quick",
        tier_reason: "A single, well-bounded regulatory question.",
        clarifications: [],
      },
    });
  });

  it("carries a typo-corrected resolved question while keeping the user's own words as asked", async () => {
    const { deps } = model({ ...CLEAR_ENGLISH, resolved: "What is the difference between Bun and Node?", title: "Bun versus Node" });

    const scoped = await scopeQuestion({ question: "waht is the diffrence between bun and node" }, deps);

    expect(scoped.brief).toMatchObject({ asked: "waht is the diffrence between bun and node", question: "What is the difference between Bun and Node?" });
  });

  it("recommends Deep, with the reason, when the model says so", async () => {
    const { deps } = model({ ...CLEAR_ENGLISH, tier: "deep", tier_reason: "Covers several markets and needs conflicting sources reconciled." });

    const scoped = await scopeQuestion({ question: "Compare the EU, US and UK approaches to regulating foundation models" }, deps);

    expect(scoped.brief).toMatchObject({
      tier: "deep",
      suggested_tier: "deep",
      tier_reason: "Covers several markets and needs conflicting sources reconciled.",
    });
  });

  it("falls back to Quick for a tier it does not know", async () => {
    const { deps } = model({ ...CLEAR_ENGLISH, tier: "wide" });

    expect((await scopeQuestion({ question: "anything" }, deps)).brief.tier).toBe("quick");
  });
});

describe("scope: language", () => {
  const POLISH = {
    clear: true,
    resolved: "Jakie wymagania RODO dotyczą danych o zdrowiu i diecie w aplikacjach do zamawiania posiłków?",
    title: "RODO a dane o zdrowiu w aplikacjach do posiłków",
    language: "pl",
    tier: "quick",
    tier_reason: "Jedno, dobrze określone pytanie prawne.",
  };

  it("keeps a Polish question Polish all the way to the title", async () => {
    const { deps } = model(POLISH);

    const scoped = await scopeQuestion({ question: "Jakie wymagania RODO dotyczą danych o zdrowiu i diecie w aplikacjach?" }, deps);

    expect(scoped.brief).toMatchObject({ language: "pl", title: POLISH.title, tier_reason: POLISH.tier_reason });
  });

  it("tells the model to answer, ask and title in the question's language", async () => {
    const { deps, requests } = model(POLISH);

    await scopeQuestion({ question: "Jakie wymagania RODO dotyczą danych o zdrowiu?" }, deps);

    expect(requests[0]!.system).toMatch(/same language as the user's question/i);
    expect(requests[0]!.system).toMatch(/title/i);
    expect(requests[0]!.prompt).toContain("Jakie wymagania RODO dotyczą danych o zdrowiu?");
  });

  it("reads the language off the question when the model names one that is not a language code", async () => {
    const { deps } = model({ ...POLISH, language: "Polish (pl-PL)" });

    const scoped = await scopeQuestion({ question: "Jakie wymagania RODO dotyczą danych o zdrowiu i diecie w aplikacjach?" }, deps);

    expect(scoped.brief.language).toBe("pl");
  });
});

describe("scope: a vague question", () => {
  const VAGUE = {
    clear: false,
    resolved: "Jak działa blockchain i do czego się go używa?",
    title: "Blockchain: jak działa i do czego służy",
    language: "pl",
    tier: "quick",
    tier_reason: "Pytanie ogólne.",
    questions: [
      {
        id: "angle",
        text: "Który aspekt Cię interesuje?",
        multi: false,
        options: ["Technologia", "Zastosowania w biznesie", "Regulacje"],
      },
      { id: "depth", text: "Jak bardzo szczegółowo?", multi: false, options: ["Przegląd", "Szczegóły techniczne"] },
    ],
  };

  it("asks the clarifying questions, in order, with numbered options, and proposes a brief", async () => {
    const { deps } = model(VAGUE);

    const scoped = await scopeQuestion({ question: "blockchain" }, deps);

    expect(scoped.needs_scoping).toBe(true);
    expect(scoped.questions).toEqual([
      {
        id: "angle",
        text: "Który aspekt Cię interesuje?",
        multi: false,
        options: [
          { id: "1", label: "Technologia" },
          { id: "2", label: "Zastosowania w biznesie" },
          { id: "3", label: "Regulacje" },
        ],
      },
      {
        id: "depth",
        text: "Jak bardzo szczegółowo?",
        multi: false,
        options: [{ id: "1", label: "Przegląd" }, { id: "2", label: "Szczegóły techniczne" }],
      },
    ]);
    expect(scoped.brief).toMatchObject({ asked: "blockchain", question: VAGUE.resolved, language: "pl", clarifications: [] });
  });

  it("never asks more than three questions of at most four options each", async () => {
    const many = Array.from({ length: 6 }, (_, i) => ({
      id: `q${i}`, text: `Question ${i}?`, multi: false, options: ["a", "b", "c", "d", "e", "f"],
    }));
    const { deps } = model({ ...VAGUE, questions: many });

    const scoped = await scopeQuestion({ question: "ai" }, deps);

    expect(scoped.questions).toHaveLength(3);
    expect(scoped.questions!.every((q) => q.options.length === 4)).toBe(true);
  });

  it("treats a vague verdict with no usable question as clear", async () => {
    const { deps } = model({ ...VAGUE, questions: [{ id: "q", text: "", options: [] }] });

    const scoped = await scopeQuestion({ question: "blockchain" }, deps);

    expect(scoped.needs_scoping).toBe(false);
  });
});

describe("scope: the second call", () => {
  const ANSWERED = {
    clear: true,
    resolved: "Jak technicznie działa blockchain, w przeglądzie?",
    title: "Blockchain: przegląd techniczny",
    language: "pl",
    tier: "quick",
    tier_reason: "Wąski, przeglądowy temat.",
  };

  it("folds the answers into the brief and records them as clarifications", async () => {
    const { deps, requests } = model(ANSWERED);
    const clarifications = [
      { question: "Który aspekt Cię interesuje?", answer: "Technologia" },
      { question: "Jak bardzo szczegółowo?", answer: "Przegląd" },
    ];

    const scoped = await scopeQuestion({ question: "blockchain", clarifications }, deps);

    expect(scoped.needs_scoping).toBe(false);
    expect(scoped.brief).toMatchObject({ asked: "blockchain", question: ANSWERED.resolved, clarifications });
    expect(requests[0]!.prompt).toContain("Technologia");
    expect(requests[0]!.system).toMatch(/do not ask/i);
  });

  it("never opens a third round: a model that asks again still produces a brief", async () => {
    const { deps } = model({ ...ANSWERED, clear: false, questions: [{ id: "q", text: "Jeszcze coś?", options: ["a", "b"] }] });

    const scoped = await scopeQuestion({ question: "blockchain", clarifications: [{ question: "?", answer: "Technologia" }] }, deps);

    expect(scoped.needs_scoping).toBe(false);
    expect(scoped.questions).toBeUndefined();
  });
});

describe("scope: follow-ups", () => {
  it("default to Quick even when the model recommends Deep", async () => {
    const { deps } = model({ ...CLEAR_ENGLISH, tier: "deep", tier_reason: "Broad." });

    const scoped = await scopeQuestion({ question: "And what about fines?", parent_run_id: "R1" }, deps);

    expect(scoped.brief).toMatchObject({ tier: "quick", suggested_tier: "quick" });
  });
});

describe("scope: titles", () => {
  it("replaces a title that is a clarifier with one taken from the question", async () => {
    const { deps } = model({ ...CLEAR_ENGLISH, resolved: "Is Bun faster than Node?", title: "Could you clarify which regulation you mean?" });

    const scoped = await scopeQuestion({ question: "Is Bun faster than Node?" }, deps);

    expect(scoped.brief.title).toBe("Is Bun faster than Node");
  });

  it("replaces an apology and a question back to the user", async () => {
    for (const title of ["I'm sorry, I cannot help with that", "Which model do you want?"]) {
      const { deps } = model({ ...CLEAR_ENGLISH, resolved: "Is Bun faster than Node?", title });

      expect((await scopeQuestion({ question: "Is Bun faster than Node?" }, deps)).brief.title).toBe("Is Bun faster than Node");
    }
  });

  it("keeps a title to a single short line", async () => {
    const { deps } = model({ ...CLEAR_ENGLISH, title: "word ".repeat(40) });

    const { title } = (await scopeQuestion({ question: "Is Bun faster than Node?" }, deps)).brief;

    expect(title.length).toBeLessThanOrEqual(60);
    expect(title).not.toMatch(/\n/);
  });
});

describe("scope: when the model cannot help", () => {
  const QUESTION = "Jakie wymagania RODO dotyczą danych o zdrowiu i diecie w aplikacjach?";

  it("falls back to the user's own words, saying why", async () => {
    const { deps } = model({ ok: false, reason: "the claude CLI is signed out" });

    const scoped = await scopeQuestion({ question: QUESTION }, deps);

    expect(scoped).toEqual({
      needs_scoping: false,
      fallback_reason: "the claude CLI is signed out",
      brief: {
        asked: QUESTION, question: QUESTION, title: "Jakie wymagania RODO dotyczą danych o zdrowiu i diecie w", language: "pl",
        tier: "quick", suggested_tier: "quick", tier_reason: "", clarifications: [],
      },
    });
  });

  it("falls back on a reply that is not JSON", async () => {
    const { deps } = model({ ok: true, text: "Sure! What do you mean?" });

    const scoped = await scopeQuestion({ question: "Is Bun faster than Node?" }, deps);

    expect(scoped.brief.question).toBe("Is Bun faster than Node?");
    expect(scoped.fallback_reason).toMatch(/json/i);
  });

  it("falls back on a reply with no resolved question", async () => {
    const { deps } = model({ clear: true, title: "x" });

    const scoped = await scopeQuestion({ question: "Is Bun faster than Node?" }, deps);

    expect(scoped.fallback_reason).toMatch(/resolved/i);
  });

  it("falls back when asking the model throws", async () => {
    const deps: ScopeDeps = { askModel: async () => { throw new Error("spawn failed"); } };

    const scoped = await scopeQuestion({ question: "Is Bun faster than Node?" }, deps);

    expect(scoped.fallback_reason).toBe("spawn failed");
    expect(scoped.needs_scoping).toBe(false);
  });

  it("keeps the clarifications it was given when it falls back", async () => {
    const { deps } = model({ ok: false, reason: "timed out" });
    const clarifications = [{ question: "Który aspekt?", answer: "Technologia" }];

    const scoped = await scopeQuestion({ question: "blockchain", clarifications }, deps);

    expect(scoped.brief.clarifications).toEqual(clarifications);
  });
});

describe("scope: input", () => {
  it("refuses an empty question rather than returning a brief nobody can run", async () => {
    const { deps } = model();

    await expect(scopeQuestion({ question: "   " }, deps)).rejects.toThrow(/question/);
  });

  it("trims the question before it asks", async () => {
    const { deps, requests } = model(CLEAR_ENGLISH);

    const scoped = await scopeQuestion({ question: "  Is Bun faster than Node?\n" }, deps);

    expect(scoped.brief.asked).toBe("Is Bun faster than Node?");
    expect(requests[0]!.prompt).toContain("Is Bun faster than Node?");
  });
});

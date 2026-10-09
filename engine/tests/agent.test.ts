import { FetchFailure } from "../src/directFetch.js";
import { describe, it, expect } from "vitest";
import { MockLanguageModelV4, convertArrayToReadableStream } from "ai/test";
import { runResearch } from "../src/agent.js";
import { Emitter } from "../src/emitter.js";
import { EvidenceStore } from "../src/evidence.js";
import { Accountant } from "../src/pricing.js";
import { resolveEffort } from "../src/providers.js";
import type { SearchLike } from "../src/agent.js";

const DEEPSEEK_PRICE = { in: 0.27, out: 1.1, cacheRead: 0.07, cacheWrite: 0 };

function usagePart(input: number, output: number) {
  return {
    type: "finish" as const,
    finishReason: "tool-calls" as const,
    usage: {
      inputTokens: { total: input, noCache: input, cacheRead: 0, cacheWrite: 0 },
      outputTokens: { total: output, text: output, reasoning: 0 },
      totalTokens: input + output,
    },
  };
}

function textPart(id: string, text: string) {
  return [
    { type: "text-start" as const, id },
    { type: "text-delta" as const, id, delta: text },
    { type: "text-end" as const, id },
  ];
}

function toolCallPart(id: string, name: string, input: object) {
  return { type: "tool-call" as const, toolCallId: id, toolName: name, input: JSON.stringify(input) };
}

function captureEmitter() {
  const lines: any[] = [];
  return { emitter: new Emitter((l) => lines.push(JSON.parse(l.trimEnd()))), lines };
}

const fakeSearch: SearchLike = {
  search: async (query) => ({ results: [{ title: "Doc", url: "https://ex/1", snippet: "about " + query }] }),
  fetch: async (url) => ({ url, markdown: "# Doc\n\nAuthoritative content." }),
};

describe("runResearch — normal completion", () => {
  it("emits deltas, tool_use for search+fetch, per-step usage with monotonic cost, and a result with fenced json", async () => {
    let step = 0;
    const model = new MockLanguageModelV4({
      doStream: async () => {
        step++;
        if (step === 1)
          return {
            stream: convertArrayToReadableStream([
              { type: "stream-start", warnings: [] },
              ...textPart("0", "Let me search. "),
              toolCallPart("t1", "web_search", { query: "fusion 2026" }),
              usagePart(1000, 200),
            ]),
          };
        if (step === 2)
          return {
            stream: convertArrayToReadableStream([
              { type: "stream-start", warnings: [] },
              ...textPart("1", "Reading a source. "),
              toolCallPart("t2", "web_fetch", { url: "https://ex/1" }),
              usagePart(1500, 250),
            ]),
          };
        return {
          stream: convertArrayToReadableStream([
            { type: "stream-start", warnings: [] },
            ...textPart(
              "2",
              'Fusion progress is real.\n\n## Sources\n- [Doc](https://ex/1)\n\n```json\n{"headline":"Fusion advances","status":"complete","sourcesConsulted":1,"findings":[{"claim":"NIF hit ignition","sources":["https://ex/1"],"confidence":"high"}]}\n```'
            ),
            { type: "finish", finishReason: "stop", usage: { inputTokens: { total: 2000, noCache: 2000, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 400, text: 400, reasoning: 0 }, totalTokens: 2400 } },
          ]),
        };
      },
    });

    const { emitter, lines } = captureEmitter();
    const accountant = new Accountant(DEEPSEEK_PRICE, { searchFee: 0.008, fetchFee: 0, budgetUsd: 1 });
    await runResearch({
      model, provider: "deepseek", modelId: "deepseek-chat",
      systemPrompt: "sys", prompt: "research fusion",
      effort: resolveEffort("medium"), maxTurns: 10, timeoutMs: 60000,
      accountant, search: fakeSearch, evidence: new EvidenceStore(), emitter, sessionId: "s1",
    });

    const textDeltas = lines.filter((l) => l.type === "stream_event" && l.event.delta.type === "text_delta");
    expect(textDeltas.length).toBeGreaterThan(0);

    const toolNames = lines.filter((l) => l.type === "assistant").map((l) => l.message.content[0].name);
    expect(toolNames).toContain("web_search");
    expect(toolNames).toContain("web_fetch");

    const usages = lines.filter((l) => l.type === "usage");
    expect(usages.length).toBeGreaterThanOrEqual(2);
    for (let i = 1; i < usages.length; i++) {
      expect(usages[i].total_cost_usd).toBeGreaterThan(usages[i - 1].total_cost_usd);
    }

    const result = lines.find((l) => l.type === "result");
    expect(result.subtype).toBe("success");
    expect(result.total_cost_usd).toBeGreaterThan(0);
    expect(result.usage.search_calls).toBe(1);
    expect(result.usage.fetch_calls).toBe(1);
    expect(result.result).toContain("```json");
    const json = JSON.parse(result.result.split("```json")[1].split("```")[0]);
    expect(json.status).toBe("complete");
    expect(json.findings.length).toBeGreaterThanOrEqual(1);
  });
});

describe("runResearch — evidence capture", () => {
  const SNAPSHOT = "# Ignition\n\nOn Dec 5 2022 the NIF reached target energy gain above 1, a first for any lab.";
  const citingSearch: SearchLike = {
    search: async () => ({
      results: [
        { title: "Announcement", url: "https://llnl.example/ignition", snippet: "NIF reached ignition" },
        { title: "Listed only", url: "https://aggregator.example/roundup", snippet: "someone else's summary" },
      ],
    }),
    fetch: async (url) => ({ url, markdown: SNAPSHOT, title: "Ignition", contentType: "html" }),
  };

  function citingModel(finalText: string) {
    let step = 0;
    return new MockLanguageModelV4({
      doStream: async () => {
        step++;
        if (step === 1)
          return {
            stream: convertArrayToReadableStream([
              { type: "stream-start", warnings: [] },
              toolCallPart("t1", "web_search", { query: "nif ignition" }),
              usagePart(100, 20),
            ]),
          };
        if (step === 2)
          return {
            stream: convertArrayToReadableStream([
              { type: "stream-start", warnings: [] },
              toolCallPart("t2", "web_fetch", { url: "https://llnl.example/ignition" }),
              usagePart(100, 20),
            ]),
          };
        return {
          stream: convertArrayToReadableStream([
            { type: "stream-start", warnings: [] },
            ...textPart("2", finalText),
            usagePart(200, 60),
          ]),
        };
      },
    });
  }

  async function capture(finalText: string) {
    const { emitter, lines } = captureEmitter();
    const evidence = new EvidenceStore({ now: () => 0 });
    const accountant = new Accountant(DEEPSEEK_PRICE, { searchFee: 0, fetchFee: 0, budgetUsd: 1 });
    const outcome = await runResearch({
      model: citingModel(finalText), provider: "deepseek", modelId: "deepseek-chat",
      systemPrompt: "sys", prompt: "p", effort: resolveEffort("medium"),
      maxTurns: 10, timeoutMs: 60000, accountant, search: citingSearch, evidence, emitter, sessionId: "s-ev",
    });
    return { outcome, lines, evidence };
  }

  const CITED = [
    "The NIF reached ignition.[^c1]",
    "",
    "```json",
    JSON.stringify({
      headline: "Ignition reached", status: "complete", sourcesConsulted: 1,
      citations: [{ id: "c1", source: "SOURCE", quote: "target energy gain above 1" }],
      findings: [{ claim: "NIF hit ignition", sources: ["https://llnl.example/ignition"], citations: ["c1"], confidence: "high" }],
    }),
    "```",
  ].join("\n");

  it("hands the model a source_id with the fetched markdown so it has something to cite", async () => {
    const { evidence } = await capture(CITED);
    const fetched = evidence.findByUrl("https://llnl.example/ignition");
    expect(fetched?.text_length).toBe(SNAPSHOT.length);
    expect(fetched?.title).toBe("Ignition");
    expect(evidence.resolveCitation({ id: "c1", source: fetched!.source_id, quote: "target energy gain above 1" }).match)
      .toBe("exact");
  });

  it("files a failed fetch as a capture failure and announces it, instead of leaving only a tool error", async () => {
    const { emitter, lines } = captureEmitter();
    const evidence = new EvidenceStore({ now: () => 0 });
    const accountant = new Accountant(DEEPSEEK_PRICE, { searchFee: 0, fetchFee: 0, budgetUsd: 1 });
    const blockedSearch: SearchLike = {
      ...citingSearch,
      fetch: async (url) => { throw new FetchFailure("blocked", url, "HTTP 403: the site refused automated access"); },
    };
    await runResearch({
      model: citingModel(CITED), provider: "deepseek", modelId: "deepseek-chat",
      systemPrompt: "sys", prompt: "p", effort: resolveEffort("medium"),
      maxTurns: 10, timeoutMs: 60000, accountant, search: blockedSearch, evidence, emitter, sessionId: "s-fail",
    });
    expect(evidence.captureFailures()).toMatchObject([
      { url: "https://llnl.example/ignition", stage: "fetch", kind: "blocked" },
    ]);
    const announced = lines.filter((e) => e.type === "capture_failure");
    expect(announced).toMatchObject([{ failure: { url: "https://llnl.example/ignition", kind: "blocked" } }]);
  });

  it("stamps a document degraded when the fetch layer fell back to tag-stripping", async () => {
    const { emitter, lines } = captureEmitter();
    const evidence = new EvidenceStore({ now: () => 0 });
    const accountant = new Accountant(DEEPSEEK_PRICE, { searchFee: 0, fetchFee: 0, budgetUsd: 1 });
    const degradedSearch: SearchLike = {
      ...citingSearch,
      fetch: async (url) => ({ url, markdown: SNAPSHOT, title: "Ignition", contentType: "html", degraded: true }),
    };
    await runResearch({
      model: citingModel(CITED), provider: "deepseek", modelId: "deepseek-chat",
      systemPrompt: "sys", prompt: "p", effort: resolveEffort("medium"),
      maxTurns: 10, timeoutMs: 60000, accountant, search: degradedSearch, evidence, emitter, sessionId: "s-degraded",
    });
    const fetched = lines.filter((l) => l.type === "document")
      .findLast((l) => l.document.url === "https://llnl.example/ignition");
    expect(fetched.document.capture).toBe("degraded");
    expect(evidence.findByUrl("https://llnl.example/ignition")?.capture).toBe("degraded");
    expect(evidence.findByUrl("https://aggregator.example/roundup")?.capture).toBe("ok");
  });

  it("emits one document event per newly captured source, namespaced by the emitter", async () => {
    const { lines, evidence } = await capture(CITED);
    const documents = lines.filter((l) => l.type === "document");
    const urls = documents.map((l) => l.document.url);
    expect(urls).toContain("https://llnl.example/ignition");
    expect(urls).toContain("https://aggregator.example/roundup");
    expect(new Set(documents.map((l) => l.document.source_id)).size).toBeLessThanOrEqual(documents.length);
    const fetchedId = evidence.findByUrl("https://llnl.example/ignition")!.source_id;
    const forFetched = documents.filter((l) => l.document.source_id === fetchedId);
    expect(forFetched.at(-1).document.snapshot_path === null).toBe(true);   // memory-only store, no dir
    expect(forFetched.at(-1).document.text_length).toBe(SNAPSHOT.length);
  });

  it("registers a search-result url with no snapshot, so citing it stays honestly unresolved", async () => {
    const { evidence } = await capture(CITED);
    const listed = evidence.findByUrl("https://aggregator.example/roundup");
    expect(listed?.text_length).toBe(0);
    expect(evidence.resolveCitation({ id: "c9", source: listed!.source_id, quote: "anything at all" }).match)
      .toBe("unresolved");
  });

  it("returns the captured documents and the resolved citations of its own writeup", async () => {
    const { outcome, evidence } = await capture(CITED.replace("SOURCE", "PLACEHOLDER"));
    const fetchedId = evidence.findByUrl("https://llnl.example/ignition")!.source_id;
    const resolved = await capture(CITED.replace("SOURCE", fetchedId));

    expect(outcome.citations.map((c) => c.match)).toEqual(["unresolved"]);
    expect(resolved.outcome.citations).toHaveLength(1);
    expect(resolved.outcome.citations[0]).toMatchObject({ id: "c1", source_id: fetchedId, match: "exact" });
    expect(resolved.outcome.documents.map((d) => d.url).sort()).toEqual([
      "https://aggregator.example/roundup",
      "https://llnl.example/ignition",
    ]);
  });
});

describe("runResearch — read parity past the per-call cap", () => {
  const HEAD = "Head. ".repeat(2000);
  const TAIL = "The tail sentence nobody could read before.";
  const LONG = HEAD + TAIL;

  function toolResults(prompt: any[]): any[] {
    const values: any[] = [];
    for (const message of prompt) {
      if (message.role !== "tool") continue;
      for (const part of message.content ?? []) {
        values.push(part.output?.value ?? part.output ?? part.result);
      }
    }
    return values;
  }

  function continuingModel(prompts: any[]) {
    let step = 0;
    return new MockLanguageModelV4({
      doStream: async (params: any) => {
        prompts.push(JSON.parse(JSON.stringify(params.prompt)));
        step++;
        if (step === 1)
          return {
            stream: convertArrayToReadableStream([
              { type: "stream-start", warnings: [] },
              toolCallPart("t1", "web_fetch", { url: "https://long.example/paper" }),
              usagePart(100, 20),
            ]),
          };
        if (step === 2)
          return {
            stream: convertArrayToReadableStream([
              { type: "stream-start", warnings: [] },
              toolCallPart("t2", "web_fetch", { url: "https://long.example/paper", offset: HEAD.length }),
              usagePart(100, 20),
            ]),
          };
        return {
          stream: convertArrayToReadableStream([
            { type: "stream-start", warnings: [] },
            ...textPart("2", 'Read it all.\n\n```json\n{"headline":"h","status":"complete","sourcesConsulted":1,"findings":[]}\n```'),
            usagePart(200, 60),
          ]),
        };
      },
    });
  }

  async function readTwice() {
    const prompts: any[] = [];
    const { emitter, lines } = captureEmitter();
    const evidence = new EvidenceStore({ now: () => 0 });
    const accountant = new Accountant(DEEPSEEK_PRICE, { searchFee: 0, fetchFee: 0, budgetUsd: 1 });
    let networkFetches = 0;
    const longSearch: SearchLike = {
      search: async () => ({ results: [] }),
      fetch: async (url) => {
        networkFetches++;
        return { url, markdown: LONG, title: "Long paper", contentType: "html" };
      },
    };
    await runResearch({
      model: continuingModel(prompts), provider: "deepseek", modelId: "deepseek-chat",
      systemPrompt: "sys", prompt: "p", effort: resolveEffort("medium"),
      maxTurns: 10, timeoutMs: 60000, accountant, search: longSearch, evidence, emitter, sessionId: "s-offset",
    });
    const reads = toolResults(prompts.at(-1) ?? []).filter((r) => r?.markdown !== undefined);
    return { reads, networkFetches, lines, evidence };
  }

  it("caps the first read but tells the model where the rest of the source starts", async () => {
    const { reads } = await readTwice();
    expect(reads[0].markdown).toHaveLength(12000);
    expect(reads[0].markdown).not.toContain(TAIL);
    expect(reads[0].offset).toBe(0);
    expect(reads[0].total_chars).toBe(LONG.length);
    expect(reads[0].next_offset).toBe(12000);
  });

  it("continues an offset read over the SAME snapshot: the tail comes back, nothing is fetched twice", async () => {
    const { reads, networkFetches, lines } = await readTwice();
    expect(reads[1].markdown).toBe(TAIL);
    expect(reads[1].offset).toBe(HEAD.length);
    expect(reads[1].source_id).toBe(reads[0].source_id);
    expect(reads[1].next_offset).toBeUndefined();

    expect(networkFetches, "the offset read must serve the stored snapshot, not re-fetch").toBe(1);
    const documents = lines.filter((l) => l.type === "document" && l.document.url === "https://long.example/paper");
    expect(documents, "one capture, one snapshot, one document event").toHaveLength(1);
    expect(lines.find((l) => l.type === "result").usage.fetch_calls).toBe(1);
  });

  it("keeps the citation offsets of the tail pointing into the one stored snapshot", async () => {
    const { evidence } = await readTwice();
    const document = evidence.findByUrl("https://long.example/paper")!;
    const citation = evidence.resolveCitation({ id: "c1", source: document.source_id, quote: TAIL });
    expect(citation.match).toBe("exact");
    expect(citation.start).toBe(HEAD.length);
    expect(document.text_length).toBe(LONG.length);
  });
});

describe("runResearch — transient model errors", () => {
  const finalText = 'Done.\n\n```json\n{"headline":"h","status":"complete","sourcesConsulted":1,"findings":[{"claim":"c","sources":["https://ex/1"],"confidence":"high"}]}\n```';

  it("retries a rate-limited call with backoff and still completes", async () => {
    let attempts = 0;
    const model = new MockLanguageModelV4({
      doStream: async () => {
        attempts++;
        if (attempts <= 2) throw Object.assign(new Error("429 rate limit exceeded"), { statusCode: 429 });
        return {
          stream: convertArrayToReadableStream([
            { type: "stream-start", warnings: [] },
            ...textPart("0", finalText),
            usagePart(100, 50),
          ]),
        };
      },
    });
    const { emitter, lines } = captureEmitter();
    const slept: number[] = [];
    const accountant = new Accountant(DEEPSEEK_PRICE, { searchFee: 0, fetchFee: 0, budgetUsd: 1 });
    const outcome = await runResearch({
      model, provider: "deepseek", modelId: "deepseek-chat",
      systemPrompt: "sys", prompt: "p", effort: resolveEffort("medium"),
      maxTurns: 10, timeoutMs: 60000, accountant, search: fakeSearch, evidence: new EvidenceStore(), emitter, sessionId: "s4",
      sleep: async (ms) => { slept.push(ms); },
    });
    expect(attempts).toBe(3);
    expect(slept).toHaveLength(2);
    expect(slept[1]).toBeGreaterThan(slept[0]);
    expect(outcome.status).toBe("complete");
    expect(lines.find((l) => l.type === "result")).toBeDefined();
  });

  it("does not retry a non-transient failure", async () => {
    let attempts = 0;
    const model = new MockLanguageModelV4({
      doStream: async () => {
        attempts++;
        throw new Error("invalid api key");
      },
    });
    const { emitter } = captureEmitter();
    const accountant = new Accountant(DEEPSEEK_PRICE, { searchFee: 0, fetchFee: 0, budgetUsd: 1 });
    const outcome = await runResearch({
      model, provider: "deepseek", modelId: "deepseek-chat",
      systemPrompt: "sys", prompt: "p", effort: resolveEffort("medium"),
      maxTurns: 10, timeoutMs: 60000, accountant, search: fakeSearch, evidence: new EvidenceStore(), emitter, sessionId: "s5",
      sleep: async () => {},
    });
    expect(attempts).toBe(1);
    expect(outcome.status).toBe("inconclusive");
    expect(String(outcome.note)).toContain("Model call failed");
  });
});

describe("runResearch — anthropic prompt caching", () => {
  const finalText = 'Done.\n\n```json\n{"headline":"h","status":"complete","sourcesConsulted":1,"findings":[]}\n```';

  function twoStepModel(prompts: any[]) {
    let step = 0;
    return new MockLanguageModelV4({
      doStream: async (params: any) => {
        prompts.push(JSON.parse(JSON.stringify(params.prompt)));
        step++;
        if (step === 1)
          return {
            stream: convertArrayToReadableStream([
              { type: "stream-start", warnings: [] },
              ...textPart("0", "Searching. "),
              toolCallPart("t1", "web_search", { query: "q" }),
              usagePart(100, 20),
            ]),
          };
        return {
          stream: convertArrayToReadableStream([
            { type: "stream-start", warnings: [] },
            ...textPart("1", finalText),
            usagePart(200, 40),
          ]),
        };
      },
    });
  }

  it("marks exactly one ephemeral breakpoint on the last message, moving it as history grows", async () => {
    const prompts: any[] = [];
    const { emitter } = captureEmitter();
    const accountant = new Accountant(DEEPSEEK_PRICE, { searchFee: 0, fetchFee: 0, budgetUsd: 1 });
    await runResearch({
      model: twoStepModel(prompts), provider: "anthropic", modelId: "claude-haiku-4-5",
      systemPrompt: "sys", prompt: "p", effort: resolveEffort("low"),
      maxTurns: 10, timeoutMs: 60000, accountant, search: fakeSearch, evidence: new EvidenceStore(), emitter, sessionId: "s6",
    });
    expect(prompts.length).toBe(2);
    for (const prompt of prompts) {
      const marked = prompt.filter((m: any) => m.providerOptions?.anthropic?.cacheControl);
      expect(marked).toHaveLength(1);
      expect(prompt.at(-1).providerOptions?.anthropic?.cacheControl).toEqual({ type: "ephemeral" });
    }
  });

  it("adds no cache markers for other providers", async () => {
    const prompts: any[] = [];
    const { emitter } = captureEmitter();
    const accountant = new Accountant(DEEPSEEK_PRICE, { searchFee: 0, fetchFee: 0, budgetUsd: 1 });
    await runResearch({
      model: twoStepModel(prompts), provider: "deepseek", modelId: "deepseek-chat",
      systemPrompt: "sys", prompt: "p", effort: resolveEffort("low"),
      maxTurns: 10, timeoutMs: 60000, accountant, search: fakeSearch, evidence: new EvidenceStore(), emitter, sessionId: "s7",
    });
    for (const prompt of prompts) {
      expect(prompt.filter((m: any) => m.providerOptions?.anthropic?.cacheControl)).toHaveLength(0);
    }
  });
});

describe("runResearch — budget wall (acceptance criterion 2)", () => {
  it("stops a runaway tool loop mid-run and emits a graceful inconclusive result", async () => {
    let calls = 0;
    const model = new MockLanguageModelV4({
      doStream: async () => {
        calls++;
        return {
          stream: convertArrayToReadableStream([
            { type: "stream-start", warnings: [] },
            ...textPart(String(calls), "searching again "),
            toolCallPart("t" + calls, "web_search", { query: "again" }),
            usagePart(100000, 0),
          ]),
        };
      },
    });
    const { emitter, lines } = captureEmitter();
    const accountant = new Accountant(DEEPSEEK_PRICE, { searchFee: 0.008, fetchFee: 0, budgetUsd: 0.05 });
    await runResearch({
      model, provider: "deepseek", modelId: "deepseek-chat",
      systemPrompt: "sys", prompt: "loop forever",
      effort: resolveEffort("max"), maxTurns: 100, timeoutMs: 60000,
      accountant, search: fakeSearch, evidence: new EvidenceStore(), emitter, sessionId: "s2",
    });

    expect(calls).toBeLessThan(20);
    const result = lines.find((l) => l.type === "result");
    expect(result).toBeDefined();
    const json = JSON.parse(result.result.split("```json")[1].split("```")[0]);
    expect(json.status).toBe("inconclusive");
    expect(json.note).toBeTruthy();
  });

  it("respects maxTurns as a backstop even under a huge budget", async () => {
    let calls = 0;
    const model = new MockLanguageModelV4({
      doStream: async () => {
        calls++;
        return {
          stream: convertArrayToReadableStream([
            { type: "stream-start", warnings: [] },
            ...textPart(String(calls), "x "),
            toolCallPart("t" + calls, "web_search", { query: "x" }),
            usagePart(10, 0),
          ]),
        };
      },
    });
    const { emitter, lines } = captureEmitter();
    const accountant = new Accountant(DEEPSEEK_PRICE, { searchFee: 0, fetchFee: 0, budgetUsd: 1000 });
    await runResearch({
      model, provider: "deepseek", modelId: "deepseek-chat",
      systemPrompt: "sys", prompt: "loop", effort: resolveEffort("max"),
      maxTurns: 3, timeoutMs: 60000, accountant, search: fakeSearch, evidence: new EvidenceStore(), emitter, sessionId: "s3",
    });
    expect(calls).toBe(3);
    expect(lines.find((l) => l.type === "result")).toBeDefined();
  });
});

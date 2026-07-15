import { describe, it, expect } from "vitest";
import { MockLanguageModelV4, convertArrayToReadableStream } from "ai/test";
import { runResearch } from "../src/agent.js";
import { Emitter } from "../src/emitter.js";
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
      accountant, search: fakeSearch, emitter, sessionId: "s1",
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
      maxTurns: 10, timeoutMs: 60000, accountant, search: fakeSearch, emitter, sessionId: "s4",
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
      maxTurns: 10, timeoutMs: 60000, accountant, search: fakeSearch, emitter, sessionId: "s5",
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
      maxTurns: 10, timeoutMs: 60000, accountant, search: fakeSearch, emitter, sessionId: "s6",
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
      maxTurns: 10, timeoutMs: 60000, accountant, search: fakeSearch, emitter, sessionId: "s7",
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
      accountant, search: fakeSearch, emitter, sessionId: "s2",
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
      maxTurns: 3, timeoutMs: 60000, accountant, search: fakeSearch, emitter, sessionId: "s3",
    });
    expect(calls).toBe(3);
    expect(lines.find((l) => l.type === "result")).toBeDefined();
  });
});

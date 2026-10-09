import { describe, it, expect } from "vitest";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MockLanguageModelV4, convertArrayToReadableStream } from "ai/test";
import { runEngine } from "../src/engine.js";
import { Emitter } from "../src/emitter.js";
import { EvidenceStore } from "../src/evidence.js";
import { MissingKeyError } from "../src/errors.js";
import type { SearchLike } from "../src/agent.js";

function capture() {
  const lines: any[] = [];
  return { emitter: new Emitter((l) => lines.push(JSON.parse(l.trimEnd()))), lines };
}

const fakeSearch: SearchLike = {
  search: async () => ({ results: [] }),
  fetch: async (url) => ({ url, markdown: "" }),
};

function finalAnswerModel() {
  return new MockLanguageModelV4({
    doStream: async () => ({
      stream: convertArrayToReadableStream([
        { type: "stream-start", warnings: [] },
        { type: "text-start", id: "0" },
        { type: "text-delta", id: "0", delta: 'Done.\n\n```json\n{"headline":"h","status":"complete","sourcesConsulted":0,"findings":[]}\n```' },
        { type: "text-end", id: "0" },
        { type: "finish", finishReason: "stop", usage: { inputTokens: { total: 500, noCache: 500, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 50, text: 50, reasoning: 0 }, totalTokens: 550 } },
      ]),
    }),
  });
}

const citingSearch: SearchLike = {
  search: async () => ({ results: [] }),
  fetch: async (url) => ({ url, markdown: "the body of record", title: "Doc", contentType: "html" }),
};

function fetchingModel() {
  let step = 0;
  return new MockLanguageModelV4({
    doStream: async () => {
      step++;
      if (step === 1)
        return {
          stream: convertArrayToReadableStream([
            { type: "stream-start", warnings: [] },
            { type: "tool-call", toolCallId: "t1", toolName: "web_fetch", input: JSON.stringify({ url: "https://ex.test/doc" }) },
            { type: "finish", finishReason: "tool-calls", usage: { inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 5, text: 5, reasoning: 0 }, totalTokens: 15 } },
          ]),
        };
      return {
        stream: convertArrayToReadableStream([
          { type: "stream-start", warnings: [] },
          { type: "text-start", id: "0" },
          { type: "text-delta", id: "0", delta: 'Done.[^c1]\n\n```json\n{"headline":"h","status":"complete","sourcesConsulted":1,"citations":[{"id":"c1","source":"s","quote":"the body of record"}],"findings":[]}\n```' },
          { type: "text-end", id: "0" },
          { type: "finish", finishReason: "stop", usage: { inputTokens: { total: 20, noCache: 20, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 5, text: 5, reasoning: 0 }, totalTokens: 25 } },
        ]),
      };
    },
  });
}

describe("runEngine", () => {
  it("emits the init handshake as the very first line", async () => {
    const { emitter, lines } = capture();
    await runEngine(
      { command: "research", prompt: "topic", model: "deepseek/deepseek-chat" },
      { QUORUM_DEEPSEEK_KEY: "k", QUORUM_TAVILY_KEY: "t" },
      { emitter, resolveModel: () => ({ model: finalAnswerModel(), provider: "deepseek", modelId: "deepseek-chat" }), makeSearchClient: () => fakeSearch }
    );
    expect(lines[0]).toMatchObject({ type: "system", subtype: "init", engine: "quorum-engine", protocol_version: 5 });
    expect(lines[0].model).toBe("deepseek/deepseek-chat");
    expect(lines.find((l) => l.type === "result")).toBeDefined();
  });

  it("captures evidence into the directory the app handed it on a single-topic run", async () => {
    const dir = mkdtempSync(join(tmpdir(), "quorum-engine-evidence-"));
    const { emitter, lines } = capture();
    await runEngine(
      { command: "research", prompt: "topic", model: "deepseek/deepseek-chat" },
      { QUORUM_DEEPSEEK_KEY: "k", QUORUM_TAVILY_KEY: "t", QUORUM_EVIDENCE_DIR: dir },
      {
        emitter,
        resolveModel: () => ({ model: fetchingModel(), provider: "deepseek", modelId: "deepseek-chat" }),
        makeSearchClient: () => citingSearch,
      }
    );
    const announced = lines.filter((l) => l.type === "document");
    expect(announced).toHaveLength(1);
    const loaded = EvidenceStore.load(dir);
    const document = loaded.findByUrl("https://ex.test/doc");
    expect(document?.snapshot_path).toBe(`sources/${document!.source_id}.md`);
    expect(loaded.resolveCitation({ id: "c1", source: document!.source_id, quote: "the body of record" }).match)
      .toBe("exact");
  });

  it("missing provider key → error event naming the provider, then a graceful inconclusive result (R6)", async () => {
    const { emitter, lines } = capture();
    await runEngine(
      { command: "research", prompt: "topic", model: "anthropic/claude-haiku-4-5" },
      {},
      {
        emitter,
        resolveModel: () => {
          throw new MissingKeyError("anthropic", "QUORUM_ANTHROPIC_KEY");
        },
        makeSearchClient: () => fakeSearch,
      }
    );
    const err = lines.find((l) => l.type === "error");
    expect(err.provider).toBe("anthropic");
    const result = lines.find((l) => l.type === "result");
    const json = JSON.parse(result.result.split("```json")[1].split("```")[0]);
    expect(json.status).toBe("inconclusive");
  });

  it("unpriced model → refuses to run blind with an error + inconclusive result (R4)", async () => {
    const { emitter, lines } = capture();
    await runEngine(
      { command: "research", prompt: "topic", model: "mystery/model-x" },
      { QUORUM_OPENAI_COMPATIBLE_KEY: "k", QUORUM_OPENAI_COMPATIBLE_BASE_URL: "https://x", QUORUM_TAVILY_KEY: "t" },
      { emitter, makeSearchClient: () => fakeSearch }
    );
    expect(lines[0].type).toBe("system");
    const err = lines.find((l) => l.type === "error");
    expect(err.error).toContain("price");
    const result = lines.find((l) => l.type === "result");
    const json = JSON.parse(result.result.split("```json")[1].split("```")[0]);
    expect(json.status).toBe("inconclusive");
  });

  it("no prompt → error + inconclusive, never a dead process", async () => {
    const { emitter, lines } = capture();
    await runEngine(
      { command: "research", model: "deepseek/deepseek-chat" },
      { QUORUM_DEEPSEEK_KEY: "k", QUORUM_TAVILY_KEY: "t" },
      { emitter, resolveModel: () => ({ model: finalAnswerModel(), provider: "deepseek", modelId: "deepseek-chat" }), makeSearchClient: () => fakeSearch }
    );
    expect(lines.find((l) => l.type === "error")).toBeDefined();
    expect(lines.find((l) => l.type === "result")).toBeDefined();
  });
});

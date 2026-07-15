import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { MockLanguageModelV4, convertArrayToReadableStream } from "ai/test";
import { Emitter } from "./emitter.js";
import { runEngine } from "./engine.js";
import type { SearchLike } from "./agent.js";

const FIXTURE_SESSION = "00000000-0000-4000-8000-000000000000";

function usage(input: number, output: number, reason: "tool-calls" | "stop") {
  return {
    type: "finish" as const,
    finishReason: reason,
    usage: {
      inputTokens: { total: input, noCache: input, cacheRead: 0, cacheWrite: 0 },
      outputTokens: { total: output, text: output, reasoning: 0 },
      totalTokens: input + output,
    },
  };
}
function text(id: string, body: string) {
  return [
    { type: "text-start" as const, id },
    { type: "text-delta" as const, id, delta: body },
    { type: "text-end" as const, id },
  ];
}
function toolCall(id: string, name: string, input: object) {
  return { type: "tool-call" as const, toolCallId: id, toolName: name, input: JSON.stringify(input) };
}

const WRITEUP = [
  "Nuclear fusion crossed scientific breakeven at the US National Ignition Facility, but grid power remains years away.",
  "",
  "## Sources",
  "- [LLNL ignition announcement](https://www.llnl.gov/news/ignition)",
  "- [ITER project status](https://www.iter.org/proj/inafewlines)",
  "",
  '```json',
  '{"headline":"Fusion has hit scientific breakeven but not net grid power","status":"complete","sourcesConsulted":2,"findings":[{"claim":"NIF achieved fusion ignition (target energy gain > 1) in December 2022","sources":["https://www.llnl.gov/news/ignition"],"confidence":"high"},{"claim":"ITER first plasma is scheduled for the mid-2030s","sources":["https://www.iter.org/proj/inafewlines"],"confidence":"medium"}]}',
  '```',
].join("\n");

function fixtureModel() {
  let step = 0;
  return new MockLanguageModelV4({
    doStream: async () => {
      step++;
      if (step === 1)
        return {
          stream: convertArrayToReadableStream([
            { type: "stream-start", warnings: [] },
            ...text("0", "Planning: I need current fusion milestones. "),
            toolCall("t1", "web_search", { query: "nuclear fusion energy status 2026 net gain" }),
            usage(1200, 220, "tool-calls"),
          ]),
        };
      if (step === 2)
        return {
          stream: convertArrayToReadableStream([
            { type: "stream-start", warnings: [] },
            ...text("1", "Reading the primary source. "),
            toolCall("t2", "web_fetch", { url: "https://www.llnl.gov/news/ignition" }),
            usage(1800, 260, "tool-calls"),
          ]),
        };
      return {
        stream: convertArrayToReadableStream([
          { type: "stream-start", warnings: [] },
          ...text("2", WRITEUP),
          usage(2600, 520, "stop"),
        ]),
      };
    },
  } as any);
}

const fixtureSearch: SearchLike = {
  search: async (query) => ({
    results: [
      { title: "LLNL ignition announcement", url: "https://www.llnl.gov/news/ignition", snippet: "NIF achieved ignition. " + query },
      { title: "ITER project status", url: "https://www.iter.org/proj/inafewlines", snippet: "ITER timeline" },
    ],
  }),
  fetch: async (url) => ({ url, markdown: "# Ignition\n\nOn Dec 5 2022, NIF achieved fusion ignition with target energy gain above 1." }),
};

export async function recordFixtureLines(): Promise<string[]> {
  const lines: string[] = [];
  const emitter = new Emitter((line) => lines.push(line));
  await runEngine(
    { command: "research", prompt: "What is the status of nuclear fusion energy in 2026?", model: "deepseek/deepseek-chat", effort: "medium" },
    { QUORUM_DEEPSEEK_KEY: "mock", QUORUM_TAVILY_KEY: "mock" },
    {
      emitter,
      sessionId: FIXTURE_SESSION,
      resolveModel: () => ({ model: fixtureModel(), provider: "deepseek", modelId: "deepseek-chat" }),
      makeSearchClient: () => fixtureSearch,
    }
  );
  return lines;
}

export const FIXTURE_PATH = fileURLToPath(new URL("../fixtures/engine-transcript.ndjson", import.meta.url));

if (import.meta.main) {
  const lines = await recordFixtureLines();
  writeFileSync(FIXTURE_PATH, lines.join(""));
  process.stderr.write(`Wrote ${lines.length} lines to ${FIXTURE_PATH}\n`);
}

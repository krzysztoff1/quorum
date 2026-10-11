import { describe, it, expect } from "vitest";
import { runTopic } from "../src/backend.js";
import { Emitter } from "../src/emitter.js";

describe("runTopic", () => {
  it("refuses a model that is not the Claude subscription", async () => {
    await expect(
      runTopic({
        angleId: "a1", role: "research", spec: "deepseek/deepseek-chat", prompt: "q", systemPrompt: "",
        effort: "low", perTopicBudgetUsd: 1, timeoutMs: 1000, env: {}, emitter: new Emitter(() => {}), deps: {},
      }),
    ).rejects.toThrow(/only the Claude subscription/);
  });
});

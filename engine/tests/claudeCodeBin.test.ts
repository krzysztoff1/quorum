import { describe, it, expect } from "vitest";
import { fileURLToPath } from "node:url";
import { runClaudeCode, buildClaudeArgs } from "../src/claudeCode.js";
import { Emitter } from "../src/emitter.js";

const FAKE = fileURLToPath(new URL("../fixtures/fake-claude.sh", import.meta.url));
const SESSION = "11111111-2222-4333-8444-555555555555";

function capture() {
  const lines: any[] = [];
  return { emitter: new Emitter((l) => lines.push(JSON.parse(l.trimEnd()))), lines };
}

describe("runClaudeCode over a real subprocess (QUORUM_CLAUDE_BIN fake script)", () => {
  it("resolves the bin override, spawns it, and adapts the piped stream-json into events + a topic result", async () => {
    const { emitter, lines } = capture();
    const outcome = await runClaudeCode({
      prompt: "research fusion",
      systemPrompt: "sys",
      role: "research",
      effort: "medium",
      maxBudgetUsd: 0.25,
      maxTurns: 8,
      timeoutMs: 60_000,
      emitter,
      env: { QUORUM_CLAUDE_BIN: FAKE },
    });

    expect(outcome.status).toBe("complete");
    expect(outcome.sessionId).toBe(SESSION);
    expect(outcome.model).toBe("claude-opus-4-20250101");
    expect(outcome.usage.search_calls).toBe(1);
    expect(outcome.usage.cost_usd).toBeCloseTo(0.0123);

    expect(lines.filter((l) => l.type === "stream_event").length).toBeGreaterThan(0);
    expect(lines.filter((l) => l.type === "assistant").map((l) => l.message.content[0].name)).toContain("web_search");
    expect(lines.find((l) => l.type === "result").session_id).toBe(SESSION);
  });

  it("kills a live claude child on abort and winds down halted", async () => {
    const { emitter } = capture();
    const controller = new AbortController();
    setTimeout(() => controller.abort(), 50);
    const outcome = await runClaudeCode({
      prompt: "x",
      systemPrompt: "",
      role: "research",
      effort: "medium",
      maxBudgetUsd: 0.25,
      maxTurns: 8,
      timeoutMs: 60_000,
      emitter,
      env: { QUORUM_CLAUDE_BIN: FAKE, QUORUM_FAKE_SLEEP: "1" },
      signal: controller.signal,
    });
    expect(outcome.status).toBe("halted");
    expect(outcome.sessionId).toBe(SESSION);
  });
});

describe("buildClaudeArgs — alias and project context", () => {
  const base = {
    prompt: "p", systemPrompt: "s", role: "research" as const, effort: "medium",
    maxBudgetUsd: 0.25, maxTurns: 8, timeoutMs: 1, emitter: new Emitter(() => {}), env: {},
  };

  it("maps a claude-code alias to --model and requests project dirs on demand", () => {
    const args = buildClaudeArgs({ ...base, alias: "opus", useProjectContext: true, projectDir: "/proj" });
    expect(args[args.indexOf("--model") + 1]).toBe("opus");
    expect(args[args.indexOf("--add-dir") + 1]).toBe("/proj");
  });
});

import { describe, it, expect } from "vitest";
import { EventEmitter } from "node:events";
import { runClaudeCode, parseClaudeCodeSpec, buildClaudeArgs, type SpawnFn } from "../src/claudeCode.js";
import { Emitter } from "../src/emitter.js";

function fakeSpawn(lines: string[]): SpawnFn {
  return ((_bin: string, _args: string[], _opts: unknown) => {
    const stdout = new EventEmitter() as EventEmitter & { setEncoding: (e: string) => void };
    stdout.setEncoding = () => {};
    const child = new EventEmitter() as EventEmitter & { stdout: unknown; stderr: unknown; kill: () => void };
    child.stdout = stdout;
    child.stderr = new EventEmitter();
    child.kill = () => {};
    queueMicrotask(() => {
      for (const l of lines) stdout.emit("data", l + "\n");
      child.emit("close");
    });
    return child;
  }) as unknown as SpawnFn;
}

const CLAUDE_STREAM = [
  `{"type":"system","subtype":"init","session_id":"real-cli-123","model":"claude-sonnet-5"}`,
  `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Fusion crossed breakeven. "}}}`,
  `{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"fusion ignition"}}],"usage":{"input_tokens":1200,"output_tokens":300}}}`,
  `{"type":"result","subtype":"success","total_cost_usd":0.42,"session_id":"real-cli-123","result":"Fusion crossed breakeven.\\n\\n\`\`\`json\\n{\\"headline\\":\\"Breakeven reached\\",\\"status\\":\\"complete\\",\\"sourcesConsulted\\":1,\\"findings\\":[{\\"claim\\":\\"NIF ignition\\",\\"sources\\":[\\"https://llnl.gov\\"],\\"confidence\\":\\"high\\"}]}\\n\`\`\`"}`,
];

describe("claude-code backend", () => {
  it("adapts the claude CLI stream into a topic outcome with the real (resumable) session id", async () => {
    const captured: string[] = [];
    const outcome = await runClaudeCode({
      prompt: "Where does fusion stand?", systemPrompt: "be rigorous", role: "research",
      effort: "medium", maxBudgetUsd: 1, maxTurns: 8, timeoutMs: 10_000,
      emitter: new Emitter((l) => captured.push(l)), env: { QUORUM_CLAUDE_BIN: "/fake/claude" },
      spawn: fakeSpawn(CLAUDE_STREAM), now: () => 0,
    });
    expect(outcome.status).toBe("complete");
    expect(outcome.sessionId).toBe("real-cli-123");   // real CLI session → Swift can --resume it
    expect(outcome.result).toContain("```json");
    expect(outcome.usage.provider).toBe("claude-code");
    expect(outcome.usage.search_calls).toBe(1);       // WebSearch normalized + tallied
    expect(outcome.usage.cost_usd).toBe(0.42);
  });

  it("winds down gracefully (never a dead process) when the CLI yields no result", async () => {
    const captured: string[] = [];
    const outcome = await runClaudeCode({
      prompt: "q", systemPrompt: "", role: "research",
      effort: "medium", maxBudgetUsd: 1, maxTurns: 8, timeoutMs: 10_000,
      emitter: new Emitter((l) => captured.push(l)), env: { QUORUM_CLAUDE_BIN: "/fake/claude" },
      spawn: fakeSpawn([]), now: () => 0,   // empty stream → no result event
    });
    expect(outcome.status).toBe("error");
    expect(outcome.result).toContain("```json");        // still emits a parseable summary, not a dead process
    expect(captured.some((l) => l.includes(`"type":"result"`))).toBe(true);
  });

  it("hands the spawned CLI the evidence directory so its mcp-serve child captures into this run", async () => {
    const options: any[] = [];
    const inner = fakeSpawn(CLAUDE_STREAM);
    const spy = ((bin: string, args: string[], opts: any) => {
      options.push(opts);
      return (inner as any)(bin, args, opts);
    }) as unknown as SpawnFn;
    await runClaudeCode({
      prompt: "q", systemPrompt: "", role: "research", effort: "medium", maxBudgetUsd: 1, maxTurns: 8,
      timeoutMs: 10_000, emitter: new Emitter(() => {}),
      env: { QUORUM_CLAUDE_BIN: "/fake/claude", QUORUM_TAVILY_KEY: "tk" },
      evidenceDir: "/runs/7/evidence", spawn: spy, now: () => 0,
    });
    expect(options[0].env.QUORUM_EVIDENCE_DIR).toBe("/runs/7/evidence");
    expect(options[0].env.QUORUM_TAVILY_KEY).toBe("tk");
  });

  it("leaves the inherited environment untouched when the run captures no evidence", async () => {
    const options: any[] = [];
    const inner = fakeSpawn(CLAUDE_STREAM);
    const spy = ((bin: string, args: string[], opts: any) => {
      options.push(opts);
      return (inner as any)(bin, args, opts);
    }) as unknown as SpawnFn;
    await runClaudeCode({
      prompt: "q", systemPrompt: "", role: "research", effort: "medium", maxBudgetUsd: 1, maxTurns: 8,
      timeoutMs: 10_000, emitter: new Emitter(() => {}),
      env: { QUORUM_CLAUDE_BIN: "/fake/claude", QUORUM_EVIDENCE_DIR: "/ambient/evidence" },
      spawn: spy, now: () => 0,
    });
    expect(options[0].env.QUORUM_EVIDENCE_DIR).toBe("/ambient/evidence");
  });

  it("wires own-search MCP only when a search key is present, never a secret in argv", () => {
    const base = {
      prompt: "p", systemPrompt: "s", role: "research" as const, effort: "medium",
      maxBudgetUsd: 0.25, maxTurns: 7, timeoutMs: 1000, emitter: new Emitter(() => {}),
    };
    const withKey = buildClaudeArgs({ ...base, env: { QUORUM_TAVILY_KEY: "secret-abc" } });
    expect(withKey).toContain("--mcp-config");
    expect(withKey.some((a) => a.includes("secret-abc"))).toBe(false);   // key rides env, not argv
    expect(withKey.join(" ")).not.toContain("WebSearch");               // own search replaces the billed built-in
    const noKey = buildClaudeArgs({ ...base, env: {} });
    expect(noKey).not.toContain("--mcp-config");
  });

  it("passes the topic's spend, effort, turn, permission, and tool guardrails", () => {
    const args = buildClaudeArgs({
      prompt: "p", systemPrompt: "s", role: "research", effort: "xhigh",
      maxBudgetUsd: 0.25, maxTurns: 7, timeoutMs: 1000,
      emitter: new Emitter(() => {}), env: {},
    });
    expect(args[args.indexOf("--permission-mode") + 1]).toBe("dontAsk");
    expect(args[args.indexOf("--effort") + 1]).toBe("xhigh");
    expect(args[args.indexOf("--max-budget-usd") + 1]).toBe("0.25");
    expect(args[args.indexOf("--max-turns") + 1]).toBe("7");
    expect(args[args.indexOf("--tools") + 1]).toBe("WebSearch,WebFetch");
    expect(args[args.indexOf("--allowedTools") + 1]).toBe("WebSearch WebFetch");
  });
});

describe("backend spec parsing", () => {
  it("recognizes claude-code specs", () => {
    expect(parseClaudeCodeSpec("claude-code")).toEqual({});
    expect(parseClaudeCodeSpec("claude-code/claude-opus-4-8")).toEqual({ alias: "claude-opus-4-8" });
    expect(parseClaudeCodeSpec("deepseek/deepseek-chat")).toBeNull();
  });
});

import { describe, it, expect } from "vitest";
import { EventEmitter } from "node:events";
import { runClaudeCode, parseClaudeCodeSpec, buildClaudeArgs, selfMcpCommand, type SpawnFn } from "../src/claudeCode.js";
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

  it("keeps the answer the CLI had already written when it stops on its budget before a result", async () => {
    const answer = "```json\n{\"verdicts\":[{\"claim\":1,\"verdict\":\"supported\"}]}\n```";
    const outcome = await runClaudeCode({
      prompt: "q", systemPrompt: "", role: "validate", effort: "low", maxBudgetUsd: 0.05, maxTurns: 1, timeoutMs: 10_000,
      emitter: new Emitter(() => {}), env: { QUORUM_CLAUDE_BIN: "/fake/claude" },
      spawn: fakeSpawn([
        `{"type":"system","subtype":"init","session_id":"s1","model":"claude-haiku-4-5"}`,
        JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: answer }], usage: { input_tokens: 10, output_tokens: 20 } } }),
        `{"type":"result","subtype":"error_max_budget_usd","total_cost_usd":0.06,"session_id":"s1"}`,
      ]),
      now: () => 0,
    });
    expect(outcome.status).toBe("inconclusive");
    expect(outcome.result).toContain('"verdict":"supported"');
    expect(outcome.result).not.toContain("Claude produced no output");
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

  const base = {
    prompt: "p", systemPrompt: "s", role: "research" as const, effort: "medium",
    maxBudgetUsd: 0.25, maxTurns: 7, timeoutMs: 1000, emitter: new Emitter(() => {}),
  };
  const toolsOf = (args: string[]) => args[args.indexOf("--tools") + 1]!.split(",");

  it("with a search key, searches and reads through the engine and never a secret in argv", () => {
    const args = buildClaudeArgs({ ...base, env: { QUORUM_TAVILY_KEY: "secret-abc" } });
    expect(args).toContain("--mcp-config");
    expect(args.some((a) => a.includes("secret-abc"))).toBe(false);
    expect(toolsOf(args)).toEqual(["mcp__quorum__web_search", "mcp__quorum__web_fetch"]);
  });

  it("with no key, discovers with the CLI's WebSearch but still reads through the engine's web_fetch", () => {
    const args = buildClaudeArgs({ ...base, env: {} });
    expect(args).toContain("--mcp-config");
    expect(toolsOf(args)).toEqual(["WebSearch", "mcp__quorum__web_fetch"]);
    expect(args[args.indexOf("--allowedTools") + 1]).toBe("WebSearch mcp__quorum__web_fetch");
  });

  it("never lets the CLI's own WebFetch read a page, because nothing it reads would be captured", () => {
    for (const env of [{}, { QUORUM_TAVILY_KEY: "tk" }, { QUORUM_BRAVE_KEY: "bk" }]) {
      const args = buildClaudeArgs({ ...base, env });
      expect(args.join(" ")).not.toMatch(/(^|[ ,])WebFetch/);
    }
  });

  it("serves the engine's tools from this binary's own mcp-serve", () => {
    const args = buildClaudeArgs({ ...base, env: {} });
    const config = JSON.parse(args[args.indexOf("--mcp-config") + 1]!);
    expect(config.mcpServers.quorum.args).toContain("mcp-serve");
  });

  it("offers spawn_inquiry whenever the run gave the angle somewhere to file it", () => {
    expect(toolsOf(buildClaudeArgs({ ...base, env: {}, spawnDir: "/run/spawns" }))).toContain("mcp__quorum__spawn_inquiry");
    expect(toolsOf(buildClaudeArgs({ ...base, env: {} }))).not.toContain("mcp__quorum__spawn_inquiry");
  });

  it("gives non-research roles no tools and no MCP server", () => {
    const args = buildClaudeArgs({ ...base, role: "synthesis", env: {} });
    expect(toolsOf(args)).toEqual([""]);
    expect(args).not.toContain("--mcp-config");
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
    expect(args[args.indexOf("--tools") + 1]).toBe("WebSearch,mcp__quorum__web_fetch");
    expect(args[args.indexOf("--allowedTools") + 1]).toBe("WebSearch mcp__quorum__web_fetch");
  });
});

describe("selfMcpCommand", () => {
  it("runs a compiled binary as itself, since its argv[1] is a virtual path inside the binary", () => {
    expect(selfMcpCommand("/Applications/Quorum.app/quorum-engine", "/$bunfs/root/quorum-engine"))
      .toEqual({ command: "/Applications/Quorum.app/quorum-engine", args: ["mcp-serve"] });
  });

  it("runs a source checkout through its entry script", () => {
    expect(selfMcpCommand("/usr/local/bin/bun", "/repo/engine/src/index.ts"))
      .toEqual({ command: "/usr/local/bin/bun", args: ["/repo/engine/src/index.ts", "mcp-serve"] });
  });

  it("runs a binary with no script argument as itself", () => {
    expect(selfMcpCommand("/bin/quorum-engine", null)).toEqual({ command: "/bin/quorum-engine", args: ["mcp-serve"] });
  });
});

describe("backend spec parsing", () => {
  it("recognizes claude-code specs", () => {
    expect(parseClaudeCodeSpec("claude-code")).toEqual({});
    expect(parseClaudeCodeSpec("claude-code/claude-opus-4-8")).toEqual({ alias: "claude-opus-4-8" });
    expect(parseClaudeCodeSpec("deepseek/deepseek-chat")).toBeNull();
  });
});

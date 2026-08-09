import { describe, it, expect } from "vitest";
import { EventEmitter } from "node:events";
import {
  runCodex,
  parseCodexSpec,
  buildCodexArgs,
  resolveCodexModel,
  codexReasoningEffort,
  CODEX_ALIASES,
} from "../src/codex.js";
import type { SpawnFn } from "../src/claudeCode.js";
import { runTopic } from "../src/backend.js";
import { runEngine } from "../src/engine.js";
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

const CODEX_STREAM = [
  `{"type":"thread.started","thread_id":"019fe6d6-99ff-70f3-959d-9c87c2a202c9"}`,
  `{"type":"turn.started"}`,
  `{"type":"item.completed","item":{"id":"r1","type":"reasoning","text":"Weighing the two reactor claims."}}`,
  `{"type":"item.completed","item":{"id":"e1","type":"web_search","query":"fusion ignition breakeven","action":{"type":"search","query":"fusion ignition breakeven"}}}`,
  `{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":"Fusion crossed breakeven.\\n\\n\`\`\`json\\n{\\"headline\\":\\"Breakeven reached\\",\\"status\\":\\"complete\\",\\"sourcesConsulted\\":1,\\"findings\\":[]}\\n\`\`\`"}}`,
  `{"type":"turn.completed","usage":{"input_tokens":58843,"cached_input_tokens":44288,"cache_write_input_tokens":12,"output_tokens":219,"reasoning_output_tokens":73}}`,
];

const BASE = {
  prompt: "Where does fusion stand?",
  systemPrompt: "be rigorous",
  role: "research" as const,
  effort: "medium",
  timeoutMs: 10_000,
};

describe("codex spec parsing", () => {
  it("recognizes codex specs and leaves other backends alone", () => {
    expect(parseCodexSpec("codex")).toEqual({});
    expect(parseCodexSpec("codex/luna")).toEqual({ alias: "luna" });
    expect(parseCodexSpec("codex/gpt-5.6-sol")).toEqual({ alias: "gpt-5.6-sol" });
    expect(parseCodexSpec("claude-code/claude-opus-4-8")).toBeNull();
    expect(parseCodexSpec("deepseek/deepseek-chat")).toBeNull();
  });

  it("resolves the three named aliases to their model slugs", () => {
    expect(resolveCodexModel("luna")).toBe("gpt-5.6-luna");
    expect(resolveCodexModel("terra")).toBe("gpt-5.6-terra");
    expect(resolveCodexModel("sol")).toBe("gpt-5.6-sol");
    expect(Object.keys(CODEX_ALIASES)).toEqual(["luna", "terra", "sol"]);
  });

  it("passes an explicit slug through and defaults an unaddressed spec", () => {
    expect(resolveCodexModel("gpt-5.6-sol")).toBe("gpt-5.6-sol");
    expect(resolveCodexModel(undefined)).toBe("gpt-5.6-terra");
  });
});

describe("codex effort", () => {
  it("maps every Quorum effort level onto the codex reasoning dial", () => {
    for (const effort of ["low", "medium", "high", "xhigh", "max"]) {
      expect(codexReasoningEffort(effort, "gpt-5.6-sol")).toBe(effort);
    }
  });

  it("clamps an effort the model does not offer down to its highest supported level", () => {
    expect(codexReasoningEffort("ultra", "gpt-5.6-sol")).toBe("ultra");
    expect(codexReasoningEffort("ultra", "gpt-5.6-terra")).toBe("ultra");
    expect(codexReasoningEffort("ultra", "gpt-5.6-luna")).toBe("max");
  });

  it("falls back to medium for an effort nobody named", () => {
    expect(codexReasoningEffort("", "gpt-5.6-luna")).toBe("medium");
    expect(codexReasoningEffort("blistering", "gpt-5.6-luna")).toBe("medium");
  });
});

describe("codex argument building", () => {
  it("pins the model, the effort, and a read-only sandbox", () => {
    const args = buildCodexArgs({ ...BASE, alias: "sol", effort: "xhigh", emitter: new Emitter(() => {}), env: {} });
    expect(args[args.indexOf("-m") + 1]).toBe("gpt-5.6-sol");
    expect(args[args.indexOf("-s") + 1]).toBe("read-only");
    expect(args).toContain("--json");
    expect(args).toContain(`model_reasoning_effort="xhigh"`);
  });

  it("carries the system prompt in the prompt, since codex exec has no system-prompt flag", () => {
    const args = buildCodexArgs({ ...BASE, emitter: new Emitter(() => {}), env: {} });
    expect(args[args.length - 1]).toContain("be rigorous");
    expect(args[args.length - 1]).toContain("Where does fusion stand?");
  });

  it("wires own-search MCP only when a search key is present, never a secret in argv", () => {
    const withKey = buildCodexArgs({ ...BASE, emitter: new Emitter(() => {}), env: { QUORUM_TAVILY_KEY: "secret-abc" } });
    expect(withKey.some((a) => a.startsWith("mcp_servers.quorum.command="))).toBe(true);
    expect(withKey.some((a) => a.includes("secret-abc"))).toBe(false);
    expect(withKey).toContain("tools.web_search=false");

    const noKey = buildCodexArgs({ ...BASE, emitter: new Emitter(() => {}), env: {} });
    expect(noKey.some((a) => a.startsWith("mcp_servers.quorum.command="))).toBe(false);
    expect(noKey).toContain("tools.web_search=true");
  });

  it("gives a synthesis topic no web reach at all", () => {
    const args = buildCodexArgs({
      ...BASE, role: "synthesis", emitter: new Emitter(() => {}), env: { QUORUM_TAVILY_KEY: "k" },
    });
    expect(args).toContain("tools.web_search=false");
    expect(args.some((a) => a.startsWith("mcp_servers.quorum.command="))).toBe(false);
  });

  it("opens the project directory only for a project-context research topic", () => {
    const withProject = buildCodexArgs({
      ...BASE, useProjectContext: true, projectDir: "/work/andon", emitter: new Emitter(() => {}), env: {},
    });
    expect(withProject[withProject.indexOf("-C") + 1]).toBe("/work/andon");

    const withoutProject = buildCodexArgs({ ...BASE, emitter: new Emitter(() => {}), env: {} });
    expect(withoutProject).not.toContain("-C");
  });
});

describe("codex backend", () => {
  it("adapts the codex exec stream into a topic outcome", async () => {
    const captured: string[] = [];
    const outcome = await runCodex({
      ...BASE, alias: "luna",
      emitter: new Emitter((l) => captured.push(l)), env: { QUORUM_CODEX_BIN: "/fake/codex" },
      spawn: fakeSpawn(CODEX_STREAM), now: () => 0,
    });
    expect(outcome.status).toBe("complete");
    expect(outcome.sessionId).toBe("019fe6d6-99ff-70f3-959d-9c87c2a202c9");
    expect(outcome.model).toBe("gpt-5.6-luna");
    expect(outcome.result).toContain("```json");
    expect(outcome.usage.provider).toBe("codex");
    expect(outcome.usage.search_calls).toBe(1);
    expect(outcome.usage.input_tokens).toBe(58843);
    expect(outcome.usage.output_tokens).toBe(219);
    expect(outcome.usage.cache_read_tokens).toBe(44288);
    expect(outcome.usage.cost_usd).toBe(0);
    expect(captured.some((l) => l.includes("thinking_delta"))).toBe(true);
  });

  it("winds down gracefully when codex yields no message", async () => {
    const captured: string[] = [];
    const outcome = await runCodex({
      ...BASE, emitter: new Emitter((l) => captured.push(l)), env: { QUORUM_CODEX_BIN: "/fake/codex" },
      spawn: fakeSpawn([]), now: () => 0,
    });
    expect(outcome.status).toBe("error");
    expect(outcome.result).toContain("```json");
    expect(captured.some((l) => l.includes(`"type":"result"`))).toBe(true);
  });

  it("surfaces a failed turn as an inconclusive outcome rather than a silent success", async () => {
    const outcome = await runCodex({
      ...BASE, emitter: new Emitter(() => {}), env: { QUORUM_CODEX_BIN: "/fake/codex" },
      spawn: fakeSpawn([
        `{"type":"thread.started","thread_id":"t1"}`,
        `{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":"partial"}}`,
        `{"type":"turn.failed","error":{"message":"usage limit reached"}}`,
      ]),
      now: () => 0,
    });
    expect(outcome.status).toBe("inconclusive");
    expect(outcome.note).toContain("usage limit reached");
  });

  it("hands the spawned CLI the evidence directory so its mcp-serve child captures into this run", async () => {
    const options: any[] = [];
    const inner = fakeSpawn(CODEX_STREAM);
    const spy = ((bin: string, args: string[], opts: any) => {
      options.push(opts);
      return (inner as any)(bin, args, opts);
    }) as unknown as SpawnFn;
    await runCodex({
      ...BASE, emitter: new Emitter(() => {}),
      env: { QUORUM_CODEX_BIN: "/fake/codex", QUORUM_TAVILY_KEY: "tk" },
      evidenceDir: "/runs/7/evidence", spawn: spy, now: () => 0,
    });
    expect(options[0].env.QUORUM_EVIDENCE_DIR).toBe("/runs/7/evidence");
    expect(options[0].env.QUORUM_TAVILY_KEY).toBe("tk");
  });

  it("is reached by dispatching a codex spec, without a price table or an API key", async () => {
    const outcome = await runTopic({
      angleId: "a1", role: "research", spec: "codex/sol",
      prompt: BASE.prompt, systemPrompt: BASE.systemPrompt, effort: "high",
      perTopicBudgetUsd: 1, timeoutMs: 10_000,
      env: { QUORUM_CODEX_BIN: "/fake/codex" },
      emitter: new Emitter(() => {}),
      deps: { spawn: fakeSpawn(CODEX_STREAM), now: () => 0 },
    });
    expect(outcome.backend).toBe("codex");
    expect(outcome.provider).toBe("codex");
    expect(outcome.model).toBe("gpt-5.6-sol");
    expect(outcome.status).toBe("complete");
  });

  it("serves the single-topic research command too, so the Swift executor can address it", async () => {
    const lines: any[] = [];
    await runEngine(
      { command: "research", prompt: BASE.prompt, model: "codex/terra", effort: "high" },
      { QUORUM_CODEX_BIN: "/fake/codex" },
      { emitter: new Emitter((l) => lines.push(JSON.parse(l.trimEnd()))), spawn: fakeSpawn(CODEX_STREAM), now: () => 0 },
    );
    const result = lines.find((l) => l.type === "result");
    expect(result).toBeDefined();
    expect(result.usage.provider).toBe("codex");
    expect(result.usage.model).toBe("gpt-5.6-terra");
    expect(lines.some((l) => l.type === "error")).toBe(false);
  });

  it("tallies own-search MCP calls the same way as the built-in search", async () => {
    const outcome = await runCodex({
      ...BASE, emitter: new Emitter(() => {}), env: { QUORUM_CODEX_BIN: "/fake/codex" },
      spawn: fakeSpawn([
        `{"type":"thread.started","thread_id":"t1"}`,
        `{"type":"item.completed","item":{"id":"c1","type":"mcp_tool_call","server":"quorum","tool":"web_search","status":"completed"}}`,
        `{"type":"item.completed","item":{"id":"c2","type":"mcp_tool_call","server":"quorum","tool":"web_fetch","status":"completed"}}`,
        `{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":"done"}}`,
        `{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":2}}`,
      ]),
      now: () => 0,
    });
    expect(outcome.usage.search_calls).toBe(1);
    expect(outcome.usage.fetch_calls).toBe(1);
  });

  it("does not count a failed tool call as a source consulted", async () => {
    const outcome = await runCodex({
      ...BASE, emitter: new Emitter(() => {}), env: { QUORUM_CODEX_BIN: "/fake/codex" },
      spawn: fakeSpawn([
        `{"type":"thread.started","thread_id":"t1"}`,
        `{"type":"item.completed","item":{"id":"c1","type":"mcp_tool_call","server":"quorum","tool":"web_search","status":"failed","error":{"message":"user cancelled MCP tool call"}}}`,
        `{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":"done"}}`,
        `{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":2}}`,
      ]),
      now: () => 0,
    });
    expect(outcome.usage.search_calls).toBe(0);
  });
});

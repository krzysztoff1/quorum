import { spawn as nodeSpawn, execFileSync, type ChildProcessByStdio } from "node:child_process";
import type { Readable } from "node:stream";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { Emitter, type UsageBlock } from "./emitter.js";
import { ClaudeNotFoundError } from "./errors.js";
import { hasSearchKey } from "./config.js";
import type { Env } from "./providers.js";

export type SpawnFn = typeof nodeSpawn;

export interface ClaudeCodeConfig {
  prompt: string;
  systemPrompt: string;
  role: "research" | "synthesis" | "verify" | "validate";
  effort: string;
  maxBudgetUsd: number;
  maxTurns: number;
  alias?: string;
  timeoutMs: number;
  emitter: Emitter;
  env: Env;
  signal?: AbortSignal;
  spawn?: SpawnFn;
  useProjectContext?: boolean;
  projectDir?: string;
  evidenceDir?: string;
  spawnDir?: string;
  angleID?: string;
  now?: () => number;
}

export interface ClaudeCodeOutcome {
  status: "complete" | "inconclusive" | "halted" | "error";
  result: string;
  note: string | null;
  usage: UsageBlock;
  sessionId: string;
  model: string;
}

export function parseClaudeCodeSpec(spec: string): { alias?: string } | null {
  if (spec === "claude-code") return {};
  if (spec.startsWith("claude-code/")) return { alias: spec.slice("claude-code/".length) };
  return null;
}

export function resolveClaudeBin(env: Env): string {
  if (env.QUORUM_CLAUDE_BIN) return env.QUORUM_CLAUDE_BIN;

  const home = env.HOME ?? "";
  const candidates = [
    ...(env.PATH ?? "").split(":").filter(Boolean).map((d) => join(d, "claude")),
    join(home, ".claude/local/claude"),
    join(home, ".local/bin/claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    "/usr/bin/claude",
  ];
  for (const c of candidates) if (c && existsSync(c)) return c;

  try {
    const shell = env.SHELL ?? "/bin/zsh";
    const out = execFileSync(shell, ["-lic", "command -v claude"], { encoding: "utf8" }).trim();
    const line = out.split("\n").map((l) => l.trim()).filter(Boolean).pop();
    if (line && existsSync(line)) return line;
  } catch {
    // fall through to the not-found error
  }
  throw new ClaudeNotFoundError();
}

export function selfMcpCommand(
  execPath: string = process.execPath,
  script: string | null = process.argv[1] ?? null,
): { command: string; args: string[] } {
  const compiled = !script || script === execPath || script.startsWith("/$bunfs/") || script.startsWith("B:\\~BUN");
  return compiled ? { command: execPath, args: ["mcp-serve"] } : { command: execPath, args: [script, "mcp-serve"] };
}

export function buildClaudeArgs(cfg: ClaudeCodeConfig): string[] {
  const tools = cfg.role !== "research"
    ? []
    : [
        ...(hasSearchKey(cfg.env) ? ["mcp__quorum__web_search"] : ["WebSearch"]),
        "mcp__quorum__web_fetch",
        ...(cfg.spawnDir ? ["mcp__quorum__spawn_inquiry"] : []),
        ...(cfg.useProjectContext ? ["Read", "Grep", "Glob"] : []),
      ];
  const args = [
    "-p", cfg.prompt,
    "--output-format", "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--permission-mode", "dontAsk",
    "--effort", cfg.effort,
    "--max-budget-usd", String(cfg.maxBudgetUsd),
    "--max-turns", String(cfg.maxTurns),
    "--tools", tools.join(","),
    "--allowedTools", tools.join(" "),
  ];
  if (cfg.alias) args.push("--model", cfg.alias);
  if (cfg.systemPrompt) args.push("--append-system-prompt", cfg.systemPrompt);

  if (cfg.role === "research") {
    const self = selfMcpCommand();
    const mcpConfig = JSON.stringify({ mcpServers: { quorum: { command: self.command, args: self.args } } });
    args.push("--mcp-config", mcpConfig);
  }

  if (cfg.role === "research" && cfg.useProjectContext && cfg.projectDir) args.push("--add-dir", cfg.projectDir);
  return args;
}

/// The CLI's environment. The evidence directory rides through it because the CLI's own `mcp-serve` child —
/// the process that actually fetches for this angle — inherits it and appends its captures there. The spawn
/// directory and angle id ride along for the same reason: that child is where questions get raised.
function spawnEnv(cfg: ClaudeCodeConfig): Env {
  return {
    ...cfg.env,
    ...(cfg.evidenceDir ? { QUORUM_EVIDENCE_DIR: cfg.evidenceDir } : {}),
    ...(cfg.spawnDir ? { QUORUM_SPAWN_DIR: cfg.spawnDir, QUORUM_ANGLE_ID: cfg.angleID ?? "" } : {}),
  };
}

function normalizeToolName(name: string): string {
  const n = name.toLowerCase();
  if (n.includes("fetch")) return "web_fetch";
  if (n.includes("search")) return "web_search";
  return name;
}

interface Tally {
  cost: number;
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  searches: number;
  fetches: number;
}

function usageBlock(tally: Tally, model: string): UsageBlock {
  return {
    provider: "claude-code",
    model,
    input_tokens: tally.input,
    output_tokens: tally.output,
    cache_read_tokens: tally.cacheRead,
    cache_write_tokens: tally.cacheWrite,
    cost_usd: tally.cost,
    search_calls: tally.searches,
    fetch_calls: tally.fetches,
  };
}

export async function runClaudeCode(cfg: ClaudeCodeConfig): Promise<ClaudeCodeOutcome> {
  const now = cfg.now ?? Date.now;
  const spawnFn = cfg.spawn ?? nodeSpawn;
  const emitter = cfg.emitter;

  let bin: string;
  try {
    bin = resolveClaudeBin(cfg.env);
  } catch (e) {
    return inconclusive(cfg, "sonnet", errorMessage(e), "error");
  }

  const child: ChildProcessByStdio<null, Readable, Readable> = spawnFn(bin, buildClaudeArgs(cfg), {
    env: spawnEnv(cfg) as NodeJS.ProcessEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });

  const tally: Tally = { cost: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, searches: 0, fetches: 0 };
  let sessionId = "";
  let model = cfg.alias ?? "sonnet";
  let resultText = "";
  let sawResult = false;
  const state = { aborted: false, timedOut: false, errored: false, resultInconclusive: false, note: null as string | null };

  const kill = () => {
    try {
      child.kill("SIGTERM");
    } catch {
      // already gone
    }
  };

  const deadline = now() + cfg.timeoutMs;
  const timer = setInterval(() => {
    if (now() >= deadline) {
      state.timedOut = true;
      state.note ??= `Time limit reached; returning partial output.`;
      kill();
    }
  }, 50);

  const onAbort = () => {
    state.aborted = true;
    state.note ??= `Run halted; returning partial output.`;
    kill();
  };
  if (cfg.signal) {
    if (cfg.signal.aborted) onAbort();
    else cfg.signal.addEventListener("abort", onAbort, { once: true });
  }

  const handleLine = (raw: string) => {
    const trimmed = raw.trim();
    if (!trimmed) return;
    let msg: any;
    try {
      msg = JSON.parse(trimmed);
    } catch {
      return;
    }

    if (typeof msg.session_id === "string" && msg.session_id) sessionId = msg.session_id;
    if (typeof msg.total_cost_usd === "number") tally.cost = msg.total_cost_usd;

    if (msg.type === "system" && msg.subtype === "init") {
      if (typeof msg.model === "string") model = msg.model;
      return;
    }

    if (msg.type === "stream_event") {
      const delta = msg.event?.delta;
      if (delta?.type === "text_delta" && typeof delta.text === "string") emitter.textDelta(delta.text);
      else if (delta?.type === "thinking_delta" && typeof delta.thinking === "string") emitter.thinkingDelta(delta.thinking);
      return;
    }

    if (msg.type === "assistant") {
      const content = msg.message?.content ?? [];
      for (const block of content) {
        if (block?.type === "tool_use") {
          const norm = normalizeToolName(block.name ?? "");
          if (norm === "web_search") tally.searches += 1;
          else if (norm === "web_fetch") tally.fetches += 1;
          emitter.toolUse(norm, block.input ?? {});
        }
      }
      const u = msg.message?.usage;
      if (u) {
        tally.input += u.input_tokens ?? 0;
        tally.output += u.output_tokens ?? 0;
        tally.cacheRead += u.cache_read_input_tokens ?? 0;
        tally.cacheWrite += u.cache_creation_input_tokens ?? 0;
        if (typeof msg.message?.model === "string") model = msg.message.model;
        emitter.usage(tally.cost, usageBlock(tally, model));
      }
      return;
    }

    if (msg.type === "result") {
      sawResult = true;
      if (typeof msg.result === "string") resultText = msg.result;
      if (typeof msg.total_cost_usd === "number") tally.cost = msg.total_cost_usd;
      const u = msg.usage;
      if (u) {
        tally.input = Math.max(tally.input, u.input_tokens ?? tally.input);
        tally.output = Math.max(tally.output, u.output_tokens ?? tally.output);
        tally.cacheRead = Math.max(tally.cacheRead, u.cache_read_input_tokens ?? tally.cacheRead);
        tally.cacheWrite = Math.max(tally.cacheWrite, u.cache_creation_input_tokens ?? tally.cacheWrite);
      }
      if (msg.subtype && msg.subtype !== "success") {
        state.resultInconclusive = true;
        state.note ??= `Claude CLI ended with subtype "${msg.subtype}".`;
      }
    }
  };

  await pumpLines(child, handleLine).catch((e) => {
    state.errored = true;
    state.note ??= errorMessage(e);
  });

  clearInterval(timer);
  cfg.signal?.removeEventListener("abort", onAbort);

  if (!sessionId) sessionId = `qeng-${randomUUID()}`;

  if (!sawResult && !state.aborted && !state.timedOut) {
    state.errored = true;
    state.note ??= "Claude CLI produced no result.";
  }

  const status: ClaudeCodeOutcome["status"] = state.aborted
    ? "halted"
    : state.errored
    ? "error"
    : state.timedOut || state.resultInconclusive
    ? "inconclusive"
    : "complete";
  const note = state.note;

  const usage = usageBlock(tally, model);
  const finalText =
    resultText.trim() ||
    (status === "halted" ? "The run was halted before Claude produced output." : "Claude produced no output.");
  const result = ensureFencedSummary(finalText, status, usage.search_calls || usage.fetch_calls, note);
  emitter.result(sessionId, tally.cost, result, usage);

  return { status, result, note, usage, sessionId, model };
}

function inconclusive(cfg: ClaudeCodeConfig, model: string, note: string, status: ClaudeCodeOutcome["status"]): ClaudeCodeOutcome {
  const sessionId = `qeng-${randomUUID()}`;
  const usage = usageBlock({ cost: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, searches: 0, fetches: 0 }, model);
  const result = ensureFencedSummary("Claude Code backend could not run.", "inconclusive", 0, note);
  cfg.emitter.error(note, "claude-code");
  cfg.emitter.result(sessionId, 0, result, usage);
  return { status, result, note, usage, sessionId, model };
}

function pumpLines(child: ChildProcessByStdio<null, Readable, Readable>, onLine: (line: string) => void): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    let buffer = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      buffer += chunk;
      let nl: number;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        onLine(buffer.slice(0, nl));
        buffer = buffer.slice(nl + 1);
      }
    });
    child.on("error", reject);
    child.on("close", () => {
      if (buffer.length > 0) onLine(buffer);
      resolve();
    });
  });
}

function hasFencedJson(text: string): boolean {
  const open = text.lastIndexOf("```json");
  return open !== -1 && text.indexOf("```", open + 7) !== -1;
}

function ensureFencedSummary(text: string, status: ClaudeCodeOutcome["status"], sources: number, note: string | null): string {
  if (hasFencedJson(text)) return text;
  const summaryStatus = status === "complete" ? "complete" : "inconclusive";
  const summary: Record<string, unknown> = {
    headline: status === "complete" ? "Research complete" : "Research incomplete",
    status: summaryStatus,
    sourcesConsulted: sources,
    findings: [],
  };
  if (note) summary.note = note;
  return text + "\n\n```json\n" + JSON.stringify(summary) + "\n```";
}

function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

import { spawn as nodeSpawn, execFileSync, type ChildProcessByStdio } from "node:child_process";
import type { Readable } from "node:stream";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { Emitter, type UsageBlock } from "./emitter.js";
import { CodexNotFoundError } from "./errors.js";
import { hasSearchKey } from "./config.js";
import { selfMcpCommand, type SpawnFn } from "./claudeCode.js";
import type { Env } from "./providers.js";

export const CODEX_ALIASES: Record<string, string> = {
  luna: "gpt-5.6-luna",
  terra: "gpt-5.6-terra",
  sol: "gpt-5.6-sol",
};

export const DEFAULT_CODEX_ALIAS = "terra";

const EFFORT_LADDER = ["low", "medium", "high", "xhigh", "max", "ultra"];

const SUPPORTED_EFFORTS: Record<string, string[]> = {
  "gpt-5.6-luna": ["low", "medium", "high", "xhigh", "max"],
  "gpt-5.6-terra": EFFORT_LADDER,
  "gpt-5.6-sol": EFFORT_LADDER,
};

/// `codex exec` offers no spend cap and no turn cap — it is a flat-rate subscription runner — so the
/// per-topic wall is the timeout, and nothing here pretends otherwise.
export interface CodexConfig {
  prompt: string;
  systemPrompt: string;
  role: "research" | "synthesis" | "verify" | "validate";
  effort: string;
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

export interface CodexOutcome {
  status: "complete" | "inconclusive" | "halted" | "error";
  result: string;
  note: string | null;
  usage: UsageBlock;
  sessionId: string;
  model: string;
}

export function parseCodexSpec(spec: string): { alias?: string } | null {
  if (spec === "codex") return {};
  if (spec.startsWith("codex/")) return { alias: spec.slice("codex/".length) };
  return null;
}

export function resolveCodexModel(alias: string | undefined): string {
  const named = alias?.trim() || DEFAULT_CODEX_ALIAS;
  return CODEX_ALIASES[named.toLowerCase()] ?? named;
}

export function codexReasoningEffort(effort: string, model: string): string {
  const supported = SUPPORTED_EFFORTS[model] ?? EFFORT_LADDER;
  const wanted = EFFORT_LADDER.indexOf((effort ?? "").toLowerCase());
  if (wanted === -1) return "medium";
  for (let i = wanted; i >= 0; i--) {
    const level = EFFORT_LADDER[i]!;
    if (supported.includes(level)) return level;
  }
  return "medium";
}

export function resolveCodexBin(env: Env): string {
  if (env.QUORUM_CODEX_BIN) return env.QUORUM_CODEX_BIN;

  const home = env.HOME ?? "";
  const candidates = [
    ...(env.PATH ?? "").split(":").filter(Boolean).map((d) => join(d, "codex")),
    join(home, ".codex/bin/codex"),
    join(home, ".local/bin/codex"),
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
    "/usr/bin/codex",
  ];
  for (const c of candidates) if (c && existsSync(c)) return c;

  try {
    const shell = env.SHELL ?? "/bin/zsh";
    const out = execFileSync(shell, ["-lic", "command -v codex"], { encoding: "utf8" }).trim();
    const line = out.split("\n").map((l) => l.trim()).filter(Boolean).pop();
    if (line && existsSync(line)) return line;
  } catch {
    // fall through to the not-found error
  }
  throw new CodexNotFoundError();
}

function tomlString(value: string): string {
  return JSON.stringify(value);
}

export function foldSystemPrompt(systemPrompt: string, prompt: string): string {
  const instructions = systemPrompt.trim();
  return instructions ? `${instructions}\n\n---\n\n${prompt}` : prompt;
}

export function buildCodexArgs(cfg: CodexConfig): string[] {
  const model = resolveCodexModel(cfg.alias);
  const hasOwnSearch = hasSearchKey(cfg.env);
  const research = cfg.role === "research";
  const ownSearch = research && hasOwnSearch;
  const builtinSearch = research && !hasOwnSearch;

  const args = [
    "exec",
    "--json",
    "--skip-git-repo-check",
    "-s", "read-only",
    "-m", model,
    "-c", `model_reasoning_effort=${tomlString(codexReasoningEffort(cfg.effort, model))}`,
    "-c", `tools.web_search=${builtinSearch}`,
  ];

  if (ownSearch) {
    const self = selfMcpCommand();
    args.push("-c", `mcp_servers.quorum.command=${tomlString(self.command)}`);
    args.push("-c", `mcp_servers.quorum.args=${JSON.stringify(self.args)}`);
  }

  if (research && cfg.useProjectContext && cfg.projectDir) args.push("-C", cfg.projectDir);

  args.push(foldSystemPrompt(cfg.systemPrompt, cfg.prompt));
  return args;
}

function spawnEnv(cfg: CodexConfig): Env {
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
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  searches: number;
  fetches: number;
}

/// Codex runs on the OpenAI subscription (OAuth in the CLI, no metered key), so the marginal dollar cost
/// of a topic is zero. Tokens are still tallied — they are what the weekly limit actually spends.
function usageBlock(tally: Tally, model: string): UsageBlock {
  return {
    provider: "codex",
    model,
    input_tokens: tally.input,
    output_tokens: tally.output,
    cache_read_tokens: tally.cacheRead,
    cache_write_tokens: tally.cacheWrite,
    cost_usd: 0,
    search_calls: tally.searches,
    fetch_calls: tally.fetches,
  };
}

export async function runCodex(cfg: CodexConfig): Promise<CodexOutcome> {
  const now = cfg.now ?? Date.now;
  const spawnFn = cfg.spawn ?? nodeSpawn;
  const emitter = cfg.emitter;
  const model = resolveCodexModel(cfg.alias);

  let bin: string;
  try {
    bin = resolveCodexBin(cfg.env);
  } catch (e) {
    return unrunnable(cfg, model, errorMessage(e));
  }

  const child: ChildProcessByStdio<null, Readable, Readable> = spawnFn(bin, buildCodexArgs(cfg), {
    env: spawnEnv(cfg) as NodeJS.ProcessEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });

  const tally: Tally = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, searches: 0, fetches: 0 };
  let sessionId = "";
  let resultText = "";
  let sawMessage = false;
  const state = { aborted: false, timedOut: false, errored: false, turnFailed: false, note: null as string | null };

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

  const handleItem = (item: any) => {
    switch (item?.type) {
      case "reasoning": {
        const text = item.text ?? item.summary ?? "";
        if (text) emitter.thinkingDelta(String(text));
        return;
      }
      case "agent_message": {
        const text = String(item.text ?? "");
        if (!text) return;
        sawMessage = true;
        resultText = resultText ? `${resultText}\n\n${text}` : text;
        emitter.textDelta(text);
        return;
      }
      case "web_search": {
        tally.searches += 1;
        emitter.toolUse("web_search", { query: item.query ?? item.action?.query ?? "" });
        return;
      }
      case "mcp_tool_call": {
        const norm = normalizeToolName(String(item.tool ?? item.name ?? ""));
        emitter.toolUse(norm, item.arguments ?? {});
        if (item.status === "failed" || item.error) return;
        if (norm === "web_search") tally.searches += 1;
        else if (norm === "web_fetch") tally.fetches += 1;
        return;
      }
      case "error": {
        state.note ??= String(item.message ?? "Codex reported an error.");
        return;
      }
      default:
        return;
    }
  };

  const handleLine = (raw: string) => {
    const trimmed = raw.trim();
    if (!trimmed.startsWith("{")) return;
    let msg: any;
    try {
      msg = JSON.parse(trimmed);
    } catch {
      return;
    }

    switch (msg.type) {
      case "thread.started":
        if (typeof msg.thread_id === "string" && msg.thread_id) sessionId = msg.thread_id;
        return;
      case "item.completed":
        handleItem(msg.item);
        return;
      case "turn.completed": {
        const u = msg.usage;
        if (!u) return;
        tally.input += u.input_tokens ?? 0;
        tally.output += u.output_tokens ?? 0;
        tally.cacheRead += u.cached_input_tokens ?? 0;
        tally.cacheWrite += u.cache_write_input_tokens ?? 0;
        emitter.usage(0, usageBlock(tally, model));
        return;
      }
      case "turn.failed":
        state.turnFailed = true;
        state.note ??= String(msg.error?.message ?? "Codex ended the turn without finishing.");
        return;
      case "error":
        state.note ??= String(msg.message ?? msg.error?.message ?? "Codex reported an error.");
        return;
      default:
        return;
    }
  };

  await pumpLines(child, handleLine).catch((e) => {
    state.errored = true;
    state.note ??= errorMessage(e);
  });

  clearInterval(timer);
  cfg.signal?.removeEventListener("abort", onAbort);

  if (!sessionId) sessionId = `qcdx-${randomUUID()}`;

  if (!sawMessage && !state.aborted && !state.timedOut && !state.turnFailed) {
    state.errored = true;
    state.note ??= "Codex CLI produced no message.";
  }

  const status: CodexOutcome["status"] = state.aborted
    ? "halted"
    : state.errored
    ? "error"
    : state.timedOut || state.turnFailed
    ? "inconclusive"
    : "complete";
  const note = state.note;

  const usage = usageBlock(tally, model);
  const finalText =
    resultText.trim() ||
    (status === "halted" ? "The run was halted before Codex produced output." : "Codex produced no output.");
  const result = ensureFencedSummary(finalText, status, usage.search_calls || usage.fetch_calls, note);
  emitter.result(sessionId, 0, result, usage);

  return { status, result, note, usage, sessionId, model };
}

function unrunnable(cfg: CodexConfig, model: string, note: string): CodexOutcome {
  const sessionId = `qcdx-${randomUUID()}`;
  const usage = usageBlock({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, searches: 0, fetches: 0 }, model);
  const result = ensureFencedSummary("Codex backend could not run.", "inconclusive", 0, note);
  cfg.emitter.error(note, "codex");
  cfg.emitter.result(sessionId, 0, result, usage);
  return { status: "error", result, note, usage, sessionId, model };
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

function ensureFencedSummary(text: string, status: CodexOutcome["status"], sources: number, note: string | null): string {
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

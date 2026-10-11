import type { SettledAnswer } from "./answer/index.js";
import { randomUUID } from "node:crypto";
import { Emitter, type Sink, type UsageBlock } from "./emitter.js";
import { resolveEffort, type Env } from "./providers.js";
import type { EvidenceStore, Citation } from "./evidence.js";
import { runClaudeCode, parseClaudeCodeSpec, type SpawnFn } from "./claudeCode.js";
import type { Refusal } from "./refusal.js";
import type { RateLimitWindow } from "./ratelimit.js";

export interface TopicOutcome {
  angle_id: string;
  role: "research" | "synthesis" | "verify" | "validate" | "plan";
  backend: "cli";
  provider: string;
  model: string;
  session_id: string;
  status: "complete" | "inconclusive" | "halted" | "error";
  result: string;
  usage: UsageBlock;
  note: string | null;
  citations?: Citation[];
  reconciled?: boolean;
  refusal?: Refusal;
  answer?: SettledAnswer;
}

export interface RunBackendDeps {
  runClaudeCode?: typeof runClaudeCode;
  spawn?: SpawnFn;
  now?: () => number;
}

export interface RunTopicConfig {
  angleId: string;
  role: "research" | "synthesis" | "verify" | "validate" | "plan";
  spec: string;
  prompt: string;
  systemPrompt: string;
  effort: string;
  perTopicBudgetUsd: number;
  timeoutMs: number;
  maxTurns?: number;
  env: Env;
  emitter: Emitter;
  signal?: AbortSignal;
  useProjectContext?: boolean;
  projectDir?: string;
  evidence?: EvidenceStore;
  evidenceDir?: string;
  deps: RunBackendDeps;
  onRateLimit?: (window: RateLimitWindow) => void;
}

export function angleEmitter(sink: Sink, angleId: string): Emitter {
  return new (class extends Emitter {
    constructor() {
      super(sink, { angle_id: angleId });
    }
    result(): void {}
  })();
}

export async function runTopic(cfg: RunTopicConfig): Promise<TopicOutcome> {
  const claudeSpec = parseClaudeCodeSpec(cfg.spec);
  if (!claudeSpec) throw new Error(`Unsupported model "${cfg.spec}": only the Claude subscription (claude-code/…) is available.`);
  return runCliTopic(cfg, claudeSpec.alias);
}

async function runCliTopic(cfg: RunTopicConfig, alias: string | undefined): Promise<TopicOutcome> {
  const cc = await (cfg.deps.runClaudeCode ?? runClaudeCode)({
    prompt: cfg.prompt,
    systemPrompt: cfg.systemPrompt,
    role: cfg.role,
    effort: cfg.effort,
    maxBudgetUsd: cfg.perTopicBudgetUsd,
    maxTurns: cfg.maxTurns ?? resolveEffort(cfg.effort).maxSteps,
    alias,
    timeoutMs: cfg.timeoutMs,
    emitter: cfg.emitter,
    env: cfg.env,
    signal: cfg.signal,
    spawn: cfg.deps.spawn,
    useProjectContext: cfg.useProjectContext,
    projectDir: cfg.projectDir,
    ...(cfg.evidenceDir === undefined ? {} : { evidenceDir: cfg.evidenceDir }),
    now: cfg.deps.now,
    ...(cfg.onRateLimit ? { onRateLimit: cfg.onRateLimit } : {}),
  });
  return {
    angle_id: cfg.angleId,
    role: cfg.role,
    backend: "cli",
    provider: "claude-code",
    model: cc.model,
    session_id: cc.sessionId,
    status: cc.status,
    result: cc.result,
    usage: cc.usage,
    note: cc.note,
    ...(cc.refusal ? { refusal: cc.refusal } : {}),
  };
}

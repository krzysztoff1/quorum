import type { CaptureFailure, SourceDocument } from "./evidence.js";
import { RECORD_SCHEMA } from "./record/schema.js";

export const ENGINE_NAME = "quorum-engine";
export const ENGINE_VERSION = "0.1.0";
export const PROTOCOL_VERSION = 5;

declare const QUORUM_ENGINE_BUILD: string | undefined;
export const ENGINE_BUILD: string =
  typeof QUORUM_ENGINE_BUILD === "string" && QUORUM_ENGINE_BUILD ? QUORUM_ENGINE_BUILD : "source";

export function versionLine(): string {
  return JSON.stringify({
    type: "version",
    engine: ENGINE_NAME,
    engine_version: ENGINE_VERSION,
    protocol_version: PROTOCOL_VERSION,
    record_schema: RECORD_SCHEMA,
    build: ENGINE_BUILD,
  }) + "\n";
}

export type GraphNodeKind =
  | "question" | "inquiry" | "source" | "finding" | "conflict" | "gap" | "synthesis" | "verification"
  | "verdict";

export type GraphNodeOrigin =
  | "root" | "planner" | "followup" | "spawn" | "dig" | "objection" | "derived";

export interface GraphNodeLine {
  id: string;
  kind: GraphNodeKind;
  title: string;
  parent_ids: string[];
  depth: number;
  round: number;
  status: string;
  origin: GraphNodeOrigin;
  meta?: Record<string, unknown>;
}

export interface GraphEdgeLine {
  from: string;
  to: string;
  kind: string;
  label?: string;
}

export interface UsageBlock {
  provider: string;
  model: string;
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  cache_write_tokens: number;
  cost_usd: number;
  search_calls: number;
  fetch_calls: number;
}

export type Sink = (line: string) => void;

export class Emitter {
  constructor(
    private readonly sink: Sink = (line) => process.stdout.write(line),
    private readonly extra: Record<string, unknown> = {}
  ) {}

  line(obj: unknown): void {
    this.sink(JSON.stringify({ ...(obj as Record<string, unknown>), ...this.extra }) + "\n");
  }

  private write(obj: unknown): void {
    this.line(obj);
  }

  init(sessionId: string, model: string): void {
    this.write({
      type: "system",
      subtype: "init",
      engine: ENGINE_NAME,
      engine_version: ENGINE_VERSION,
      protocol_version: PROTOCOL_VERSION,
      session_id: sessionId,
      model,
    });
  }

  textDelta(text: string): void {
    this.write({
      type: "stream_event",
      event: { type: "content_block_delta", delta: { type: "text_delta", text } },
    });
  }

  thinkingDelta(thinking: string): void {
    this.write({
      type: "stream_event",
      event: { type: "content_block_delta", delta: { type: "thinking_delta", thinking } },
    });
  }

  toolUse(name: string, input: unknown): void {
    this.write({
      type: "assistant",
      message: { content: [{ type: "tool_use", name, input }] },
    });
  }

  /// A source captured at research time, announced once per newly registered document.
  document(document: SourceDocument): void {
    this.write({ type: "document", document });
  }

  captureFailure(failure: CaptureFailure): void {
    this.write({ type: "capture_failure", failure });
  }

  /// The run's shape as it grows. Only the orchestrator emits these — a model may ask for a node, never
  /// declare one — so what the app draws is what actually happened.
  graphNode(node: GraphNodeLine): void {
    this.write({ type: "graph_node", node });
  }

  graphEdge(edge: GraphEdgeLine): void {
    this.write({ type: "graph_edge", edge });
  }

  graphNodeUpdate(id: string, status: string, meta?: Record<string, unknown>): void {
    this.write({ type: "graph_node_update", id, status, ...(meta ? { meta } : {}) });
  }

  usage(totalCostUsd: number, usage: UsageBlock): void {
    this.write({ type: "usage", total_cost_usd: totalCostUsd, usage });
  }

  result(sessionId: string, totalCostUsd: number, result: string, usage: UsageBlock): void {
    this.write({
      type: "result",
      subtype: "success",
      total_cost_usd: totalCostUsd,
      session_id: sessionId,
      result,
      usage,
    });
  }

  error(error: string, provider?: string): void {
    this.write(provider === undefined ? { type: "error", error } : { type: "error", error, provider });
  }
}

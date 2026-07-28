import type { SourceDocument } from "./evidence.js";

export const ENGINE_NAME = "quorum-engine";
export const ENGINE_VERSION = "0.1.0";
export const PROTOCOL_VERSION = 2;

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

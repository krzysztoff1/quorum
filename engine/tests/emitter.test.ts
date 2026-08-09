import { describe, it, expect } from "vitest";
import { Emitter } from "../src/emitter.js";

function capture() {
  const lines: any[] = [];
  const raw: string[] = [];
  const emitter = new Emitter((line) => {
    raw.push(line);
    lines.push(JSON.parse(line.trimEnd()));
  });
  return { emitter, lines, raw };
}

describe("Emitter", () => {
  it("each emit writes exactly one newline-terminated JSON line", () => {
    const { emitter, raw } = capture();
    emitter.init("sess-1", "deepseek/deepseek-chat");
    emitter.textDelta("hi");
    expect(raw).toHaveLength(2);
    for (const line of raw) {
      expect(line.endsWith("\n")).toBe(true);
      expect(line.slice(0, -1)).not.toContain("\n");
      expect(() => JSON.parse(line)).not.toThrow();
    }
  });

  it("init handshake carries engine identity and protocol version", () => {
    const { emitter, lines } = capture();
    emitter.init("sess-1", "deepseek/deepseek-chat");
    expect(lines[0]).toMatchObject({
      type: "system",
      subtype: "init",
      engine: "quorum-engine",
      protocol_version: 3,
      session_id: "sess-1",
      model: "deepseek/deepseek-chat",
    });
    expect(typeof lines[0].engine_version).toBe("string");
  });

  it("document announces a captured source under the evidence field names Swift decodes", () => {
    const { emitter, lines } = capture();
    emitter.document({
      source_id: "s3",
      url: "https://nature.example/paper.pdf",
      title: "Paper",
      content_type: "pdf",
      fetched_at: "2026-07-27T10:00:00.000Z",
      snapshot_path: "sources/s3.md",
      original_path: "sources/s3.pdf",
      text_length: 48213,
      byte_size: 1048576,
      page_offsets: [0, 1820, 3944],
    });
    expect(lines[0]).toEqual({
      type: "document",
      document: {
        source_id: "s3",
        url: "https://nature.example/paper.pdf",
        title: "Paper",
        content_type: "pdf",
        fetched_at: "2026-07-27T10:00:00.000Z",
        snapshot_path: "sources/s3.md",
        original_path: "sources/s3.pdf",
        text_length: 48213,
        byte_size: 1048576,
        page_offsets: [0, 1820, 3944],
      },
    });
  });

  it("namespaces a document by angle when the emitter carries an angle id", () => {
    const lines: any[] = [];
    const angle = new Emitter((line) => lines.push(JSON.parse(line.trimEnd())), { angle_id: "a2" });
    angle.document({
      source_id: "s1", url: "https://ex.test", title: "", content_type: "text", fetched_at: null,
      snapshot_path: null, original_path: null, text_length: 0, byte_size: 0, page_offsets: [],
    });
    expect(lines[0].type).toBe("document");
    expect(lines[0].angle_id).toBe("a2");
  });

  it("text delta uses stream_event/content_block_delta/text_delta shape the Swift parser reads", () => {
    const { emitter, lines } = capture();
    emitter.textDelta("partial");
    expect(lines[0]).toEqual({
      type: "stream_event",
      event: { type: "content_block_delta", delta: { type: "text_delta", text: "partial" } },
    });
  });

  it("thinking delta uses thinking_delta with a thinking field", () => {
    const { emitter, lines } = capture();
    emitter.thinkingDelta("pondering");
    expect(lines[0].event.delta).toEqual({ type: "thinking_delta", thinking: "pondering" });
  });

  it("tool_use nests under assistant.message.content with name and input", () => {
    const { emitter, lines } = capture();
    emitter.toolUse("web_search", { query: "quorum" });
    expect(lines[0]).toEqual({
      type: "assistant",
      message: { content: [{ type: "tool_use", name: "web_search", input: { query: "quorum" } }] },
    });
  });

  it("usage line carries cumulative total_cost_usd and a per-step usage block", () => {
    const { emitter, lines } = capture();
    emitter.usage(0.0031, {
      provider: "deepseek",
      model: "deepseek-chat",
      input_tokens: 1200,
      output_tokens: 800,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      cost_usd: 0.0007,
      search_calls: 1,
      fetch_calls: 0,
    });
    expect(lines[0].type).toBe("usage");
    expect(lines[0].total_cost_usd).toBe(0.0031);
    expect(lines[0].usage.provider).toBe("deepseek");
    expect(lines[0].usage.search_calls).toBe(1);
  });

  it("result carries the full writeup and run totals", () => {
    const { emitter, lines } = capture();
    emitter.result("sess-1", 0.0142, "writeup ```json\n{}```", {
      provider: "deepseek",
      model: "deepseek-chat",
      input_tokens: 5000,
      output_tokens: 3200,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      cost_usd: 0.0142,
      search_calls: 4,
      fetch_calls: 6,
    });
    expect(lines[0]).toMatchObject({
      type: "result",
      subtype: "success",
      total_cost_usd: 0.0142,
      session_id: "sess-1",
    });
    expect(lines[0].result).toContain("writeup");
    expect(lines[0].usage.search_calls).toBe(4);
  });

  it("error names the provider", () => {
    const { emitter, lines } = capture();
    emitter.error("missing key", "anthropic");
    expect(lines[0]).toEqual({ type: "error", error: "missing key", provider: "anthropic" });
  });
});

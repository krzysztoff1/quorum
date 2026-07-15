import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { recordFixtureLines, FIXTURE_PATH } from "../src/record-fixture.js";

const raw = readFileSync(FIXTURE_PATH, "utf8");
const lines = raw.split("\n").filter((l) => l.length > 0);
const events = lines.map((l) => JSON.parse(l));

describe("golden transcript fixture (R7 / shared with the Swift ResearchOutputParser)", () => {
  it("every line is valid standalone JSON (NDJSON)", () => {
    for (const line of lines) expect(() => JSON.parse(line)).not.toThrow();
    expect(events.length).toBeGreaterThanOrEqual(8);
  });

  it("first line is the init handshake announcing engine + protocol version", () => {
    expect(events[0]).toMatchObject({
      type: "system",
      subtype: "init",
      engine: "quorum-engine",
      protocol_version: 1,
    });
    expect(typeof events[0].session_id).toBe("string");
    expect(typeof events[0].model).toBe("string");
  });

  it("contains text deltas in the shape the Swift parser reads", () => {
    const deltas = events.filter(
      (e) => e.type === "stream_event" && e.event?.delta?.type === "text_delta"
    );
    expect(deltas.length).toBeGreaterThan(0);
    for (const d of deltas) expect(typeof d.event.delta.text).toBe("string");
  });

  it("contains at least one web_search and one web_fetch tool_use with parser-visible inputs", () => {
    const tools = events
      .filter((e) => e.type === "assistant")
      .map((e) => e.message.content[0]);
    const search = tools.find((t) => t.name === "web_search");
    const fetch = tools.find((t) => t.name === "web_fetch");
    expect(search?.type).toBe("tool_use");
    expect(typeof search?.input.query).toBe("string");
    expect(fetch?.type).toBe("tool_use");
    expect(typeof fetch?.input.url).toBe("string");
  });

  it("has >= 2 usage events with monotonically increasing cumulative total_cost_usd", () => {
    const usages = events.filter((e) => e.type === "usage");
    expect(usages.length).toBeGreaterThanOrEqual(2);
    for (let i = 1; i < usages.length; i++) {
      expect(usages[i].total_cost_usd).toBeGreaterThan(usages[i - 1].total_cost_usd);
    }
    for (const u of usages) {
      expect(u.usage.provider).toBeTruthy();
      expect(typeof u.usage.input_tokens).toBe("number");
      expect(typeof u.usage.cost_usd).toBe("number");
    }
  });

  it("final event is a result whose writeup ends with a valid fenced json summary (>=1 finding)", () => {
    const result = events[events.length - 1];
    expect(result).toMatchObject({ type: "result", subtype: "success" });
    expect(typeof result.session_id).toBe("string");
    expect(result.total_cost_usd).toBeGreaterThan(0);
    expect(result.result).toContain("## Sources");

    const open = result.result.lastIndexOf("```json");
    const close = result.result.indexOf("```", open + 7);
    const summary = JSON.parse(result.result.slice(open + 7, close));
    expect(summary.status).toBe("complete");
    expect(summary.findings.length).toBeGreaterThanOrEqual(1);
    for (const f of summary.findings) {
      expect(typeof f.claim).toBe("string");
      expect(Array.isArray(f.sources)).toBe(true);
    }
    expect(result.usage.search_calls).toBeGreaterThanOrEqual(1);
    expect(result.usage.fetch_calls).toBeGreaterThanOrEqual(1);
  });

  it("the committed fixture matches a fresh deterministic recording (regenerate with `bun run record:fixture`)", async () => {
    const fresh = (await recordFixtureLines()).join("");
    expect(fresh).toBe(raw);
  });
});

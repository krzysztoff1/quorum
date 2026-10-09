import { describe, it, expect } from "vitest";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { createMcpServer, evidenceStoreFor } from "../src/mcp.js";
import { FetchFailure } from "../src/directFetch.js";
import { EvidenceStore } from "../src/evidence.js";
import type { SearchLike } from "../src/agent.js";

const fakeSearch: SearchLike = {
  search: async (query) => ({ results: [{ title: "Doc", url: "https://ex/1", snippet: "about " + query }] }),
  fetch: async (url) => ({ url, markdown: "# Doc\n\nbody for " + url }),
};

async function connectedClient(search: SearchLike, evidence?: EvidenceStore, options?: { webSearch?: boolean }) {
  const server = createMcpServer(search, evidence ?? new EvidenceStore(), undefined, options);
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);
  const client = new Client({ name: "test", version: "0" });
  await client.connect(clientTransport);
  return client;
}

describe("mcp-serve (acceptance criterion 4)", () => {
  it("exposes web_search and web_fetch over stdio MCP", async () => {
    const client = await connectedClient(fakeSearch);
    const names = (await client.listTools()).tools.map((t) => t.name);
    expect(names).toContain("web_search");
    expect(names).toContain("web_fetch");
  });

  it("round-trips a web_search call against the shared backend", async () => {
    const client = await connectedClient(fakeSearch);
    const res: any = await client.callTool({ name: "web_search", arguments: { query: "fusion" } });
    const text = res.content.map((c: any) => c.text).join("");
    expect(text).toContain("https://ex/1");
    expect(text).toContain("fusion");
  });

  it("round-trips a web_fetch call against the shared backend", async () => {
    const client = await connectedClient(fakeSearch);
    const res: any = await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/1" } });
    const text = res.content.map((c: any) => c.text).join("");
    expect(text).toContain("body for https://ex/1");
  });
});

describe("mcp-serve evidence capture (what makes subscription-mode runs verifiable)", () => {
  it("captures the fetched document and tells the model the source_id to cite", async () => {
    const evidence = new EvidenceStore({ now: () => 0 });
    const client = await connectedClient(fakeSearch, evidence);
    const res: any = await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/1" } });
    const text = res.content.map((c: any) => c.text).join("");

    const document = evidence.findByUrl("https://ex/1");
    expect(document).toBeDefined();
    expect(text).toContain(`source_id: ${document!.source_id}`);
    expect(text).toContain("body for https://ex/1");
    expect(evidence.resolveCitation({ id: "c1", source: document!.source_id, quote: "body for https://ex/1" }).match)
      .toBe("exact");
  });

  it("carries a degraded extraction through to the document the CLI's angle will be judged on", async () => {
    const evidence = new EvidenceStore({ now: () => 0 });
    const degraded: SearchLike = {
      ...fakeSearch,
      fetch: async (url) => ({ url, markdown: "nav home body for " + url, degraded: true }),
    };
    const client = await connectedClient(degraded, evidence);
    await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/1" } });
    expect(evidence.findByUrl("https://ex/1")?.capture).toBe("degraded");
  });

  it("registers search-result urls without a snapshot, so citing an unread page stays unresolved", async () => {
    const evidence = new EvidenceStore({ now: () => 0 });
    const client = await connectedClient(fakeSearch, evidence);
    await client.callTool({ name: "web_search", arguments: { query: "fusion" } });
    const listed = evidence.findByUrl("https://ex/1");
    expect(listed?.text_length).toBe(0);
    expect(evidence.resolveCitation({ id: "c1", source: listed!.source_id, quote: "anything" }).match).toBe("unresolved");
  });

  it("writes into QUORUM_EVIDENCE_DIR so the engine that spawned the CLI can read the captures back", async () => {
    const dir = mkdtempSync(join(tmpdir(), "quorum-mcp-"));
    const client = await connectedClient(fakeSearch, evidenceStoreFor({ QUORUM_EVIDENCE_DIR: dir }));
    await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/1" } });

    const loaded = EvidenceStore.load(dir);
    const document = loaded.findByUrl("https://ex/1");
    expect(document?.snapshot_path).toBe(`sources/${document!.source_id}.md`);
    expect(readFileSync(join(dir, document!.snapshot_path!), "utf8")).toContain("body for https://ex/1");
    expect(loaded.resolveCitation({ id: "c1", source: document!.source_id, quote: "body for https://ex/1" }).match)
      .toBe("exact");
  });

  it("continues an existing index rather than starting a fresh one", async () => {
    const dir = mkdtempSync(join(tmpdir(), "quorum-mcp-"));
    new EvidenceStore({ dir, now: () => 0 }).register({ url: "https://ex/earlier", text: "earlier body" });
    const store = evidenceStoreFor({ QUORUM_EVIDENCE_DIR: dir });
    expect(store.findByUrl("https://ex/earlier")).toBeDefined();
  });

  it("is memory-only when the app passed no evidence directory", () => {
    const store = evidenceStoreFor({});
    expect(store.register({ url: "https://ex/1", text: "body" }).snapshot_path).toBeNull();
  });
});

describe("mcp-serve without a search key (the subscription path)", () => {
  it("offers web_fetch alone, leaving discovery to the CLI's built-in WebSearch", async () => {
    const client = await connectedClient(fakeSearch, undefined, { webSearch: false });
    const names = (await client.listTools()).tools.map((t) => t.name);
    expect(names).toContain("web_fetch");
    expect(names).not.toContain("web_search");
  });

  it("still captures what web_fetch reads", async () => {
    const evidence = new EvidenceStore({ now: () => 0 });
    const client = await connectedClient(fakeSearch, evidence, { webSearch: false });
    await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/1" } });
    expect(evidence.hasSnapshots()).toBe(true);
  });
});

describe("mcp-serve web_fetch paging (offset parity with the BYOK tool)", () => {
  const LONG = Array.from({ length: 30000 }, (_, i) => String.fromCharCode(97 + (i % 26))).join("");
  const longSearch = (fetches: string[]): SearchLike => ({
    ...fakeSearch,
    fetch: async (url) => {
      fetches.push(url);
      return { url, markdown: LONG, title: "Long" };
    },
  });
  const textOf = (res: any) => res.content.map((c: any) => c.text).join("");

  it("returns the first 12000 characters with the offset to continue from", async () => {
    const client = await connectedClient(longSearch([]), new EvidenceStore({ now: () => 0 }));
    const text = textOf(await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/long" } }));
    expect(text).toContain("next_offset: 12000");
    expect(text).toContain("total_chars: 30000");
    expect(text).toContain(LONG.slice(0, 12000));
    expect(text).not.toContain(LONG.slice(0, 12001));
  });

  it("continues through the same captured copy without fetching again", async () => {
    const fetches: string[] = [];
    const client = await connectedClient(longSearch(fetches), new EvidenceStore({ now: () => 0 }));
    await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/long" } });
    const second = textOf(await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/long", offset: 12000 } }));
    expect(fetches).toHaveLength(1);
    expect(second).toContain("offset: 12000");
    expect(second).toContain("next_offset: 24000");
    expect(second).toContain(LONG.slice(12000, 24000));
  });

  it("ends paging with no next_offset", async () => {
    const client = await connectedClient(longSearch([]), new EvidenceStore({ now: () => 0 }));
    await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/long" } });
    const last = textOf(await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/long", offset: 24000 } }));
    expect(last).toContain(LONG.slice(24000));
    expect(last).not.toContain("next_offset");
  });

  it("snapshots the whole page even though only a window is returned", async () => {
    const evidence = new EvidenceStore({ now: () => 0 });
    const client = await connectedClient(longSearch([]), evidence);
    await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/long" } });
    const document = evidence.findByUrl("https://ex/long")!;
    expect(evidence.snapshotText(document.source_id)).toBe(LONG);
  });
});

describe("mcp-serve fetch failures are never silent", () => {
  const failing = (error: Error): SearchLike => ({ ...fakeSearch, fetch: async () => { throw error; } });
  const textOf = (res: any) => res.content.map((c: any) => c.text).join("");

  it("tells the model what failed and why, as an error result", async () => {
    const client = await connectedClient(
      failing(new FetchFailure("paywall", "https://ex/p", "https://ex/p shows a paywall")),
      new EvidenceStore({ now: () => 0 }),
    );
    const res: any = await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/p" } });
    expect(res.isError).toBe(true);
    expect(textOf(res)).toContain("paywall");
    expect(textOf(res)).toMatch(/another source/i);
  });

  it("files the failure as evidence the engine can read back", async () => {
    const dir = mkdtempSync(join(tmpdir(), "quorum-mcp-fail-"));
    const client = await connectedClient(
      failing(new FetchFailure("blocked", "https://ex/b", "HTTP 403")),
      evidenceStoreFor({ QUORUM_EVIDENCE_DIR: dir }),
    );
    await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/b" } });
    expect(EvidenceStore.load(dir).captureFailures()).toMatchObject([{ url: "https://ex/b", stage: "fetch", kind: "blocked" }]);
  });

  it("files an unexpected error as a network failure rather than crashing the server", async () => {
    const evidence = new EvidenceStore({ now: () => 0 });
    const client = await connectedClient(failing(new Error("boom")), evidence);
    const res: any = await client.callTool({ name: "web_fetch", arguments: { url: "https://ex/x" } });
    expect(res.isError).toBe(true);
    expect(evidence.captureFailures()).toMatchObject([{ kind: "network", error: "boom" }]);
  });
});

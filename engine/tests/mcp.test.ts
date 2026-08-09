import { describe, it, expect } from "vitest";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { createMcpServer, evidenceStoreFor } from "../src/mcp.js";
import { EvidenceStore } from "../src/evidence.js";
import type { SearchLike } from "../src/agent.js";

const fakeSearch: SearchLike = {
  search: async (query) => ({ results: [{ title: "Doc", url: "https://ex/1", snippet: "about " + query }] }),
  fetch: async (url) => ({ url, markdown: "# Doc\n\nbody for " + url }),
};

async function connectedClient(search: SearchLike, evidence?: EvidenceStore) {
  const server = evidence ? createMcpServer(search, evidence) : createMcpServer(search);
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

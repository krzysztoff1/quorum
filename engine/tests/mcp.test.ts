import { describe, it, expect } from "vitest";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { createMcpServer } from "../src/mcp.js";
import type { SearchLike } from "../src/agent.js";

const fakeSearch: SearchLike = {
  search: async (query) => ({ results: [{ title: "Doc", url: "https://ex/1", snippet: "about " + query }] }),
  fetch: async (url) => ({ url, markdown: "# Doc\n\nbody for " + url }),
};

async function connectedClient(search: SearchLike) {
  const server = createMcpServer(search);
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

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { ENGINE_NAME, ENGINE_VERSION } from "./emitter.js";
import type { SearchLike } from "./agent.js";
import { EvidenceStore } from "./evidence.js";
import { makeSearchClient } from "./config.js";
import type { Env } from "./providers.js";

/// The evidence store this server appends to. With `QUORUM_EVIDENCE_DIR` set the captures are durable and
/// the engine that spawned the Claude Code angle reads them back — this process cannot hand them over any
/// other way, since it is a separate process serving the CLI's fetches.
export function evidenceStoreFor(env: Env): EvidenceStore {
  const dir = env.QUORUM_EVIDENCE_DIR;
  return dir ? EvidenceStore.load(dir) : new EvidenceStore();
}

export function createMcpServer(search: SearchLike, evidence: EvidenceStore = new EvidenceStore()): McpServer {
  const server = new McpServer({ name: ENGINE_NAME, version: ENGINE_VERSION });

  server.registerTool(
    "web_search",
    {
      description: "Search the web for authoritative sources. Returns titles, URLs, and snippets.",
      inputSchema: { query: z.string().describe("the search query") },
    },
    async ({ query }) => {
      const { results } = await search.search(query);
      for (const hit of results) if (hit.url) evidence.registerSearchResult(hit.url, hit.title);
      return { content: [{ type: "text", text: JSON.stringify(results, null, 2) }] };
    }
  );

  server.registerTool(
    "web_fetch",
    {
      description:
        "Fetch a URL and return its main readable content as markdown, plus the source_id to cite it by.",
      inputSchema: { url: z.string().describe("the URL to fetch") },
    },
    async ({ url }) => {
      const fetched = await search.fetch(url);
      const document = evidence.register({
        url: fetched.url || url,
        ...(fetched.title === undefined ? {} : { title: fetched.title }),
        ...(fetched.contentType === undefined ? {} : { contentType: fetched.contentType }),
        text: fetched.markdown,
        ...(fetched.bytes === undefined ? {} : { bytes: fetched.bytes }),
      });
      const header = `source_id: ${document.source_id}\nurl: ${document.url}\ntitle: ${document.title}\n\n`;
      return { content: [{ type: "text", text: header + fetched.markdown }] };
    }
  );

  return server;
}

export async function runMcpServe(env: Env): Promise<void> {
  const server = createMcpServer(makeSearchClient(env), evidenceStoreFor(env));
  await server.connect(new StdioServerTransport());
}

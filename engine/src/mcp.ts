import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { ENGINE_NAME, ENGINE_VERSION } from "./emitter.js";
import type { SearchLike } from "./agent.js";
import { makeSearchClient } from "./config.js";
import type { Env } from "./providers.js";

export function createMcpServer(search: SearchLike): McpServer {
  const server = new McpServer({ name: ENGINE_NAME, version: ENGINE_VERSION });

  server.registerTool(
    "web_search",
    {
      description: "Search the web for authoritative sources. Returns titles, URLs, and snippets.",
      inputSchema: { query: z.string().describe("the search query") },
    },
    async ({ query }) => {
      const { results } = await search.search(query);
      return { content: [{ type: "text", text: JSON.stringify(results, null, 2) }] };
    }
  );

  server.registerTool(
    "web_fetch",
    {
      description: "Fetch a URL and return its main readable content as markdown.",
      inputSchema: { url: z.string().describe("the URL to fetch") },
    },
    async ({ url }) => {
      const { markdown } = await search.fetch(url);
      return { content: [{ type: "text", text: markdown }] };
    }
  );

  return server;
}

export async function runMcpServe(env: Env): Promise<void> {
  const server = createMcpServer(makeSearchClient(env));
  await server.connect(new StdioServerTransport());
}

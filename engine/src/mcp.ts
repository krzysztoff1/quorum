import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { ENGINE_NAME, ENGINE_VERSION } from "./emitter.js";
import { SPAWN_TOOL_DESCRIPTION, capturedRead, readPage, FETCH_CHAR_CAP, type SearchLike } from "./agent.js";
import { EvidenceStore } from "./evidence.js";
import { hasSearchKey, makeSearchClient } from "./config.js";
import { fetchFailureKind } from "./directFetch.js";
import { fileSpawnRequest } from "./spawnLog.js";
import type { Env } from "./providers.js";

/// The evidence store this server appends to. With `QUORUM_EVIDENCE_DIR` set the captures are durable and
/// the engine that spawned the Claude Code angle reads them back — this process cannot hand them over any
/// other way, since it is a separate process serving the CLI's fetches.
export function evidenceStoreFor(env: Env): EvidenceStore {
  const dir = env.QUORUM_EVIDENCE_DIR;
  return dir ? EvidenceStore.load(dir) : new EvidenceStore();
}

/// Where a Claude Code angle files the questions it raises, and which angle is filing. Both ride in on the
/// environment the engine gave the CLI, for the same reason the evidence directory does: this is a
/// different process and has no other way to reach the run.
export interface SpawnFiling {
  dir: string;
  angleID: string;
}

export function spawnFilingFor(env: Env): SpawnFiling | undefined {
  const dir = env.QUORUM_SPAWN_DIR;
  const angleID = env.QUORUM_ANGLE_ID;
  return dir && angleID ? { dir, angleID } : undefined;
}

export interface McpServerOptions {
  webSearch?: boolean;
}

export function createMcpServer(search: SearchLike, evidence: EvidenceStore = new EvidenceStore(),
                                filing?: SpawnFiling, options: McpServerOptions = {}): McpServer {
  const server = new McpServer({ name: ENGINE_NAME, version: ENGINE_VERSION });

  if (options.webSearch !== false) {
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
  }

  server.registerTool(
    "web_fetch",
    {
      description:
        "Fetch a URL and return its main readable content as markdown, plus the source_id to cite it by. " +
        `At most ${FETCH_CHAR_CAP} characters come back per call: when the reply carries next_offset there ` +
        "is more, and calling again with that offset continues through the SAME captured copy — so a quote " +
        "from deep in a long source is as citable as one from its first page.",
      inputSchema: {
        url: z.string().describe("the URL to fetch"),
        offset: z
          .number()
          .int()
          .min(0)
          .optional()
          .describe("character offset to continue reading from — the next_offset of an earlier call on this url"),
      },
    },
    async ({ url, offset }) => {
      const start = Math.max(0, Math.trunc(offset ?? 0));
      const continued = start > 0 ? capturedRead(evidence, url) : undefined;
      if (continued) return pageResult(readPage(continued.document, url, continued.text, start));
      try {
        const fetched = await search.fetch(url);
        const document = evidence.register({
          url: fetched.url || url,
          ...(fetched.title === undefined ? {} : { title: fetched.title }),
          ...(fetched.contentType === undefined ? {} : { contentType: fetched.contentType }),
          text: fetched.markdown,
          ...(fetched.bytes === undefined ? {} : { bytes: fetched.bytes }),
          ...(fetched.degraded === undefined ? {} : { degraded: fetched.degraded }),
        });
        return pageResult(readPage(document, fetched.url || url, fetched.markdown, start));
      } catch (e) {
        return failureResult(evidence, url, e);
      }
    }
  );

  if (filing) {
    server.registerTool(
      "spawn_inquiry",
      {
        description: SPAWN_TOOL_DESCRIPTION,
        inputSchema: {
          question: z.string().describe("the specific question to investigate"),
          why: z.string().describe("why you cannot answer it from where you are"),
          provoked_by: z.string().describe("the source_id or the finding that raised it — required"),
        },
      },
      async ({ question, why, provoked_by }) => {
        if (!provoked_by?.trim()) {
          return {
            content: [{ type: "text", text: JSON.stringify(
              { verdict: "rejected", reason: "a spawn must name the source or finding that provoked it" }) }],
          };
        }
        fileSpawnRequest(filing.dir, { angle_id: filing.angleID, question, why, provoked_by });
        return {
          content: [{ type: "text", text: JSON.stringify({
            verdict: "filed",
            note: "The run will rule on this question when this angle finishes. Carry on without its answer.",
          }) }],
        };
      }
    );
  }

  return server;
}

function pageResult(page: ReturnType<typeof readPage>) {
  const header = [
    `source_id: ${page.source_id}`,
    `url: ${page.url}`,
    `title: ${page.title}`,
    `offset: ${page.offset}`,
    `total_chars: ${page.total_chars}`,
    ...("next_offset" in page ? [`next_offset: ${page.next_offset}`] : []),
  ].join("\n");
  return { content: [{ type: "text" as const, text: `${header}\n\n${page.markdown}` }] };
}

function failureResult(evidence: EvidenceStore, url: string, e: unknown) {
  const message = e instanceof Error ? e.message : String(e);
  const kind = fetchFailureKind(e);
  evidence.recordFetchFailure(url, kind, message);
  const text = `Could not read ${url} (${kind}): ${message}. It was not captured and cannot be cited. Try another source.`;
  return { isError: true, content: [{ type: "text" as const, text }] };
}

export async function runMcpServe(env: Env): Promise<void> {
  const server = createMcpServer(makeSearchClient(env), evidenceStoreFor(env), spawnFilingFor(env),
                                 { webSearch: hasSearchKey(env) });
  await server.connect(new StdioServerTransport());
}

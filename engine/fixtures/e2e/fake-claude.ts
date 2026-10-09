#!/usr/bin/env bun
import { readFileSync } from "node:fs";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const argv = process.argv.slice(2);
const flag = (name: string): string | undefined => {
  const at = argv.indexOf(name);
  return at === -1 ? undefined : argv[at + 1];
};

const prompt = flag("-p") ?? "";
const system = flag("--append-system-prompt") ?? "";
const tools = (flag("--tools") ?? "").split(",").filter(Boolean);
const base = process.env.QUORUM_E2E_BASE_URL ?? "";
const scenario = process.env.QUORUM_FAKE_SCENARIO ?? "happy";
const session = "fake-claude-session";

const emit = (line: unknown) => process.stdout.write(JSON.stringify(line) + "\n");

const PAGES: Record<string, { path: string; quoteContains: string }[]> = {
  obligations: [
    { path: "/ai-act-obligations.html", quoteContains: "technical documentation of the model" },
    { path: "/members-only.html", quoteContains: "" },
  ],
  timeline: [{ path: "/gpai-timeline.html", quoteContains: "apply from 2 August 2025" }],
};

function begin(): void {
  emit({ type: "system", subtype: "init", session_id: session, model: "claude-haiku-4-5" });
}

function finish(text: string, cost: number, usage = { input_tokens: 900, output_tokens: 300 }): void {
  emit({ type: "assistant", message: { content: [{ type: "text", text }], usage, model: "claude-haiku-4-5" } });
  emit({
    type: "result", subtype: "success", is_error: false, session_id: session, total_cost_usd: cost, result: text,
    usage: { ...usage, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
  });
}

function fenced(json: unknown): string {
  return "```json\n" + JSON.stringify(json) + "\n```";
}

function replayLoggedOut(): void {
  const recorded = readFileSync(new URL("../cli/not-logged-in.ndjson", import.meta.url), "utf8");
  process.stdout.write(recorded);
}

function planner(): void {
  begin();
  finish(
    "Two angles.\n\n" +
      fenced([
        { title: "Provider obligations", prompt: "What must providers of general-purpose AI models do under the AI Act? [angle:obligations]" },
        { title: "Application dates", prompt: "From when do the AI Act's general-purpose AI obligations apply? [angle:timeline]" },
      ]),
    0.002,
  );
}

function sentenceContaining(text: string, phrase: string): string {
  const sentences = text.split(/(?<=[.!?])\s+/);
  const found = sentences.find((s) => s.includes(phrase));
  if (!found) throw new Error(`no sentence contains "${phrase}" in the fetched page`);
  return found.replace(/\s+/g, " ").trim();
}

async function researcher(): Promise<void> {
  begin();
  const angle = /\[angle:(\w+)\]/.exec(prompt)?.[1] ?? "";
  const mcpConfig = JSON.parse(flag("--mcp-config") ?? "{}");
  const server = mcpConfig.mcpServers?.quorum;
  const client = new Client({ name: "fake-claude", version: "0" });
  await client.connect(new StdioClientTransport({
    command: server.command, args: server.args, env: process.env as Record<string, string>,
  }));

  const citations: { id: string; source: string; quote: string; url: string }[] = [];
  for (const page of PAGES[angle] ?? []) {
    const url = base + page.path;
    emit({ type: "assistant", message: { content: [{ type: "tool_use", name: "mcp__quorum__web_fetch", input: { url } }] } });
    const reply: any = await client.callTool({ name: "web_fetch", arguments: { url } });
    const text: string = reply.content?.[0]?.text ?? "";
    if (reply.isError || !page.quoteContains) continue;
    const sourceId = /^source_id: (\S+)/m.exec(text)?.[1] ?? "";
    const body = text.slice(text.indexOf("\n\n") + 2);
    citations.push({ id: `c${citations.length + 1}`, source: sourceId, quote: sentenceContaining(body, page.quoteContains), url });
  }
  await client.close();

  const markers = citations.map((c) => `[^${c.id}]`).join("");
  const claim = angle === "obligations"
    ? "Providers must keep technical documentation of the model up to date."
    : "The general-purpose AI obligations apply from 2 August 2025.";
  finish(
    `${claim}${markers}\n\n## Sources\n${citations.map((c) => `- [page](${c.url})`).join("\n")}\n\n` +
      fenced({
        headline: claim, status: "complete", sourcesConsulted: citations.length,
        findings: [{ claim, sources: citations.map((c) => c.url), confidence: "high", citations: citations.map((c) => c.id) }],
        citations: citations.map(({ id, source, quote }) => ({ id, source, quote })),
      }),
    0.012,
  );
}

function synthesis(): void {
  begin();
  const offered = [...prompt.matchAll(/^- \[\^(\w+)\] source (\S+): "(.+)"$/gm)].map((m) => ({ id: m[1]!, source: m[2]!, quote: m[3]! }));
  const claims = offered.map((c) => (c.quote.includes("2 August 2025")
    ? "The general-purpose AI obligations apply from 2 August 2025."
    : "Providers must keep technical documentation of the model up to date."));
  const body = claims.map((claim, i) => `${claim}[^${offered[i]!.id}]`).join(" ");
  finish(
    `${body}\n\n` +
      fenced({
        headline: "General-purpose AI obligations and dates", status: "complete", sourcesConsulted: offered.length,
        findings: claims.map((claim, i) => ({ claim, sources: [], confidence: "high", citations: [offered[i]!.id] })),
        conflicts: [], gaps: [],
        citations: offered,
      }),
    0.02,
  );
}

function claimVerifier(): void {
  begin();
  const count = [...prompt.matchAll(/^CLAIM (\d+):/gm)].length;
  finish(fenced({ verdicts: Array.from({ length: count }, (_, i) => ({ claim: i + 1, verdict: "supported" })) }), 0.004);
}

function critic(): void {
  begin();
  finish(fenced({ objections: [] }), 0.003);
}

async function main(): Promise<void> {
  if (scenario === "logged-out") return replayLoggedOut();
  if (tools.some((t) => t.includes("web_fetch"))) return researcher();
  if (system.startsWith("Decompose")) return planner();
  if (system.startsWith("You are a synthesis engine")) return synthesis();
  if (system.startsWith("You are a claim verifier")) return claimVerifier();
  if (system.startsWith("You are one critic")) return critic();
  throw new Error(`fake claude does not know this role: ${system.slice(0, 60)}`);
}

await main();

import { MissingKeyError } from "./errors.js";
import type { SourceContentType } from "./evidence.js";

export interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}
export interface SearchResponse {
  query: string;
  results: SearchResult[];
}

/// What a fetch hands the evidence store: the extracted text to snapshot, what to call it, what it is, and
/// — for a PDF — the original bytes, so the reader can highlight in the real page layout instead of in a
/// markdown approximation of it.
export interface FetchResponse {
  url: string;
  markdown: string;
  title: string;
  contentType: SourceContentType;
  bytes?: Uint8Array;
  /// True when the text is `stripHtml` tag soup rather than a reader extraction — a snapshot quotes will
  /// rarely locate in, so what it becomes is a degraded capture, not a clean one.
  degraded?: boolean;
}

interface HttpResponse {
  ok: boolean;
  status: number;
  json: () => Promise<any>;
  text: () => Promise<string>;
  headers?: { get: (name: string) => string | null };
  arrayBuffer?: () => Promise<ArrayBuffer>;
}

export interface SearchClientConfig {
  provider: "tavily" | "brave";
  tavilyKey?: string;
  braveKey?: string;
  fetchImpl?: typeof fetch;
  concurrency?: number;
  maxRetries?: number;
  backoffMs?: number;
  maxResults?: number;
  sleep?: (ms: number) => Promise<void>;
}

class Semaphore {
  private active = 0;
  private waiters: Array<() => void> = [];
  constructor(private readonly max: number) {}
  async run<T>(fn: () => Promise<T>): Promise<T> {
    while (this.active >= this.max) await new Promise<void>((r) => this.waiters.push(r));
    this.active += 1;
    try {
      return await fn();
    } finally {
      this.active -= 1;
      this.waiters.shift()?.();
    }
  }
}

export class SearchClient {
  private readonly fetchImpl: typeof fetch;
  private readonly gate: Semaphore;
  private readonly maxRetries: number;
  private readonly backoffMs: number;
  private readonly maxResults: number;
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(private readonly config: SearchClientConfig) {
    this.fetchImpl = config.fetchImpl ?? fetch;
    this.gate = new Semaphore(config.concurrency ?? 4);
    this.maxRetries = config.maxRetries ?? 3;
    this.backoffMs = config.backoffMs ?? 500;
    this.maxResults = config.maxResults ?? 8;
    this.sleep = config.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
  }

  private async fetchWithRetry(url: string, init?: RequestInit): Promise<HttpResponse> {
    let res!: HttpResponse;
    for (let attempt = 0; attempt < this.maxRetries; attempt++) {
      res = (await this.fetchImpl(url, init)) as unknown as HttpResponse;
      if (res.ok || (res.status !== 429 && res.status < 500)) return res;
      if (attempt < this.maxRetries - 1) await this.sleep(this.backoffMs * 2 ** attempt);
    }
    return res;
  }

  search(query: string): Promise<SearchResponse> {
    return this.gate.run(() => (this.config.provider === "brave" ? this.searchBrave(query) : this.searchTavily(query)));
  }

  private async searchTavily(query: string): Promise<SearchResponse> {
    if (!this.config.tavilyKey) throw new MissingKeyError("tavily", "QUORUM_TAVILY_KEY");
    const res = await this.fetchWithRetry("https://api.tavily.com/search", {
      method: "POST",
      headers: { Authorization: `Bearer ${this.config.tavilyKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ query, max_results: this.maxResults, search_depth: "basic" }),
    });
    if (!res.ok) throw new Error(`Tavily search failed (HTTP ${res.status})`);
    const body = await res.json();
    const results: SearchResult[] = (body.results ?? []).map((r: any) => ({
      title: r.title ?? "",
      url: r.url ?? "",
      snippet: r.content ?? r.snippet ?? "",
    }));
    return { query, results };
  }

  private async searchBrave(query: string): Promise<SearchResponse> {
    if (!this.config.braveKey) throw new MissingKeyError("brave", "QUORUM_BRAVE_KEY");
    const url = `https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(query)}&count=${this.maxResults}`;
    const res = await this.fetchWithRetry(url, {
      headers: { "X-Subscription-Token": this.config.braveKey, Accept: "application/json" },
    });
    if (!res.ok) throw new Error(`Brave search failed (HTTP ${res.status})`);
    const body = await res.json();
    const results: SearchResult[] = (body.web?.results ?? []).map((r: any) => ({
      title: r.title ?? "",
      url: r.url ?? "",
      snippet: r.description ?? "",
    }));
    return { query, results };
  }

  fetch(url: string): Promise<FetchResponse> {
    return this.gate.run(() => this.fetchOne(url));
  }

  private async fetchOne(url: string): Promise<FetchResponse> {
    const jina = await this.fetchWithRetry(`https://r.jina.ai/${url}`, {
      headers: { "X-Return-Format": "markdown" },
    });
    if (jina.ok) {
      const reader = readerPayload(await jina.text());
      const pdf = looksLikePdfUrl(url);
      return {
        url,
        markdown: reader.markdown,
        title: reader.title,
        contentType: pdf ? "pdf" : "html",
        ...(pdf ? await this.originalBytes(url) : {}),
      };
    }
    const plain = await this.fetchWithRetry(url);
    if (!plain.ok) throw new Error(`Fetch failed for ${url} (HTTP ${plain.status})`);
    const contentTypeHeader = plain.headers?.get("content-type") ?? "";
    if (isPdf(url, contentTypeHeader)) {
      const bytes = await readBytes(plain);
      return { url, markdown: "", title: "", contentType: "pdf", ...(bytes ? { bytes } : {}) };
    }
    const html = await plain.text();
    return { url, markdown: stripHtml(html), title: htmlTitle(html), contentType: "html", degraded: true };
  }

  private async originalBytes(url: string): Promise<{ bytes?: Uint8Array }> {
    try {
      const plain = await this.fetchWithRetry(url);
      if (!plain.ok) return {};
      const bytes = await readBytes(plain);
      return bytes ? { bytes } : {};
    } catch {
      return {};
    }
  }
}

async function readBytes(response: HttpResponse): Promise<Uint8Array | undefined> {
  if (!response.arrayBuffer) return undefined;
  try {
    const buffer = await response.arrayBuffer();
    return buffer.byteLength > 0 ? new Uint8Array(buffer) : undefined;
  } catch {
    return undefined;
  }
}

function isPdf(url: string, contentType: string): boolean {
  return contentType.toLowerCase().includes("application/pdf") || looksLikePdfUrl(url);
}

function looksLikePdfUrl(url: string): boolean {
  const path = url.split("?")[0]!.split("#")[0]!;
  return path.toLowerCase().endsWith(".pdf");
}

/// Jina Reader prefixes its markdown with `Title:` / `URL Source:` / `Markdown Content:` lines. The title
/// is worth keeping; the preamble is not — the snapshot is what citation offsets index into, so it should
/// hold the document, not the reader's header.
function readerPayload(body: string): { title: string; markdown: string } {
  const text = body.trim();
  const title = /^Title:[ \t]*(.+)$/m.exec(text)?.[1]?.trim() ?? "";
  const marker = text.indexOf("Markdown Content:");
  const markdown = marker === -1 ? text : text.slice(marker + "Markdown Content:".length).trim();
  return { title, markdown: markdown || text };
}

function htmlTitle(html: string): string {
  const raw = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html)?.[1] ?? "";
  return decodeEntities(raw).replace(/\s+/g, " ").trim();
}

function decodeEntities(text: string): string {
  return text
    .replace(/&nbsp;/g, " ")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

// ponytail: naive tag-strip readability — swap for a real extractor (readability/turndown) if fetch
// quality on JS-heavy pages proves poor.
function stripHtml(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, "")
    .replace(/<style[\s\S]*?<\/style>/gi, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ")
    .trim();
}

import { MissingKeyError } from "./errors.js";
import type { SourceContentType } from "./evidence.js";
import { DirectFetcher } from "./directFetch.js";

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
  degraded?: boolean;
}

interface HttpResponse {
  ok: boolean;
  status: number;
  json: () => Promise<any>;
  text: () => Promise<string>;
}

export interface PageFetcher {
  fetch(url: string): Promise<FetchResponse>;
}

export interface SearchClientConfig {
  provider: "tavily" | "brave";
  tavilyKey?: string;
  braveKey?: string;
  fetchImpl?: typeof fetch;
  fetcher?: PageFetcher;
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
  private readonly fetcher: PageFetcher;
  private readonly gate: Semaphore;
  private readonly maxRetries: number;
  private readonly backoffMs: number;
  private readonly maxResults: number;
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(private readonly config: SearchClientConfig) {
    this.fetchImpl = config.fetchImpl ?? fetch;
    this.fetcher = config.fetcher ?? new DirectFetcher();
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
    return this.gate.run(() => this.fetcher.fetch(url));
  }
}

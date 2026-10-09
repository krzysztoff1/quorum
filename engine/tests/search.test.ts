import { describe, it, expect, vi } from "vitest";
import { SearchClient } from "../src/search.js";
import { MissingKeyError } from "../src/errors.js";
import { FetchFailure } from "../src/directFetch.js";

function jsonResponse(body: unknown, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}
function textResponse(text: string, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => ({}), text: async () => text };
}
function binaryResponse(bytes: number[], contentType: string, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => ({}),
    text: async () => String.fromCharCode(...bytes),
    headers: { get: (name: string) => (name.toLowerCase() === "content-type" ? contentType : null) },
    arrayBuffer: async () => new Uint8Array(bytes).buffer,
  };
}

describe("SearchClient.search", () => {
  it("queries Tavily and normalizes results, sending the key in a header not the query string", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({ results: [{ title: "T1", url: "https://a", content: "snip-a" }] })
    ) as unknown as typeof fetch;
    const client = new SearchClient({ provider: "tavily", tavilyKey: "tk", fetchImpl, sleep: async () => {} });
    const res = await client.search("fusion");
    expect(res.results).toEqual([{ title: "T1", url: "https://a", snippet: "snip-a" }]);
    const [url, init] = (fetchImpl as any).mock.calls[0];
    expect(String(url)).toContain("tavily.com");
    expect(JSON.stringify(init.headers)).toContain("tk");
    expect(String(url)).not.toContain("tk");
  });

  it("queries Brave when configured and normalizes results", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({ web: { results: [{ title: "B1", url: "https://b", description: "snip-b" }] } })
    ) as unknown as typeof fetch;
    const client = new SearchClient({ provider: "brave", braveKey: "bk", fetchImpl, sleep: async () => {} });
    const res = await client.search("fusion");
    expect(res.results).toEqual([{ title: "B1", url: "https://b", snippet: "snip-b" }]);
  });

  it("throws MissingKeyError naming the provider when its key is absent", async () => {
    const client = new SearchClient({ provider: "tavily", fetchImpl: (async () => jsonResponse({})) as any });
    await expect(client.search("x")).rejects.toBeInstanceOf(MissingKeyError);
  });

  it("retries with backoff on 429 then succeeds", async () => {
    let n = 0;
    const fetchImpl = vi.fn(async () => {
      n++;
      if (n < 3) return jsonResponse({}, 429);
      return jsonResponse({ results: [{ title: "ok", url: "https://ok", content: "c" }] });
    }) as unknown as typeof fetch;
    const client = new SearchClient({ provider: "tavily", tavilyKey: "tk", fetchImpl, maxRetries: 3, sleep: async () => {} });
    const res = await client.search("x");
    expect(n).toBe(3);
    expect(res.results[0]!.url).toBe("https://ok");
  });

  it("caps concurrency so parallel calls don't trip RPM limits", async () => {
    let inFlight = 0;
    let peak = 0;
    let release: () => void = () => {};
    const gate = new Promise<void>((r) => (release = r));
    const fetchImpl = (async () => {
      inFlight++;
      peak = Math.max(peak, inFlight);
      await gate;
      inFlight--;
      return jsonResponse({ results: [] });
    }) as unknown as typeof fetch;
    const client = new SearchClient({ provider: "tavily", tavilyKey: "tk", fetchImpl, concurrency: 2, sleep: async () => {} });
    const all = Promise.all([client.search("a"), client.search("b"), client.search("c"), client.search("d")]);
    await new Promise((r) => setTimeout(r, 10));
    expect(peak).toBeLessThanOrEqual(2);
    release();
    await all;
  });
});

describe("SearchClient.fetch", () => {
  const page = { url: "https://example.com/doc", markdown: "# Heading\n\nbody text", title: "Doc", contentType: "html" as const };

  it("reads a page through the engine's own direct fetch", async () => {
    const fetcher = { fetch: vi.fn(async () => page) };
    const client = new SearchClient({ provider: "tavily", tavilyKey: "tk", fetcher, sleep: async () => {} });
    expect(await client.fetch("https://example.com/doc")).toEqual(page);
    expect(fetcher.fetch).toHaveBeenCalledWith("https://example.com/doc");
  });

  it("works with no search key at all", async () => {
    const fetcher = { fetch: vi.fn(async () => page) };
    const client = new SearchClient({ provider: "tavily", fetcher });
    expect((await client.fetch("https://example.com/doc")).markdown).toContain("Heading");
  });

  it("never hands a url to a third-party reader", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({})) as unknown as typeof fetch;
    const fetcher = { fetch: vi.fn(async () => page) };
    const client = new SearchClient({ provider: "tavily", tavilyKey: "tk", fetchImpl, fetcher });
    await client.fetch("https://example.com/doc");
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("surfaces a capture failure instead of swallowing it", async () => {
    const fetcher = { fetch: vi.fn(async () => { throw new FetchFailure("blocked", "https://example.com/doc", "HTTP 403"); }) };
    const client = new SearchClient({ provider: "tavily", fetcher });
    await expect(client.fetch("https://example.com/doc")).rejects.toMatchObject({ kind: "blocked" });
  });

  it("shares the concurrency cap with search", async () => {
    let inFlight = 0;
    let peak = 0;
    let release: () => void = () => {};
    const gate = new Promise<void>((r) => (release = r));
    const fetcher = {
      fetch: async () => {
        inFlight++;
        peak = Math.max(peak, inFlight);
        await gate;
        inFlight--;
        return page;
      },
    };
    const client = new SearchClient({ provider: "tavily", fetcher, concurrency: 2 });
    const all = Promise.all(["a", "b", "c", "d"].map((x) => client.fetch(`https://example.com/${x}`)));
    await new Promise((r) => setTimeout(r, 10));
    expect(peak).toBe(2);
    release();
    await all;
  });
});

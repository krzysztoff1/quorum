import { describe, it, expect, vi } from "vitest";
import { SearchClient } from "../src/search.js";
import { MissingKeyError } from "../src/errors.js";

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
  it("reads a URL as markdown via Jina Reader", async () => {
    const fetchImpl = vi.fn(async (u: any) => {
      if (String(u).includes("r.jina.ai")) return textResponse("# Heading\n\nbody text");
      return textResponse("<html>nope</html>");
    }) as unknown as typeof fetch;
    const client = new SearchClient({ provider: "tavily", tavilyKey: "tk", fetchImpl, sleep: async () => {} });
    const res = await client.fetch("https://example.com/doc");
    expect(res.url).toBe("https://example.com/doc");
    expect(res.markdown).toContain("Heading");
  });

  it("falls back to plain fetch + tag stripping when Jina fails", async () => {
    const fetchImpl = vi.fn(async (u: any) => {
      if (String(u).includes("r.jina.ai")) return textResponse("err", 500);
      return textResponse("<html><body><p>Hello <b>world</b></p><script>x=1</script></body></html>");
    }) as unknown as typeof fetch;
    const client = new SearchClient({ provider: "tavily", tavilyKey: "tk", fetchImpl, maxRetries: 1, sleep: async () => {} });
    const res = await client.fetch("https://example.com/doc");
    expect(res.markdown).toContain("Hello");
    expect(res.markdown).toContain("world");
    expect(res.markdown).not.toContain("<b>");
    expect(res.markdown).not.toContain("x=1");
  });
});

describe("SearchClient.fetch — what evidence capture needs", () => {
  it("reads Jina's Title header as the document title and calls the source html", async () => {
    const fetchImpl = vi.fn(async () =>
      textResponse("Title: Cold starts in 2026\n\nURL Source: https://example.com/doc\n\nMarkdown Content:\n# Cold starts\n\nbody")
    ) as unknown as typeof fetch;
    const client = new SearchClient({ provider: "tavily", tavilyKey: "tk", fetchImpl, sleep: async () => {} });
    const res = await client.fetch("https://example.com/doc");
    expect(res.title).toBe("Cold starts in 2026");
    expect(res.contentType).toBe("html");
    expect(res.bytes).toBeUndefined();
    expect(res.markdown).toContain("# Cold starts");
    expect((fetchImpl as any).mock.calls).toHaveLength(1);
  });

  it("extracts <title> when it falls back to the raw page", async () => {
    const fetchImpl = vi.fn(async (u: any) => {
      if (String(u).includes("r.jina.ai")) return textResponse("err", 500);
      return textResponse("<html><head><title>Fusion &amp; the grid</title></head><body><p>Hello</p></body></html>");
    }) as unknown as typeof fetch;
    const client = new SearchClient({ provider: "tavily", tavilyKey: "tk", fetchImpl, maxRetries: 1, sleep: async () => {} });
    const res = await client.fetch("https://example.com/doc");
    expect(res.title).toBe("Fusion & the grid");
    expect(res.contentType).toBe("html");
  });

  it("keeps the raw bytes of a .pdf url so the app can open the real PDF", async () => {
    const pdf = [37, 80, 68, 70, 45, 49];
    const fetchImpl = vi.fn(async (u: any) => {
      if (String(u).includes("r.jina.ai")) return textResponse("Title: The paper\n\nMarkdown Content:\nextracted page text");
      return binaryResponse(pdf, "application/pdf");
    }) as unknown as typeof fetch;
    const client = new SearchClient({ provider: "tavily", tavilyKey: "tk", fetchImpl, sleep: async () => {} });
    const res = await client.fetch("https://example.com/paper.pdf");
    expect(res.contentType).toBe("pdf");
    expect(res.markdown).toContain("extracted page text");
    expect(res.title).toBe("The paper");
    expect(Array.from(res.bytes!)).toEqual(pdf);
  });

  it("detects a pdf served from an extensionless url by its content-type", async () => {
    const pdf = [37, 80, 68, 70];
    const fetchImpl = vi.fn(async (u: any) => {
      if (String(u).includes("r.jina.ai")) return textResponse("err", 500);
      return binaryResponse(pdf, "application/pdf; charset=binary");
    }) as unknown as typeof fetch;
    const client = new SearchClient({ provider: "tavily", tavilyKey: "tk", fetchImpl, maxRetries: 1, sleep: async () => {} });
    const res = await client.fetch("https://example.com/download?id=7");
    expect(res.contentType).toBe("pdf");
    expect(Array.from(res.bytes!)).toEqual(pdf);
  });

  it("still returns the extracted text when the raw pdf bytes cannot be had", async () => {
    const fetchImpl = vi.fn(async (u: any) => {
      if (String(u).includes("r.jina.ai")) return textResponse("Markdown Content:\npage text");
      return textResponse("nope", 403);
    }) as unknown as typeof fetch;
    const client = new SearchClient({ provider: "tavily", tavilyKey: "tk", fetchImpl, maxRetries: 1, sleep: async () => {} });
    const res = await client.fetch("https://example.com/paper.pdf");
    expect(res.contentType).toBe("pdf");
    expect(res.markdown).toContain("page text");
    expect(res.bytes).toBeUndefined();
  });
});

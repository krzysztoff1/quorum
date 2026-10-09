import { describe, it, expect, vi } from "vitest";
import { DirectFetcher, FetchFailure, parseRobots, robotsAllows } from "../src/directFetch.js";

type Route = Response | ((url: string, init?: RequestInit) => Response | Promise<Response>);

function html(body: string, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(body, { status, headers: { "content-type": "text/html; charset=utf-8", ...headers } });
}

function fetcherFor(routes: Record<string, Route>, options: ConstructorParameters<typeof DirectFetcher>[0] = {}) {
  const calls: Array<{ url: string; init?: RequestInit }> = [];
  const fetchImpl = (async (input: string | URL, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, init });
    const route = routes[url];
    if (route === undefined) return new Response("", { status: 404 });
    return typeof route === "function" ? route(url, init) : route.clone();
  }) as unknown as typeof fetch;
  const fetcher = new DirectFetcher({ fetchImpl, sleep: async () => {}, hostGapMs: 0, ...options });
  return { fetcher, calls };
}

const ARTICLE = `<!doctype html><html><head><title>Cold starts &amp; you</title>
<meta property="og:title" content="Cold starts and you"></head><body>
<nav><a href="/">Home</a><a href="/pricing">Pricing</a></nav>
<article><h1>Cold starts</h1><p>Latency fell 40% year over year in tested clusters.</p>
<p>The &quot;control plane&quot; absorbed the rest &mdash; a result the authors call decisive.</p>
<ul><li>first point</li><li>second point</li></ul>
${"<p>Filler sentence so the page is long enough to count as content. </p>".repeat(8)}</article>
<footer>© 2026 Acme. All rights reserved.</footer><script>window.track()</script></body></html>`;

describe("DirectFetcher reading a page", () => {
  it("extracts the article as readable text without navigation, footer or script", async () => {
    const { fetcher } = fetcherFor({ "https://ex.test/a": html(ARTICLE) });
    const page = await fetcher.fetch("https://ex.test/a");
    expect(page.contentType).toBe("html");
    expect(page.markdown).toContain("Latency fell 40% year over year in tested clusters.");
    expect(page.markdown).toContain('The "control plane" absorbed the rest — a result');
    expect(page.markdown).toContain("- first point");
    expect(page.markdown).not.toContain("Pricing");
    expect(page.markdown).not.toContain("All rights reserved");
    expect(page.markdown).not.toContain("window.track");
    expect(page.degraded).toBeUndefined();
  });

  it("keeps paragraphs apart", async () => {
    const { fetcher } = fetcherFor({ "https://ex.test/a": html(ARTICLE) });
    const page = await fetcher.fetch("https://ex.test/a");
    expect(page.markdown).toMatch(/year over year in tested clusters\.\n\nThe "control plane"/);
  });

  it("prefers the page's own headline for the title", async () => {
    const { fetcher } = fetcherFor({ "https://ex.test/a": html(ARTICLE) });
    expect((await fetcher.fetch("https://ex.test/a")).title).toBe("Cold starts and you");
  });

  it("falls back to the <title> and flags whole-page extraction as degraded", async () => {
    const page = `<html><head><title>Plain  page</title></head><body><div>${"Some body text about things. ".repeat(20)}</div></body></html>`;
    const { fetcher } = fetcherFor({ "https://ex.test/p": html(page) });
    const fetched = await fetcher.fetch("https://ex.test/p");
    expect(fetched.title).toBe("Plain page");
    expect(fetched.degraded).toBe(true);
  });

  it("reads plain text and json as text", async () => {
    const { fetcher } = fetcherFor({
      "https://ex.test/a.txt": new Response("just words", { headers: { "content-type": "text/plain" } }),
    });
    const fetched = await fetcher.fetch("https://ex.test/a.txt");
    expect(fetched).toMatchObject({ contentType: "text", markdown: "just words" });
  });

  it("identifies itself with a user agent and asks for html", async () => {
    const { fetcher, calls } = fetcherFor({ "https://ex.test/a": html(ARTICLE) });
    await fetcher.fetch("https://ex.test/a");
    const headers = new Headers(calls.find((c) => c.url === "https://ex.test/a")!.init!.headers);
    expect(headers.get("user-agent")).toMatch(/^Quorum\/\S+ \(.*research.*\)/i);
    expect(headers.get("accept")).toContain("text/html");
  });
});

describe("DirectFetcher redirects", () => {
  it("follows redirects, resolving relative locations", async () => {
    const { fetcher } = fetcherFor({
      "https://ex.test/old": new Response(null, { status: 301, headers: { location: "/new" } }),
      "https://ex.test/new": html(ARTICLE),
    });
    const page = await fetcher.fetch("https://ex.test/old");
    expect(page.markdown).toContain("Latency fell 40%");
    expect(page.url).toBe("https://ex.test/old");
  });

  it("gives up on a redirect loop with an explicit failure", async () => {
    const { fetcher } = fetcherFor({
      "https://ex.test/a": new Response(null, { status: 302, headers: { location: "https://ex.test/b" } }),
      "https://ex.test/b": new Response(null, { status: 302, headers: { location: "https://ex.test/a" } }),
    });
    await expect(fetcher.fetch("https://ex.test/a")).rejects.toMatchObject({ kind: "redirects" });
  });

  it("refuses redirects to non-http schemes", async () => {
    const { fetcher } = fetcherFor({
      "https://ex.test/a": new Response(null, { status: 302, headers: { location: "file:///etc/passwd" } }),
    });
    await expect(fetcher.fetch("https://ex.test/a")).rejects.toMatchObject({ kind: "unsupported" });
  });
});

describe("DirectFetcher failures are explicit and typed", () => {
  const kindOf = async (response: Response, options = {}) => {
    const { fetcher } = fetcherFor({ "https://ex.test/a": response }, options);
    const error = await fetcher.fetch("https://ex.test/a").then(() => undefined, (e) => e);
    expect(error).toBeInstanceOf(FetchFailure);
    return (error as FetchFailure).kind;
  };

  it("calls 403 and 401 blocked", async () => {
    expect(await kindOf(html("denied", 403))).toBe("blocked");
    expect(await kindOf(html("login", 401))).toBe("blocked");
  });

  it("calls 402 a paywall", async () => {
    expect(await kindOf(html("pay", 402))).toBe("paywall");
  });

  it("calls 404 and 410 not found", async () => {
    expect(await kindOf(html("", 404))).toBe("not_found");
    expect(await kindOf(html("", 410))).toBe("not_found");
  });

  it("retries a 503 then reports http_error with the status", async () => {
    let calls = 0;
    const { fetcher } = fetcherFor({ "https://ex.test/a": () => { calls += 1; return html("down", 503); } }, { maxRetries: 2 });
    const error = (await fetcher.fetch("https://ex.test/a").catch((e) => e)) as FetchFailure;
    expect(error.kind).toBe("http_error");
    expect(error.message).toContain("503");
    expect(calls).toBe(2);
  });

  it("recovers when a retry succeeds", async () => {
    let calls = 0;
    const { fetcher } = fetcherFor({
      "https://ex.test/a": () => (++calls === 1 ? html("busy", 429) : html(ARTICLE)),
    });
    expect((await fetcher.fetch("https://ex.test/a")).markdown).toContain("Latency fell");
  });

  it("calls an aborted request a timeout", async () => {
    const { fetcher } = fetcherFor({
      "https://ex.test/a": () => { throw Object.assign(new Error("aborted"), { name: "TimeoutError" }); },
    });
    await expect(fetcher.fetch("https://ex.test/a")).rejects.toMatchObject({ kind: "timeout" });
  });

  it("calls a connection error a network failure", async () => {
    const { fetcher } = fetcherFor({ "https://ex.test/a": () => { throw new TypeError("fetch failed"); } });
    await expect(fetcher.fetch("https://ex.test/a")).rejects.toMatchObject({ kind: "network" });
  });

  it("rejects a body over the size cap, declared or streamed", async () => {
    expect(await kindOf(html("x", 200, { "content-length": "999999999" }), { maxBytes: 1000 })).toBe("too_large");
    expect(await kindOf(html("y".repeat(5000)), { maxBytes: 1000 })).toBe("too_large");
  });

  it("rejects binary content it cannot read", async () => {
    expect(await kindOf(new Response("PNG", { headers: { "content-type": "image/png" } }))).toBe("unsupported");
    expect(await kindOf(new Response("zip", { headers: { "content-type": "application/zip" } }))).toBe("unsupported");
  });

  it("recognises a JavaScript-only shell instead of snapshotting its emptiness", async () => {
    const shell = `<html><head><title>App</title><script src="/bundle.js"></script></head><body><div id="root"></div><noscript>You need to enable JavaScript to run this app.</noscript></body></html>`;
    expect(await kindOf(html(shell))).toBe("js_only");
  });

  it("recognises a paywall teaser", async () => {
    const teaser = `<html><body><article><p>The first paragraph of the story, then:</p><p>Subscribe to continue reading this article.</p></article></body></html>`;
    expect(await kindOf(html(teaser))).toBe("paywall");
  });

  it("calls a nearly empty page empty", async () => {
    expect(await kindOf(html("<html><body><p>Hi</p></body></html>"))).toBe("empty");
  });

  it("refuses non-http urls", async () => {
    const { fetcher } = fetcherFor({});
    await expect(fetcher.fetch("ftp://ex.test/a")).rejects.toMatchObject({ kind: "unsupported" });
    await expect(fetcher.fetch("not a url")).rejects.toMatchObject({ kind: "unsupported" });
  });
});

describe("DirectFetcher with PDFs", () => {
  const MINIMAL_PDF = Buffer.from(
    "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R 5 0 R]/Count 2>>endobj\n" +
    "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 200]/Contents 4 0 R/Resources<</Font<</F1 7 0 R>>>>>>endobj\n" +
    "4 0 obj<</Length 44>>stream\nBT /F1 18 Tf 20 100 Td (Page one text) Tj ET\nendstream endobj\n" +
    "5 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 200]/Contents 6 0 R/Resources<</Font<</F1 7 0 R>>>>>>endobj\n" +
    "6 0 obj<</Length 44>>stream\nBT /F1 18 Tf 20 100 Td (Page two text) Tj ET\nendstream endobj\n" +
    "7 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\ntrailer<</Root 1 0 R/Size 8>>\n%%EOF",
  );

  it("extracts pdf text page by page, separated by form feeds, and keeps the original bytes", async () => {
    const { fetcher } = fetcherFor({
      "https://ex.test/p.pdf": new Response(MINIMAL_PDF, { headers: { "content-type": "application/pdf" } }),
    });
    const page = await fetcher.fetch("https://ex.test/p.pdf");
    expect(page.contentType).toBe("pdf");
    expect(page.markdown).toContain("Page one text");
    expect(page.markdown.split("\f")[1]).toContain("Page two text");
    expect(page.bytes?.byteLength).toBe(MINIMAL_PDF.byteLength);
  });

  it("detects a pdf served as octet-stream by its magic bytes", async () => {
    const { fetcher } = fetcherFor({
      "https://ex.test/download": new Response(MINIMAL_PDF, { headers: { "content-type": "application/octet-stream" } }),
    });
    expect((await fetcher.fetch("https://ex.test/download")).contentType).toBe("pdf");
  });

  it("reports a pdf with no extractable text instead of snapshotting nothing", async () => {
    const blank = Buffer.from(
      "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n" +
      "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 100 100]>>endobj\ntrailer<</Root 1 0 R/Size 4>>\n%%EOF",
    );
    const { fetcher } = fetcherFor({ "https://ex.test/s.pdf": new Response(blank, { headers: { "content-type": "application/pdf" } }) });
    await expect(fetcher.fetch("https://ex.test/s.pdf")).rejects.toMatchObject({ kind: "empty" });
  });

  it("reports a corrupt pdf as unsupported rather than throwing something raw", async () => {
    const { fetcher } = fetcherFor({
      "https://ex.test/bad.pdf": new Response("%PDF-1.4 garbage", { headers: { "content-type": "application/pdf" } }),
    });
    await expect(fetcher.fetch("https://ex.test/bad.pdf")).rejects.toBeInstanceOf(FetchFailure);
  });
});

describe("robots.txt", () => {
  it("parses groups and picks the most specific agent", () => {
    const rules = parseRobots("User-agent: *\nDisallow: /private\n\nUser-agent: Quorum\nDisallow: /nope\nAllow: /nope/ok\n", "Quorum");
    expect(robotsAllows(rules, "/private/x")).toBe(true);
    expect(robotsAllows(rules, "/nope/x")).toBe(false);
    expect(robotsAllows(rules, "/nope/ok/y")).toBe(true);
  });

  it("falls back to the wildcard group and supports * and $", () => {
    const rules = parseRobots("User-agent: *\nDisallow: /*.json$\nDisallow: /admin\n", "Quorum");
    expect(robotsAllows(rules, "/data.json")).toBe(false);
    expect(robotsAllows(rules, "/data.json?x=1")).toBe(true);
    expect(robotsAllows(rules, "/admin/panel")).toBe(false);
    expect(robotsAllows(rules, "/blog")).toBe(true);
  });

  it("treats an empty Disallow as allow-all", () => {
    expect(robotsAllows(parseRobots("User-agent: *\nDisallow:\n", "Quorum"), "/anything")).toBe(true);
  });

  it("refuses a disallowed url with a robots failure and never requests it", async () => {
    const { fetcher, calls } = fetcherFor({
      "https://ex.test/robots.txt": new Response("User-agent: *\nDisallow: /secret\n", { headers: { "content-type": "text/plain" } }),
      "https://ex.test/secret/a": html(ARTICLE),
    });
    await expect(fetcher.fetch("https://ex.test/secret/a")).rejects.toMatchObject({ kind: "robots" });
    expect(calls.map((c) => c.url)).not.toContain("https://ex.test/secret/a");
  });

  it("fetches robots.txt once per origin", async () => {
    const { fetcher, calls } = fetcherFor({
      "https://ex.test/robots.txt": new Response("User-agent: *\nDisallow:\n"),
      "https://ex.test/a": html(ARTICLE),
      "https://ex.test/b": html(ARTICLE),
    });
    await fetcher.fetch("https://ex.test/a");
    await fetcher.fetch("https://ex.test/b");
    expect(calls.filter((c) => c.url.endsWith("/robots.txt"))).toHaveLength(1);
  });

  it("allows everything when robots.txt is missing or unreachable", async () => {
    const { fetcher } = fetcherFor({
      "https://ex.test/robots.txt": () => { throw new TypeError("down"); },
      "https://ex.test/a": html(ARTICLE),
    });
    expect((await fetcher.fetch("https://ex.test/a")).markdown).toContain("Latency fell");
  });

  it("can be switched off", async () => {
    const { fetcher } = fetcherFor({
      "https://ex.test/robots.txt": new Response("User-agent: *\nDisallow: /\n"),
      "https://ex.test/a": html(ARTICLE),
    }, { respectRobots: false });
    expect((await fetcher.fetch("https://ex.test/a")).markdown).toContain("Latency fell");
  });
});

describe("politeness", () => {
  it("spaces requests to one host apart and never overlaps them", async () => {
    let now = 0;
    const sleeps: number[] = [];
    let active = 0;
    let peak = 0;
    const { fetcher } = fetcherFor({
      "https://ex.test/a": async () => { active++; peak = Math.max(peak, active); await Promise.resolve(); active--; return html(ARTICLE); },
      "https://ex.test/b": async () => { active++; peak = Math.max(peak, active); await Promise.resolve(); active--; return html(ARTICLE); },
    }, {
      respectRobots: false, hostGapMs: 500, now: () => now,
      sleep: async (ms) => { sleeps.push(ms); now += ms; },
    });
    await Promise.all([fetcher.fetch("https://ex.test/a"), fetcher.fetch("https://ex.test/b")]);
    expect(peak).toBe(1);
    expect(sleeps.some((ms) => ms > 0 && ms <= 500)).toBe(true);
  });

  it("does not make different hosts wait for each other", async () => {
    const sleeps: number[] = [];
    const { fetcher } = fetcherFor({
      "https://a.test/x": html(ARTICLE),
      "https://b.test/x": html(ARTICLE),
    }, { respectRobots: false, hostGapMs: 500, sleep: async (ms) => { sleeps.push(ms); } });
    await Promise.all([fetcher.fetch("https://a.test/x"), fetcher.fetch("https://b.test/x")]);
    expect(sleeps).toEqual([]);
  });
});

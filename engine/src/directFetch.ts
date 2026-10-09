import { extractText, getDocumentProxy, getMeta } from "unpdf";
import type { FetchResponse } from "./search.js";

export type FetchFailureKind =
  | "blocked"
  | "paywall"
  | "not_found"
  | "http_error"
  | "timeout"
  | "network"
  | "too_large"
  | "unsupported"
  | "js_only"
  | "empty"
  | "robots"
  | "redirects";

export class FetchFailure extends Error {
  constructor(readonly kind: FetchFailureKind, readonly url: string, message: string) {
    super(message);
    this.name = "FetchFailure";
  }
}

export function fetchFailureKind(e: unknown): FetchFailureKind {
  return e instanceof FetchFailure ? e.kind : "network";
}

export interface DirectFetcherOptions {
  fetchImpl?: typeof fetch;
  userAgent?: string;
  timeoutMs?: number;
  maxBytes?: number;
  maxRedirects?: number;
  maxRetries?: number;
  backoffMs?: number;
  hostGapMs?: number;
  respectRobots?: boolean;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
}

export const USER_AGENT = "Quorum/0.1 (research assistant; fetches pages a user asked it to read)";

const MIN_TEXT_CHARS = 100;
const MIN_PDF_CHARS = 10;
const MAX_RETRY_AFTER_MS = 5000;
const PAYWALL_SIGNS = /subscribe to (?:continue|read|unlock)|sign in to (?:continue|read)|log in to (?:continue|read)|create a free account to (?:continue|read)|already a subscriber|this (?:content|article) is (?:for|available to) (?:members|subscribers)|premium content|to continue reading|unlock this article/i;
const SCRIPT_SHELL_SIGNS = /enable javascript|requires javascript|javascript is (?:required|disabled)/i;
const TEXT_TYPES = /^(?:text\/(?:plain|markdown|csv|xml)|application\/(?:json|xml|rss\+xml|atom\+xml))/;
const HTML_TYPES = /^(?:text\/html|application\/xhtml\+xml)/;

export class DirectFetcher {
  private readonly fetchImpl: typeof fetch;
  private readonly userAgent: string;
  private readonly timeoutMs: number;
  private readonly maxBytes: number;
  private readonly maxRedirects: number;
  private readonly maxRetries: number;
  private readonly backoffMs: number;
  private readonly hostGapMs: number;
  private readonly respectRobots: boolean;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly now: () => number;
  private readonly hostTails = new Map<string, Promise<void>>();
  private readonly hostLastEnd = new Map<string, number>();
  private readonly robots = new Map<string, Promise<RobotsRules | undefined>>();

  constructor(options: DirectFetcherOptions = {}) {
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.userAgent = options.userAgent ?? USER_AGENT;
    this.timeoutMs = options.timeoutMs ?? 20_000;
    this.maxBytes = options.maxBytes ?? 20 * 1024 * 1024;
    this.maxRedirects = options.maxRedirects ?? 5;
    this.maxRetries = options.maxRetries ?? 3;
    this.backoffMs = options.backoffMs ?? 500;
    this.hostGapMs = options.hostGapMs ?? 750;
    this.respectRobots = options.respectRobots ?? true;
    this.sleep = options.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    this.now = options.now ?? Date.now;
  }

  async fetch(url: string): Promise<FetchResponse> {
    let target = parseHttpUrl(url);
    for (let hop = 0; hop <= this.maxRedirects; hop++) {
      await this.requireRobotsAllows(target);
      const response = await this.politely(target.host, () => this.request(target));
      if (!isRedirect(response.status)) return this.read(url, target, response);
      target = redirectTarget(url, target, response);
    }
    throw new FetchFailure("redirects", url, `Too many redirects (more than ${this.maxRedirects}) reading ${url}`);
  }

  private async request(target: URL): Promise<Response> {
    let last: Response | undefined;
    for (let attempt = 1; attempt <= this.maxRetries; attempt++) {
      last = await this.attempt(target);
      if (!isRetryable(last.status)) return last;
      if (attempt < this.maxRetries) await this.sleep(this.retryDelayMs(last, attempt));
    }
    return last!;
  }

  private async attempt(target: URL): Promise<Response> {
    try {
      return await this.fetchImpl(target.href, {
        headers: {
          "user-agent": this.userAgent,
          accept: "text/html,application/xhtml+xml,application/pdf;q=0.9,text/plain;q=0.8,*/*;q=0.1",
          "accept-language": "en,*;q=0.5",
        },
        redirect: "manual",
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (e) {
      throw asFailure(e, target.href);
    }
  }

  private retryDelayMs(response: Response, attempt: number): number {
    const seconds = Number(response.headers.get("retry-after"));
    if (Number.isFinite(seconds) && seconds > 0) return Math.min(seconds * 1000, MAX_RETRY_AFTER_MS);
    return this.backoffMs * 2 ** (attempt - 1);
  }

  private async read(url: string, target: URL, response: Response): Promise<FetchResponse> {
    refuseStatus(url, response.status);
    const contentType = (response.headers.get("content-type") ?? "").toLowerCase();
    const declared = Number(response.headers.get("content-length"));
    if (Number.isFinite(declared) && declared > this.maxBytes) throw tooLarge(url, declared, this.maxBytes);
    const bytes = await readCapped(response, url, this.maxBytes);

    if (isPdfBytes(bytes) || contentType.startsWith("application/pdf")) return readPdf(url, bytes);
    if (HTML_TYPES.test(contentType) || (!contentType && looksLikeHtml(bytes))) {
      return readHtml(url, decode(bytes, contentType));
    }
    if (TEXT_TYPES.test(contentType) || !contentType) return readText(url, decode(bytes, contentType));
    throw new FetchFailure("unsupported", url, `Cannot read ${contentType.split(";")[0]} content at ${target.href}`);
  }

  private politely<T>(host: string, task: () => Promise<T>): Promise<T> {
    const previous = this.hostTails.get(host) ?? Promise.resolve();
    const run = previous.then(async () => {
      const lastEnd = this.hostLastEnd.get(host);
      const wait = lastEnd === undefined ? 0 : lastEnd + this.hostGapMs - this.now();
      if (wait > 0) await this.sleep(wait);
      try {
        return await task();
      } finally {
        this.hostLastEnd.set(host, this.now());
      }
    });
    this.hostTails.set(host, run.then(() => undefined, () => undefined));
    return run;
  }

  private async requireRobotsAllows(target: URL): Promise<void> {
    if (!this.respectRobots) return;
    const rules = await this.robotsFor(target);
    if (rules && !robotsAllows(rules, target.pathname + target.search)) {
      throw new FetchFailure("robots", target.href, `robots.txt on ${target.host} disallows fetching ${target.pathname}`);
    }
  }

  private robotsFor(target: URL): Promise<RobotsRules | undefined> {
    const cached = this.robots.get(target.origin);
    if (cached) return cached;
    const loading = this.loadRobots(target);
    this.robots.set(target.origin, loading);
    return loading;
  }

  private async loadRobots(target: URL): Promise<RobotsRules | undefined> {
    try {
      const robotsUrl = new URL("/robots.txt", target.origin);
      const response = await this.politely(target.host, () => this.attempt(robotsUrl));
      if (!response.ok) return undefined;
      const body = new TextDecoder().decode(await readCapped(response, robotsUrl.href, 512 * 1024));
      return parseRobots(body, this.userAgent.split(/[\/\s]/)[0]!);
    } catch {
      return undefined;
    }
  }
}

function parseHttpUrl(url: string): URL {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new FetchFailure("unsupported", url, `Not a valid URL: ${url}`);
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new FetchFailure("unsupported", url, `Only http and https URLs can be fetched, not ${parsed.protocol}`);
  }
  return parsed;
}

function isRedirect(status: number): boolean {
  return status === 301 || status === 302 || status === 303 || status === 307 || status === 308;
}

function isRetryable(status: number): boolean {
  return status === 429 || status === 500 || status === 502 || status === 503 || status === 504;
}

function redirectTarget(url: string, from: URL, response: Response): URL {
  const location = response.headers.get("location");
  if (!location) throw new FetchFailure("http_error", url, `HTTP ${response.status} redirect without a Location from ${from.href}`);
  let next: URL;
  try {
    next = new URL(location, from);
  } catch {
    throw new FetchFailure("http_error", url, `Redirect from ${from.href} points to an invalid location`);
  }
  return parseHttpUrl(next.href);
}

function refuseStatus(url: string, status: number): void {
  if (status >= 200 && status < 300) return;
  if (status === 401 || status === 403 || status === 451) {
    throw new FetchFailure("blocked", url, `HTTP ${status}: the site refused automated access to ${url}`);
  }
  if (status === 402) throw new FetchFailure("paywall", url, `HTTP 402: ${url} requires payment`);
  if (status === 404 || status === 410) throw new FetchFailure("not_found", url, `HTTP ${status}: ${url} does not exist`);
  throw new FetchFailure("http_error", url, `HTTP ${status} fetching ${url}`);
}

function tooLarge(url: string, size: number, cap: number): FetchFailure {
  return new FetchFailure("too_large", url, `${url} is larger than the ${cap}-byte capture limit (${size} bytes)`);
}

async function readCapped(response: Response, url: string, maxBytes: number): Promise<Uint8Array> {
  const reader = response.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        reader.cancel().catch(() => undefined);
        throw tooLarge(url, total, maxBytes);
      }
      chunks.push(value);
    }
  } catch (e) {
    throw asFailure(e, url);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

function asFailure(e: unknown, url: string): FetchFailure {
  if (e instanceof FetchFailure) return e;
  const name = (e as { name?: string })?.name;
  if (name === "TimeoutError" || name === "AbortError") return new FetchFailure("timeout", url, `Timed out fetching ${url}`);
  const detail = e instanceof Error ? e.message : String(e);
  return new FetchFailure("network", url, `Could not reach ${url}: ${detail}`);
}

function isPdfBytes(bytes: Uint8Array): boolean {
  return bytes.length > 4 && bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
}

function looksLikeHtml(bytes: Uint8Array): boolean {
  const head = new TextDecoder().decode(bytes.slice(0, 512)).trimStart().toLowerCase();
  return head.startsWith("<!doctype html") || head.startsWith("<html") || head.startsWith("<head") || head.startsWith("<body");
}

function decode(bytes: Uint8Array, contentType: string): string {
  const charset = /charset=["']?([\w-]+)/i.exec(contentType)?.[1] ?? "utf-8";
  try {
    return new TextDecoder(charset as "utf-8").decode(bytes);
  } catch {
    return new TextDecoder().decode(bytes);
  }
}

async function readPdf(url: string, bytes: Uint8Array): Promise<FetchResponse> {
  let pages: string[];
  let title = "";
  try {
    const document = await getDocumentProxy(bytes.slice());
    const extracted = await extractText(document, { mergePages: false });
    pages = extracted.text.map((page) => page.trim());
    title = await pdfTitle(document);
  } catch (e) {
    throw new FetchFailure("unsupported", url, `Could not read the PDF at ${url}: ${e instanceof Error ? e.message : String(e)}`);
  }
  const markdown = pages.join("\f");
  if (markdown.replace(/\s/g, "").length < MIN_PDF_CHARS) {
    throw new FetchFailure("empty", url, `The PDF at ${url} has no extractable text (a scan?)`);
  }
  return { url, markdown, title, contentType: "pdf", bytes };
}

async function pdfTitle(document: Awaited<ReturnType<typeof getDocumentProxy>>): Promise<string> {
  try {
    const meta = await getMeta(document);
    const title = (meta.info as { Title?: unknown } | undefined)?.Title;
    return typeof title === "string" ? title.trim() : "";
  } catch {
    return "";
  }
}

function readText(url: string, text: string): FetchResponse {
  const markdown = text.trim();
  if (!markdown) throw new FetchFailure("empty", url, `${url} returned no text`);
  return { url, markdown, title: "", contentType: "text" };
}

function readHtml(url: string, html: string): FetchResponse {
  const { markdown, whole } = extractReadable(html);
  const title = pageTitle(html);
  if (PAYWALL_SIGNS.test(markdown) && markdown.length < 1500) {
    throw new FetchFailure("paywall", url, `${url} shows a paywall or sign-in wall instead of the article`);
  }
  if (markdown.length < MIN_TEXT_CHARS) {
    if (isScriptShell(html, markdown)) {
      throw new FetchFailure("js_only", url, `${url} renders its content with JavaScript, so a plain fetch sees nothing`);
    }
    throw new FetchFailure("empty", url, `${url} has almost no readable text (${markdown.length} characters)`);
  }
  return { url, markdown, title, contentType: "html", ...(whole ? { degraded: true } : {}) };
}

function isScriptShell(html: string, text: string): boolean {
  return /<script\b/i.test(html) || /<noscript\b/i.test(html) || SCRIPT_SHELL_SIGNS.test(text);
}

function pageTitle(html: string): string {
  const og = /<meta\s[^>]*property=["']og:title["'][^>]*content=["']([^"']*)["']/i.exec(html)?.[1]
    ?? /<meta\s[^>]*content=["']([^"']*)["'][^>]*property=["']og:title["']/i.exec(html)?.[1];
  const raw = og ?? /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html)?.[1] ?? "";
  return decodeEntities(raw).replace(/\s+/g, " ").trim();
}

function extractReadable(html: string): { markdown: string; whole: boolean } {
  const cleaned = html
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<(script|style|noscript|template|svg|iframe|canvas|head)\b[\s\S]*?<\/\1>/gi, "");
  const container = enclosed(cleaned, "article") ?? enclosed(cleaned, "main");
  const body = container ?? enclosed(cleaned, "body") ?? cleaned;
  const chrome = container ? ["nav", "aside", "form", "button", "select", "dialog"] : ["nav", "header", "footer", "aside", "form", "button", "select", "dialog"];
  const stripped = chrome.reduce((text, tag) => text.replace(new RegExp(`<${tag}\\b[\\s\\S]*?<\\/${tag}>`, "gi"), ""), body);
  return { markdown: htmlToText(stripped), whole: container === undefined };
}

function enclosed(html: string, tag: string): string | undefined {
  const open = new RegExp(`<${tag}\\b[^>]*>`, "i").exec(html);
  if (!open) return undefined;
  const close = html.toLowerCase().lastIndexOf(`</${tag}>`);
  if (close < open.index) return undefined;
  const inner = html.slice(open.index + open[0].length, close);
  return htmlToText(inner).length >= MIN_TEXT_CHARS ? inner : undefined;
}

function htmlToText(html: string): string {
  const text = html
    .replace(/<h([1-6])\b[^>]*>/gi, (_, level: string) => `\n\n${"#".repeat(Number(level))} `)
    .replace(/<li\b[^>]*>/gi, "\n- ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/?(?:p|div|section|tr|blockquote|pre|table|ul|ol|hr|h[1-6]|figure|figcaption|dl|dt|dd)\b[^>]*>/gi, "\n\n")
    .replace(/<[^>]+>/g, " ");
  return decodeEntities(text)
    .split("\n")
    .map((line) => line.replace(/[ \t ]+/g, " ").trim())
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

const NAMED_ENTITIES: Record<string, string> = {
  nbsp: " ", amp: "&", quot: '"', apos: "'", lt: "<", gt: ">", mdash: "—", ndash: "–", hellip: "…",
  rsquo: "’", lsquo: "‘", rdquo: "”", ldquo: "“", copy: "©", reg: "®", trade: "™", euro: "€", pound: "£", bull: "•",
};

function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (match, entity: string) => {
    if (entity[0] === "#") {
      const code = entity[1]!.toLowerCase() === "x" ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
      return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : match;
    }
    return NAMED_ENTITIES[entity.toLowerCase()] ?? match;
  });
}

interface RobotsRule {
  allow: boolean;
  pattern: RegExp;
  length: number;
}

export type RobotsRules = RobotsRule[];

export function parseRobots(body: string, agent: string): RobotsRules {
  const groups: Array<{ agents: string[]; rules: RobotsRule[] }> = [];
  let current: { agents: string[]; rules: RobotsRule[] } | undefined;
  let collectingAgents = false;
  for (const raw of body.split(/\r?\n/)) {
    const line = raw.replace(/#.*/, "").trim();
    const separator = line.indexOf(":");
    if (separator === -1) continue;
    const field = line.slice(0, separator).trim().toLowerCase();
    const value = line.slice(separator + 1).trim();
    if (field === "user-agent") {
      if (!collectingAgents || !current) {
        current = { agents: [], rules: [] };
        groups.push(current);
      }
      current.agents.push(value.toLowerCase());
      collectingAgents = true;
      continue;
    }
    collectingAgents = false;
    if (!current || (field !== "allow" && field !== "disallow") || value === "") continue;
    current.rules.push({ allow: field === "allow", pattern: robotsPattern(value), length: value.length });
  }
  const token = agent.toLowerCase();
  const specific = groups.filter((g) => g.agents.some((a) => a !== "*" && token.includes(a)));
  const chosen = specific.length > 0 ? specific : groups.filter((g) => g.agents.includes("*"));
  return chosen.flatMap((g) => g.rules);
}

function robotsPattern(value: string): RegExp {
  const anchored = value.endsWith("$");
  const body = (anchored ? value.slice(0, -1) : value).replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
  return new RegExp(`^${body}${anchored ? "$" : ""}`);
}

export function robotsAllows(rules: RobotsRules, path: string): boolean {
  let verdict: RobotsRule | undefined;
  for (const rule of rules) {
    if (!rule.pattern.test(path)) continue;
    if (!verdict || rule.length > verdict.length || (rule.length === verdict.length && rule.allow)) verdict = rule;
  }
  return verdict ? verdict.allow : true;
}

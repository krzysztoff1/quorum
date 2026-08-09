import { createHash } from "node:crypto";
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export type SourceContentType = "html" | "pdf" | "text";

export type QuoteMatch = "exact" | "normalized" | "fuzzy" | "unresolved";

/// How much of this source the run actually kept. `failed` means the bytes never reached disk or cannot be
/// read back; `degraded` means the text is a tag-strip approximation of the page rather than an extraction.
/// Either way a citation against it may be unresolvable, and the reader is told which it is instead of
/// being left to infer it.
export type SourceCapture = "ok" | "failed" | "degraded";

export type CaptureStage = "write" | "read" | "index";

export interface CaptureFailure {
  source_id: string;
  url: string;
  stage: CaptureStage;
  error: string;
}

/// One source captured at research time. `snapshot_path` is the extracted text that a citation's
/// `start`/`end` index into; `original_path` is the bytes as fetched. Both are evidence-directory-relative
/// and null when the fetch produced nothing to keep — a url seen only in search results still registers,
/// so a citation against it resolves honestly to `unresolved`.
export interface SourceDocument {
  source_id: string;
  url: string;
  title: string;
  content_type: SourceContentType;
  fetched_at: string | null;
  snapshot_path: string | null;
  original_path: string | null;
  text_length: number;
  byte_size: number;
  page_offsets: number[];
  capture: SourceCapture;
}

/// A quote pinned to a source document. `start`/`end` are character offsets into that document's stored
/// snapshot, omitted when `match` is `unresolved`.
export interface Citation {
  id: string;
  source_id: string;
  quote: string;
  start?: number;
  end?: number;
  match: QuoteMatch;
  page?: number;
}

/// What a model asked us to verify: its marker id, the source it claims, and the span it claims to quote.
export interface CitationRequest {
  id: string;
  source: string;
  quote: string;
}

export interface RegisterInput {
  url: string;
  title?: string;
  contentType?: SourceContentType;
  text?: string;
  bytes?: Uint8Array;
  degraded?: boolean;
}

export interface EvidenceStoreOptions {
  dir?: string;
  now?: () => number;
}

const DOCUMENTS_FILE = "documents.jsonl";
const SOURCES_DIR = "sources";

/// The two bars a reworded quote must clear together. Dice alone accepts a bag of the right words in any
/// arrangement — a scrambled quote scores 1.0 — so an order score rides alongside it. Mirrored by the Swift
/// `QuoteLocator` and pinned by `Tests/QuorumCoreTests/Fixtures/quote-match-contract.json`.
export const FUZZY_DICE_THRESHOLD = 0.82;
export const FUZZY_ORDER_THRESHOLD = 0.6;

const EXTENSIONS: Record<SourceContentType, string> = { pdf: "pdf", html: "html", text: "txt" };

/// One url is one document: lowercased, trailing slashes stripped. The store dedupes on this, and the
/// url-trace check in the run compares against it.
export function normalizeSource(source: string): string {
  let t = source.trim();
  while (t.endsWith("/")) t = t.slice(0, -1);
  return t.toLowerCase();
}

/// Source ids are derived from the url, not counted out, because a run's evidence directory is written by
/// several writers at once — parallel angles in this process plus one `mcp-serve` subprocess per Claude
/// Code angle. A counter would hand the same `s3` to two different urls and a citation would then resolve
/// against the wrong snapshot; deriving the id needs no coordination and makes dedupe-by-url and
/// dedupe-by-id the same thing.
export function sourceIdFor(url: string): string {
  return "s" + createHash("sha256").update(normalizeSource(url)).digest("hex").slice(0, 8);
}

/// Page starts (0-based offsets into the extracted text) when — and only when — the extraction actually
/// carries separators: form feeds, `--- page N ---`, or `[Page N]`. An empty table means "not paginated,
/// do not guess"; the reader falls back to PDFKit's own text search for a visual highlight.
export function pageOffsets(text: string): number[] {
  const starts = new Set<number>();
  for (let i = 0; i < text.length; i++) if (text[i] === "\f") starts.add(i + 1);
  const marker = /(?:-{2,}[ \t]*page[ \t]+\d+[ \t]*-{2,}|\[[ \t]*page[ \t]+\d+[ \t]*\])/gi;
  for (const hit of text.matchAll(marker)) {
    const start = hit.index ?? 0;
    if (atLineStart(text, start) && atLineEnd(text, start + hit[0].length)) starts.add(start);
  }
  if (starts.size === 0) return [];
  starts.add(0);
  return [...starts].sort((a, b) => a - b);
}

function atLineStart(text: string, index: number): boolean {
  if (index === 0) return true;
  return isBreak(text[index - 1]!) || /^[ \t]*$/.test(lineHeadBefore(text, index));
}

function atLineEnd(text: string, index: number): boolean {
  for (let i = index; i < text.length; i++) {
    if (isBreak(text[i]!)) return true;
    if (text[i] !== " " && text[i] !== "\t") return false;
  }
  return true;
}

function lineHeadBefore(text: string, index: number): string {
  let start = index;
  while (start > 0 && !isBreak(text[start - 1]!)) start--;
  return text.slice(start, index);
}

function isBreak(ch: string): boolean {
  return ch === "\n" || ch === "\r" || ch === "\f";
}

/// The `citations` array of a trailing fenced summary, cleaned: ids deduped, quotes trimmed, entries
/// missing an id or a quote dropped. Tolerates `source_id` in place of `source` — models paste back the
/// field name they were shown.
export function citationRequests(summary: unknown): CitationRequest[] {
  const raw = (summary as { citations?: unknown })?.citations;
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const requests: CitationRequest[] = [];
  for (const entry of raw) {
    const record = entry as Record<string, unknown> | null;
    const id = String(record?.id ?? "").trim();
    const source = String(record?.source ?? record?.source_id ?? "").trim();
    const quote = String(record?.quote ?? "").trim();
    if (!id || !quote || seen.has(id)) continue;
    seen.add(id);
    requests.push({ id, source, quote });
  }
  return requests;
}

/// The captured sources of one topic or one run, and the deterministic verification of quotes against
/// them. With a `dir` the store is durable and shareable across processes; without one it lives in memory
/// (tests, and runs where the app passed no directory).
export class EvidenceStore {
  private readonly dir: string | undefined;
  private readonly clock: () => number;
  private readonly documents = new Map<string, SourceDocument>();
  private readonly idsByUrl = new Map<string, string>();
  private readonly texts = new Map<string, string>();
  private readonly failures: CaptureFailure[] = [];

  constructor(options: EvidenceStoreOptions = {}) {
    this.dir = options.dir;
    this.clock = options.now ?? Date.now;
  }

  /// Read back a `documents.jsonl` written by a different process — the `mcp-serve` subprocess that serves
  /// a Claude Code angle's fetches cannot share memory with the engine that spawned it.
  static load(dir: string): EvidenceStore {
    const store = new EvidenceStore({ dir });
    store.ingestIndex();
    return store;
  }

  /// Capture a fetched source. Returns the stored document — the SAME object when nothing changed, so a
  /// caller can emit a `document` event only for what is new.
  register(input: RegisterInput): SourceDocument {
    const url = input.url.trim();
    const key = normalizeSource(url);
    const text = input.text ?? "";
    const known = this.idsByUrl.get(key);
    if (known !== undefined) {
      const current = this.documents.get(known)!;
      if (!text || this.snapshotText(known) !== undefined) return current;
    }
    const sourceId = known ?? sourceIdFor(key);
    const contentType = input.contentType ?? "text";
    const bytes = input.bytes;
    const document: SourceDocument = {
      source_id: sourceId,
      url,
      title: (input.title ?? "").trim(),
      content_type: contentType,
      fetched_at: new Date(this.clock()).toISOString(),
      snapshot_path: this.dir && text ? `${SOURCES_DIR}/${sourceId}.md` : null,
      original_path: this.dir && bytes?.byteLength ? `${SOURCES_DIR}/${sourceId}.${EXTENSIONS[contentType]}` : null,
      text_length: text.length,
      byte_size: bytes?.byteLength ?? 0,
      page_offsets: pageOffsets(text),
      capture: input.degraded ? "degraded" : "ok",
    };
    this.put(document, text);
    this.persist(document, text, bytes);
    return document;
  }

  /// A url seen only in search results: registered with no snapshot, so a citation against it resolves
  /// `unresolved` instead of borrowing trust it never earned. Never clobbers a real capture.
  registerSearchResult(url: string, title?: string): SourceDocument {
    return this.register({ url, ...(title === undefined ? {} : { title }) });
  }

  get(sourceId: string): SourceDocument | undefined {
    return this.documents.get(sourceId);
  }

  findByUrl(url: string): SourceDocument | undefined {
    const id = this.idsByUrl.get(normalizeSource(url));
    return id === undefined ? undefined : this.documents.get(id);
  }

  all(): SourceDocument[] {
    return [...this.documents.values()];
  }

  /// Whether anything here can actually be checked against. False means capture never ran (built-in search
  /// returns text to the model only), so an uncited claim is not evidence of a bad claim.
  hasSnapshots(): boolean {
    for (const document of this.documents.values()) {
      if (this.snapshotText(document.source_id) !== undefined) return true;
    }
    return false;
  }

  /// Everything this store could not keep or read back, so a run can report why a citation is unresolvable
  /// rather than leaving the reader to guess.
  captureFailures(): CaptureFailure[] {
    return [...this.failures];
  }

  /// Fold another store's captures in (documents plus their snapshot text), returning what this store did
  /// not already have. Purely in-memory: the files these documents point at are already on disk.
  merge(other: EvidenceStore): SourceDocument[] {
    for (const failure of other.captureFailures()) {
      const known = this.failures.some(
        (f) => f.source_id === failure.source_id && f.stage === failure.stage && f.error === failure.error,
      );
      if (!known) this.failures.push(failure);
    }
    const added: SourceDocument[] = [];
    for (const document of other.all()) {
      const known = this.idsByUrl.get(normalizeSource(document.url));
      const text = other.snapshotText(document.source_id);
      if (known !== undefined && (text === undefined || this.snapshotText(known) !== undefined)) continue;
      this.put(document, text ?? "");
      added.push(document);
    }
    return added;
  }

  resolveAll(requests: CitationRequest[]): Citation[] {
    return requests.map((request) => this.resolveCitation(request));
  }

  /// Locate a claimed quote in its source's snapshot: exact, then normalized, then a fuzzy window, then an
  /// honest `unresolved`. No model is asked whether the citation is real — a string search answers it and
  /// cannot be talked out of the answer.
  resolveCitation(request: CitationRequest): Citation {
    const quote = request.quote.trim();
    const document = this.lookup(request.source);
    const sourceId = document?.source_id ?? request.source;
    const text = document ? this.snapshotText(document.source_id) : undefined;
    if (!text || !quote) return { id: request.id, source_id: sourceId, quote, match: "unresolved" };

    const span = locate(text, quote);
    if (!span) return { id: request.id, source_id: sourceId, quote, match: "unresolved" };
    const page = document ? pageContaining(document, span.start) : undefined;
    return {
      id: request.id,
      source_id: sourceId,
      quote,
      start: span.start,
      end: span.end,
      match: span.match,
      ...(page === undefined ? {} : { page }),
    };
  }

  /// The extracted text behind a source id, read from `sources/<id>.md` on first use when the store was
  /// opened on a directory.
  snapshotText(sourceId: string): string | undefined {
    const cached = this.texts.get(sourceId);
    if (cached !== undefined) return cached.length > 0 ? cached : undefined;
    const document = this.documents.get(sourceId);
    if (!this.dir || !document?.snapshot_path) return undefined;
    try {
      const text = readFileSync(join(this.dir, document.snapshot_path), "utf8");
      this.texts.set(sourceId, text);
      return text.length > 0 ? text : undefined;
    } catch (e) {
      this.noteFailure(document, "read", e);
      return undefined;
    }
  }

  private noteFailure(document: Pick<SourceDocument, "source_id" | "url">, stage: CaptureStage, e: unknown): void {
    const known = this.documents.get(document.source_id);
    if (known) known.capture = "failed";
    const error = e instanceof Error ? e.message : String(e);
    if (this.failures.some((f) => f.source_id === document.source_id && f.stage === stage)) return;
    this.failures.push({ source_id: document.source_id, url: document.url, stage, error });
  }

  private lookup(source: string): SourceDocument | undefined {
    return this.documents.get(source) ?? this.findByUrl(source);
  }

  private put(document: SourceDocument, text: string): void {
    this.documents.set(document.source_id, document);
    this.idsByUrl.set(normalizeSource(document.url), document.source_id);
    if (text) this.texts.set(document.source_id, text);
  }

  /// Evidence capture is best-effort — an unwritable run directory must not fail the run — but it is never
  /// silent: what could not be written is stamped onto the document that goes out on the wire.
  private persist(document: SourceDocument, text: string, bytes: Uint8Array | undefined): void {
    if (!this.dir) return;
    try {
      if (document.snapshot_path || document.original_path) mkdirSync(join(this.dir, SOURCES_DIR), { recursive: true });
      else mkdirSync(this.dir, { recursive: true });
      if (document.snapshot_path) writeFileSync(join(this.dir, document.snapshot_path), text);
      if (document.original_path && bytes) writeFileSync(join(this.dir, document.original_path), bytes);
    } catch (e) {
      this.noteFailure(document, "write", e);
    }
    try {
      appendFileSync(join(this.dir, DOCUMENTS_FILE), JSON.stringify(document) + "\n");
    } catch (e) {
      this.noteFailure(document, "write", e);
    }
  }

  private ingestIndex(): void {
    if (!this.dir) return;
    let raw: string;
    try {
      raw = readFileSync(join(this.dir, DOCUMENTS_FILE), "utf8");
    } catch (e) {
      if ((e as { code?: string })?.code !== "ENOENT") {
        this.failures.push({ source_id: "", url: this.dir, stage: "index", error: errorText(e) });
      }
      return;
    }
    for (const line of raw.split("\n")) {
      const document = parseDocument(line);
      if (!document) {
        if (line.trim()) {
          this.failures.push({ source_id: "", url: this.dir, stage: "index", error: `unreadable index line: ${line.trim().slice(0, 120)}` });
        }
        continue;
      }
      const known = this.idsByUrl.get(normalizeSource(document.url));
      if (known !== undefined && !document.snapshot_path) continue;
      if (known !== undefined && known !== document.source_id) this.documents.delete(known);
      this.documents.set(document.source_id, document);
      this.idsByUrl.set(normalizeSource(document.url), document.source_id);
    }
  }
}

function parseDocument(line: string): SourceDocument | undefined {
  const trimmed = line.trim();
  if (!trimmed) return undefined;
  let raw: Record<string, unknown>;
  try {
    raw = JSON.parse(trimmed) as Record<string, unknown>;
  } catch {
    return undefined;
  }
  const sourceId = typeof raw.source_id === "string" ? raw.source_id : "";
  const url = typeof raw.url === "string" ? raw.url : "";
  if (!sourceId || !url) return undefined;
  return {
    source_id: sourceId,
    url,
    title: typeof raw.title === "string" ? raw.title : "",
    content_type: raw.content_type === "pdf" || raw.content_type === "html" ? raw.content_type : "text",
    fetched_at: typeof raw.fetched_at === "string" ? raw.fetched_at : null,
    snapshot_path: typeof raw.snapshot_path === "string" ? raw.snapshot_path : null,
    original_path: typeof raw.original_path === "string" ? raw.original_path : null,
    text_length: typeof raw.text_length === "number" ? raw.text_length : 0,
    byte_size: typeof raw.byte_size === "number" ? raw.byte_size : 0,
    page_offsets: Array.isArray(raw.page_offsets) ? raw.page_offsets.filter((n): n is number => typeof n === "number") : [],
    capture: raw.capture === "failed" || raw.capture === "degraded" ? raw.capture : "ok",
  };
}

function errorText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

function pageContaining(document: SourceDocument, offset: number): number | undefined {
  if (document.page_offsets.length === 0) return undefined;
  let page = 1;
  document.page_offsets.forEach((start, index) => {
    if (offset >= start) page = index + 1;
  });
  return page;
}

interface Span {
  start: number;
  end: number;
  match: "exact" | "normalized" | "fuzzy";
}

function locate(text: string, quote: string): Span | undefined {
  const exact = text.indexOf(quote);
  if (exact !== -1) return { start: exact, end: exact + quote.length, match: "exact" };

  const haystack = fold(text);
  const needle = fold(quote);
  if (needle.text.length === 0) return undefined;

  const normalized = haystack.text.indexOf(needle.text);
  if (normalized !== -1) {
    return {
      start: haystack.offsets[normalized]!,
      end: haystack.offsets[normalized + needle.text.length - 1]! + 1,
      match: "normalized",
    };
  }
  return bestWindow(haystack, needle);
}

interface Folded {
  text: string;
  offsets: number[];
}

const FOLDED_CHARS: Record<string, string> = {
  "‘": "'", "’": "'", "‛": "'", "′": "'",
  "“": '"', "”": '"', "‟": '"', "″": '"',
  "–": "-", "—": "-", "―": "-", "−": "-",
};

/// Case-folded, whitespace-collapsed, typography-flattened text plus, for every folded character, the
/// offset it came from — so a hit in the folded text maps back to a range in the ORIGINAL snapshot, which
/// is the file the reader highlights.
function fold(text: string): Folded {
  const chars: string[] = [];
  const offsets: number[] = [];
  let spaceAt = -1;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]!;
    if (/\s/.test(ch)) {
      if (spaceAt === -1) spaceAt = i;
      continue;
    }
    if (spaceAt !== -1) {
      if (chars.length > 0) {
        chars.push(" ");
        offsets.push(spaceAt);
      }
      spaceAt = -1;
    }
    chars.push((FOLDED_CHARS[ch] ?? ch).toLowerCase());
    offsets.push(i);
  }
  return { text: chars.join(""), offsets };
}

interface Token {
  text: string;
  start: number;
  end: number;
}

function tokenize(folded: Folded): Token[] {
  const tokens: Token[] = [];
  let cursor = 0;
  while (cursor < folded.text.length) {
    if (folded.text[cursor] === " ") {
      cursor += 1;
      continue;
    }
    let end = cursor;
    while (end < folded.text.length && folded.text[end] !== " ") end += 1;
    const word = folded.text.slice(cursor, end).replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}%]+$/gu, "");
    if (word) tokens.push({ text: word, start: folded.offsets[cursor]!, end: folded.offsets[end - 1]! + 1 });
    cursor = end;
  }
  return tokens;
}

export interface WindowScores {
  dice: number;
  order: number;
}

/// How the best-overlapping window in `text` scores against `quote`: word-set overlap, and how much of that
/// window reads in the quote's own order. Exported so the bar itself is testable, and so the Swift matcher
/// can be held to the same numbers.
export function windowScores(text: string, quote: string): WindowScores | undefined {
  return scoredWindow(tokenize(fold(text)), tokenize(fold(quote)))?.scores;
}

interface ScoredWindow {
  start: number;
  size: number;
  scores: WindowScores;
}

/// Best word-granularity window by Dice overlap, scored for word order too. Offsets are approximate by
/// construction — the quote was reworded — so the reader shows a "close match" badge rather than claiming
/// verbatim provenance.
function scoredWindow(words: Token[], target: Token[]): ScoredWindow | undefined {
  const wanted = target.map((t) => t.text);
  const size = wanted.length;
  if (size === 0 || words.length < size) return undefined;

  const unique = new Set(wanted);
  let best: ScoredWindow | undefined;
  for (let i = 0; i + size <= words.length; i++) {
    const window = words.slice(i, i + size).map((t) => t.text);
    const seen = new Set(window);
    let shared = 0;
    for (const word of seen) if (unique.has(word)) shared += 1;
    const dice = (2 * shared) / (seen.size + unique.size);
    if (best && dice <= best.scores.dice) continue;
    best = { start: i, size, scores: { dice, order: orderRatio(window, wanted) } };
  }
  return best;
}

/// Longest common subsequence of the two word sequences over the quote's length: 1.0 when the window reads
/// the quote's words in the quote's order, near zero when it merely contains them.
function orderRatio(window: string[], wanted: string[]): number {
  return wanted.length === 0 ? 0 : commonSubsequence(window, wanted) / wanted.length;
}

function commonSubsequence(left: string[], right: string[]): number {
  const columns = right.length;
  let previous = new Array<number>(columns + 1).fill(0);
  let current = new Array<number>(columns + 1).fill(0);
  for (let i = 1; i <= left.length; i++) {
    for (let j = 1; j <= columns; j++) {
      current[j] = left[i - 1] === right[j - 1]
        ? previous[j - 1]! + 1
        : Math.max(previous[j]!, current[j - 1]!);
    }
    [previous, current] = [current, previous];
  }
  return previous[columns] ?? 0;
}

/// How alike two short texts are, by the same two measures the quote ladder uses. Whole-string rather than
/// windowed: a rewrite may be longer than what it rewrote, so neither side can be treated as the target
/// length. Callers set their own bar — a verbatim span and a reworded claim are not held to the same one.
export function textSimilarity(left: string, right: string): WindowScores {
  const a = tokenize(fold(left)).map((t) => t.text);
  const b = tokenize(fold(right)).map((t) => t.text);
  if (a.length === 0 || b.length === 0) return { dice: 0, order: 0 };
  const uniqueA = new Set(a);
  const uniqueB = new Set(b);
  let shared = 0;
  for (const word of uniqueA) if (uniqueB.has(word)) shared += 1;
  return {
    dice: (2 * shared) / (uniqueA.size + uniqueB.size),
    order: commonSubsequence(a, b) / Math.max(a.length, b.length),
  };
}

function bestWindow(haystack: Folded, needle: Folded): Span | undefined {
  const words = tokenize(haystack);
  const window = scoredWindow(words, tokenize(needle));
  if (!window) return undefined;
  if (window.scores.dice < FUZZY_DICE_THRESHOLD || window.scores.order < FUZZY_ORDER_THRESHOLD) return undefined;
  return { start: words[window.start]!.start, end: words[window.start + window.size - 1]!.end, match: "fuzzy" };
}

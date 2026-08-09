import { describe, it, expect } from "vitest";
import { appendFileSync, chmodSync, mkdtempSync, readFileSync, existsSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  EvidenceStore,
  citationRequests,
  pageOffsets,
  normalizeSource,
  windowScores,
  textSimilarity,
  FUZZY_DICE_THRESHOLD,
  FUZZY_ORDER_THRESHOLD,
  type QuoteMatch,
} from "../src/evidence.js";

interface MatchContract {
  diceThreshold: number;
  orderThreshold: number;
  snapshots: Record<string, string>;
  cases: Array<{ name: string; snapshot: string; quote: string; match: QuoteMatch }>;
}

const CONTRACT: MatchContract = JSON.parse(
  readFileSync(
    join(import.meta.dirname, "..", "..", "Tests", "QuorumCoreTests", "Fixtures", "quote-match-contract.json"),
    "utf8",
  ),
);

function contractCase(name: string) {
  const found = CONTRACT.cases.find((c) => c.name === name);
  if (!found) throw new Error(`no contract case named "${name}"`);
  return { ...found, text: CONTRACT.snapshots[found.snapshot]! };
}

function matchOf(text: string, quote: string): QuoteMatch {
  const store = new EvidenceStore({ now: () => 0 });
  const doc = store.register({ url: "https://contract.test/s", text });
  return store.resolveCitation({ id: "c1", source: doc.source_id, quote }).match;
}

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), "quorum-evidence-"));
}

const SNAPSHOT = [
  "# Cold starts",
  "",
  "Measured across the fleet, latency fell 40% year over year in tested clusters,",
  'and the "control plane" absorbed the rest — a result the authors call decisive.',
].join("\n");

function storeWithSnapshot(dir?: string) {
  const store = new EvidenceStore({ ...(dir ? { dir } : {}), now: () => 0 });
  const doc = store.register({
    url: "https://nature.example/cold-starts",
    title: "Cold starts",
    contentType: "html",
    text: SNAPSHOT,
  });
  return { store, doc };
}

describe("EvidenceStore registration", () => {
  it("assigns a stable id per normalized url and returns the same document for a duplicate fetch", () => {
    const store = new EvidenceStore({ now: () => 0 });
    const first = store.register({ url: "https://ex.test/a", title: "A", contentType: "html", text: "body a" });
    const again = store.register({ url: "https://EX.test/a/", title: "A", contentType: "html", text: "body a" });
    const other = store.register({ url: "https://ex.test/b", title: "B", contentType: "html", text: "body b" });

    expect(again).toBe(first);
    expect(again.source_id).toBe(first.source_id);
    expect(other.source_id).not.toBe(first.source_id);
    expect(store.all()).toHaveLength(2);
    expect(store.get(first.source_id)?.url).toBe("https://ex.test/a");
  });

  it("gives the same id to the same url in two independent stores so merged runs never cross wires", () => {
    const a = new EvidenceStore();
    const b = new EvidenceStore();
    expect(a.register({ url: "https://ex.test/x", text: "x" }).source_id)
      .toBe(b.register({ url: "https://ex.test/x", text: "x" }).source_id);
    expect(b.register({ url: "https://ex.test/y", text: "y" }).source_id)
      .not.toBe(a.register({ url: "https://ex.test/x", text: "x" }).source_id);
  });

  it("records a search-result url with no snapshot, and upgrades it when the url is later fetched", () => {
    const store = new EvidenceStore({ now: () => 0 });
    const seen = store.registerSearchResult("https://ex.test/paper", "Paper");
    expect(seen.text_length).toBe(0);
    expect(store.resolveCitation({ id: "c1", source: seen.source_id, quote: "anything at all" }).match)
      .toBe("unresolved");

    const fetched = store.register({ url: "https://ex.test/paper", title: "Paper", contentType: "html", text: "the body" });
    expect(fetched.source_id).toBe(seen.source_id);
    expect(fetched).not.toBe(seen);
    expect(fetched.text_length).toBe("the body".length);
    expect(store.all()).toHaveLength(1);
  });

  it("never lets a later search result clobber a captured snapshot", () => {
    const { store, doc } = storeWithSnapshot();
    const again = store.registerSearchResult("https://nature.example/cold-starts/", "Cold starts");
    expect(again).toBe(doc);
    expect(again.text_length).toBe(SNAPSHOT.length);
  });

  it("keeps the first capture when the same url is fetched twice with different text", () => {
    const store = new EvidenceStore({ now: () => 0 });
    const first = store.register({ url: "https://ex.test/drift", text: "as it read at research time" });
    const second = store.register({ url: "https://ex.test/drift", text: "the page changed later" });
    expect(second).toBe(first);
    expect(store.resolveCitation({ id: "c1", source: first.source_id, quote: "as it read at research time" }).match)
      .toBe("exact");
  });
});

describe("EvidenceStore on disk", () => {
  it("writes the extracted text, the raw bytes, and one jsonl line per document", () => {
    const dir = tempDir();
    const store = new EvidenceStore({ dir, now: () => 0 });
    const doc = store.register({
      url: "https://nature.example/paper.pdf",
      title: "Paper",
      contentType: "pdf",
      text: "extracted page text",
      bytes: new Uint8Array([37, 80, 68, 70]),
    });

    expect(doc.snapshot_path).toBe(`sources/${doc.source_id}.md`);
    expect(doc.original_path).toBe(`sources/${doc.source_id}.pdf`);
    expect(readFileSync(join(dir, doc.snapshot_path!), "utf8")).toBe("extracted page text");
    expect(readFileSync(join(dir, doc.original_path!))).toEqual(Buffer.from([37, 80, 68, 70]));
    expect(doc.byte_size).toBe(4);
    expect(doc.fetched_at).toBe("1970-01-01T00:00:00.000Z");

    const lines = readFileSync(join(dir, "documents.jsonl"), "utf8").trim().split("\n");
    expect(lines).toHaveLength(1);
    expect(JSON.parse(lines[0]!)).toEqual(doc);
  });

  it("omits both paths when the fetch produced no text to keep", () => {
    const dir = tempDir();
    const store = new EvidenceStore({ dir, now: () => 0 });
    const doc = store.registerSearchResult("https://ex.test/never-fetched", "Listed only");
    expect(doc.snapshot_path).toBeNull();
    expect(doc.original_path).toBeNull();
    expect(existsSync(join(dir, "sources"))).toBe(false);
  });

  it("creates the run's evidence directory on first capture, since the app names it before it exists", () => {
    const dir = join(tempDir(), "run-7", "evidence");
    const store = new EvidenceStore({ dir, now: () => 0 });
    const listed = store.registerSearchResult("https://ex.test/listed", "Listed");
    const fetched = store.register({ url: "https://ex.test/fetched", text: "captured body" });
    expect(readFileSync(join(dir, fetched.snapshot_path!), "utf8")).toBe("captured body");
    expect(readFileSync(join(dir, "documents.jsonl"), "utf8").trim().split("\n")).toHaveLength(2);
    expect(EvidenceStore.load(dir).all().map((d) => d.source_id).sort())
      .toEqual([listed.source_id, fetched.source_id].sort());
  });

  it("loads a documents.jsonl written by another process and resolves quotes against its snapshots", () => {
    const dir = tempDir();
    const { doc } = storeWithSnapshot(dir);

    const reopened = EvidenceStore.load(dir);
    expect(reopened.all().map((d) => d.source_id)).toEqual([doc.source_id]);
    const citation = reopened.resolveCitation({ id: "c1", source: doc.source_id, quote: "latency fell 40% year over year" });
    expect(citation.match).toBe("exact");
    expect(SNAPSHOT.slice(citation.start!, citation.end!)).toBe("latency fell 40% year over year");
  });

  it("dedupes the index by normalized url, preferring the line that carries a snapshot", () => {
    const dir = tempDir();
    const writer = new EvidenceStore({ dir, now: () => 0 });
    writer.registerSearchResult("https://ex.test/paper", "Paper");
    writer.register({ url: "https://ex.test/paper/", title: "Paper", contentType: "html", text: "real body" });

    expect(readFileSync(join(dir, "documents.jsonl"), "utf8").trim().split("\n")).toHaveLength(2);
    const reopened = EvidenceStore.load(dir);
    expect(reopened.all()).toHaveLength(1);
    expect(reopened.all()[0]!.snapshot_path).not.toBeNull();
  });

  it("survives a truncated or garbled jsonl line instead of losing the whole index", () => {
    const dir = tempDir();
    const { doc } = storeWithSnapshot(dir);
    appendFileSync(join(dir, "documents.jsonl"), '{"source_id":"broken"\n');
    const reopened = EvidenceStore.load(dir);
    expect(reopened.all().map((d) => d.source_id)).toEqual([doc.source_id]);
  });

  it("is memory-only with no dir, writing nothing while still resolving quotes", () => {
    const dir = tempDir();
    const { store, doc } = storeWithSnapshot();
    expect(doc.snapshot_path).toBeNull();
    expect(readdirSync(dir)).toHaveLength(0);
    expect(store.resolveCitation({ id: "c1", source: doc.source_id, quote: "absorbed the rest" }).match).toBe("exact");
  });
});

describe("capture failures on the wire", () => {
  it("calls a clean capture ok", () => {
    const { doc, store } = storeWithSnapshot(tempDir());
    expect(doc.capture).toBe("ok");
    expect(store.captureFailures()).toEqual([]);
  });

  it("marks tag-soup fallback text degraded, because a quote will rarely locate in it", () => {
    const store = new EvidenceStore({ now: () => 0 });
    const doc = store.register({ url: "https://ex.test/soup", text: "nav home about body text", degraded: true });
    expect(doc.capture).toBe("degraded");
  });

  it("reports a snapshot write into an unwritable directory instead of swallowing it", () => {
    const dir = tempDir();
    chmodSync(dir, 0o500);
    try {
      const store = new EvidenceStore({ dir, now: () => 0 });
      const doc = store.register({ url: "https://ex.test/unwritable", text: SNAPSHOT });
      expect(doc.capture).toBe("failed");
      expect(store.captureFailures().map((f) => f.source_id)).toEqual([doc.source_id]);
      expect(store.captureFailures()[0]!.stage).toBe("write");
      expect(store.captureFailures()[0]!.error).not.toBe("");
    } finally {
      chmodSync(dir, 0o700);
    }
  });

  it("reports a garbled index line rather than dropping it in silence", () => {
    const dir = tempDir();
    storeWithSnapshot(dir);
    appendFileSync(join(dir, "documents.jsonl"), '{"source_id":"broken"\n');
    const reopened = EvidenceStore.load(dir);
    expect(reopened.captureFailures().map((f) => f.stage)).toEqual(["index"]);
  });

  it("stays quiet about an index that was simply never written", () => {
    expect(EvidenceStore.load(tempDir()).captureFailures()).toEqual([]);
  });

  it("marks a document failed when its snapshot file has gone missing under it", () => {
    const dir = tempDir();
    const { doc } = storeWithSnapshot(dir);
    const reopened = EvidenceStore.load(dir);
    rmSync(join(dir, doc.snapshot_path!));
    expect(reopened.resolveCitation({ id: "c1", source: doc.source_id, quote: "absorbed the rest" }).match)
      .toBe("unresolved");
    expect(reopened.get(doc.source_id)!.capture).toBe("failed");
    expect(reopened.captureFailures().map((f) => f.stage)).toEqual(["read"]);
  });

  it("carries failures across a merge, so the run reports what its angles could not keep", () => {
    const dir = tempDir();
    chmodSync(dir, 0o500);
    try {
      const angle = new EvidenceStore({ dir, now: () => 0 });
      angle.register({ url: "https://ex.test/unwritable", text: SNAPSHOT });
      const run = new EvidenceStore({ now: () => 0 });
      run.merge(angle);
      expect(run.captureFailures()).toEqual(angle.captureFailures());
    } finally {
      chmodSync(dir, 0o700);
    }
  });
});

describe("EvidenceStore.merge", () => {
  it("unions documents and their snapshots, reporting what was new", () => {
    const a = new EvidenceStore({ now: () => 0 });
    const b = new EvidenceStore({ now: () => 0 });
    const shared = a.register({ url: "https://ex.test/shared", text: "shared body" });
    b.register({ url: "https://ex.test/shared", text: "shared body" });
    const own = b.register({ url: "https://ex.test/own", text: "own body" });

    const run = new EvidenceStore();
    expect(run.merge(a).map((d) => d.source_id)).toEqual([shared.source_id]);
    expect(run.merge(b).map((d) => d.source_id)).toEqual([own.source_id]);
    expect(run.all()).toHaveLength(2);
    expect(run.resolveCitation({ id: "c1", source: own.source_id, quote: "own body" }).match).toBe("exact");
  });

  it("upgrades a snapshotless document from the store that actually fetched it", () => {
    const listed = new EvidenceStore();
    const fetched = new EvidenceStore();
    listed.registerSearchResult("https://ex.test/p", "P");
    const doc = fetched.register({ url: "https://ex.test/p", text: "body of p" });

    const run = new EvidenceStore();
    run.merge(listed);
    expect(run.merge(fetched).map((d) => d.source_id)).toEqual([doc.source_id]);
    expect(run.all()).toHaveLength(1);
    expect(run.resolveCitation({ id: "c1", source: doc.source_id, quote: "body of p" }).match).toBe("exact");
  });
});

describe("quote resolution ladder", () => {
  it("exact: offsets index the stored snapshot itself", () => {
    const { store, doc } = storeWithSnapshot();
    const c = store.resolveCitation({ id: "c1", source: doc.source_id, quote: "latency fell 40% year over year" });
    expect(c).toMatchObject({ id: "c1", source_id: doc.source_id, match: "exact" });
    expect(SNAPSHOT.slice(c.start!, c.end!)).toBe("latency fell 40% year over year");
  });

  it("normalized: folds whitespace runs, smart quotes, dashes and case — offsets still index the original", () => {
    const { store, doc } = storeWithSnapshot();
    const c = store.resolveCitation({
      id: "c1",
      source: doc.source_id,
      quote: "and the “control plane”    absorbed the REST — a result",
    });
    expect(c.match).toBe("normalized");
    expect(SNAPSHOT.slice(c.start!, c.end!)).toBe('and the "control plane" absorbed the rest — a result');
  });

  it("normalized: a quote broken across the snapshot's line wrap still resolves", () => {
    const { store, doc } = storeWithSnapshot();
    const c = store.resolveCitation({
      id: "c1",
      source: doc.source_id,
      quote: "in tested clusters, and the “control plane” absorbed",
    });
    expect(c.match).toBe("normalized");
    expect(SNAPSHOT.slice(c.start!, c.end!)).toContain("\n");
  });

  it("fuzzy: a lightly reworded quote resolves with approximate offsets", () => {
    const { store, doc } = storeWithSnapshot();
    const c = store.resolveCitation({
      id: "c1",
      source: doc.source_id,
      quote: "Measured across the fleet, latency fell 40% year over year in the tested clusters",
    });
    expect(c.match).toBe("fuzzy");
    expect(SNAPSHOT.slice(c.start!, c.end!)).toContain("latency fell 40%");
  });

  it("unresolved: a quote the source does not support keeps no offsets", () => {
    const { store, doc } = storeWithSnapshot();
    const c = store.resolveCitation({
      id: "c1",
      source: doc.source_id,
      quote: "Kubernetes eliminated cold starts entirely across every region in 2019",
    });
    expect(c).toEqual({ id: "c1", source_id: doc.source_id, quote: "Kubernetes eliminated cold starts entirely across every region in 2019", match: "unresolved" });
  });

  it("unresolved: an unknown source id is reported honestly, not attributed to a neighbour", () => {
    const { store } = storeWithSnapshot();
    const c = store.resolveCitation({ id: "c1", source: "s-nonexistent", quote: "latency fell 40% year over year" });
    expect(c).toMatchObject({ source_id: "s-nonexistent", match: "unresolved" });
    expect(c.start).toBeUndefined();
  });

  it("accepts a url in place of a source id, since models paste what they were shown", () => {
    const { store, doc } = storeWithSnapshot();
    const c = store.resolveCitation({
      id: "c1",
      source: "https://nature.example/cold-starts/",
      quote: "absorbed the rest",
    });
    expect(c.source_id).toBe(doc.source_id);
    expect(c.match).toBe("exact");
  });

  it("fills page from the document's page table when the extraction carried separators", () => {
    const store = new EvidenceStore({ now: () => 0 });
    const doc = store.register({
      url: "https://ex.test/report.pdf",
      contentType: "pdf",
      text: "cover page\n\f--- page 2 ---\nthe finding lives on the second page\n\f[Page 3]\ntail",
    });
    expect(doc.page_offsets.length).toBe(3);
    const c = store.resolveCitation({ id: "c1", source: doc.source_id, quote: "the finding lives on the second page" });
    expect(c.match).toBe("exact");
    expect(c.page).toBe(2);
  });

  it("leaves page unset when the extraction had no page separators to trust", () => {
    const { store, doc } = storeWithSnapshot();
    expect(doc.page_offsets).toEqual([]);
    expect(store.resolveCitation({ id: "c1", source: doc.source_id, quote: "absorbed the rest" }).page).toBeUndefined();
  });

  it("resolveAll keeps every citation, resolved or not, in the order given", () => {
    const { store, doc } = storeWithSnapshot();
    const out = store.resolveAll([
      { id: "c1", source: doc.source_id, quote: "absorbed the rest" },
      { id: "c2", source: doc.source_id, quote: "no such words in the snapshot at all, none" },
    ]);
    expect(out.map((c) => c.id)).toEqual(["c1", "c2"]);
    expect(out.map((c) => c.match)).toEqual(["exact", "unresolved"]);
  });
});

describe("order-aware fuzzy matching", () => {
  it("refuses a scrambled quote that the set-Dice bar alone would have called a close match", () => {
    const scrambled = contractCase("scrambled quote: every word of the source, none of its order");
    const scores = windowScores(scrambled.text, scrambled.quote)!;
    expect(scores.dice).toBeGreaterThanOrEqual(FUZZY_DICE_THRESHOLD);
    expect(scores.order).toBeLessThan(FUZZY_ORDER_THRESHOLD);
    expect(matchOf(scrambled.text, scrambled.quote)).toBe("unresolved");
  });

  it("keeps a reworded quote that reads in the source's own order", () => {
    const reworded = contractCase("lightly reworded quote in the source's own order");
    const scores = windowScores(reworded.text, reworded.quote)!;
    expect(scores.dice).toBeGreaterThanOrEqual(FUZZY_DICE_THRESHOLD);
    expect(scores.order).toBeGreaterThanOrEqual(FUZZY_ORDER_THRESHOLD);
    expect(matchOf(reworded.text, reworded.quote)).toBe("fuzzy");
  });

  it("resolves an order score sitting exactly on the threshold", () => {
    const boundary = contractCase("order score exactly at the threshold");
    expect(windowScores(boundary.text, boundary.quote)).toEqual({ dice: 1, order: FUZZY_ORDER_THRESHOLD });
    expect(matchOf(boundary.text, boundary.quote)).toBe("fuzzy");
  });

  it("drops an order score one word below the threshold", () => {
    const boundary = contractCase("order score one word below the threshold");
    const scores = windowScores(boundary.text, boundary.quote)!;
    expect(scores.dice).toBe(1);
    expect(scores.order).toBeLessThan(FUZZY_ORDER_THRESHOLD);
    expect(matchOf(boundary.text, boundary.quote)).toBe("unresolved");
  });

  it("pins the thresholds the Swift QuoteLocator is built against", () => {
    expect(FUZZY_DICE_THRESHOLD).toBe(CONTRACT.diceThreshold);
    expect(FUZZY_ORDER_THRESHOLD).toBe(CONTRACT.orderThreshold);
  });
});

/// What the rewrite-survival check in `run.ts` leans on: a whole-string score, so a rewrite that grew is
/// still comparable, and one that keeps the words but not the argument is not.
describe("textSimilarity", () => {
  it("scores a reworded claim high on both measures", () => {
    const scores = textSimilarity(
      "Cold starts fell 40% year over year in tested clusters",
      "Cold starts dropped 40% year on year across the tested clusters");
    expect(scores.dice).toBeGreaterThan(0.6);
    expect(scores.order).toBeGreaterThan(0.5);
  });

  it("scores the same words in a scrambled order low on order alone", () => {
    const scores = textSimilarity(
      "cold starts fell in tested clusters",
      "clusters tested in fell starts cold");
    expect(scores.dice).toBe(1);
    expect(scores.order).toBeLessThan(0.5);
  });

  it("compares a longer rewrite against a shorter original rather than giving up", () => {
    const scores = textSimilarity("cold starts fell", "cold starts fell sharply last quarter");
    expect(scores.order).toBeCloseTo(3 / 6, 10);
  });

  it("scores unrelated claims at zero", () => {
    expect(textSimilarity("cold starts fell in tested clusters", "serverless adoption grew across retail"))
      .toEqual({ dice: 0, order: 0 });
  });
});

describe("shared quote-match contract (Tests/QuorumCoreTests/Fixtures/quote-match-contract.json)", () => {
  for (const shared of CONTRACT.cases) {
    it(`resolves ${shared.name} to ${shared.match}`, () => {
      expect(matchOf(CONTRACT.snapshots[shared.snapshot]!, shared.quote)).toBe(shared.match);
    });
  }
});

describe("pageOffsets", () => {
  it("reads form feeds as page boundaries starting at zero", () => {
    expect(pageOffsets("page one\fpage two\fpage three")).toEqual([0, 9, 18]);
  });

  it("reads --- page N --- and [Page N] separator lines", () => {
    const text = "intro\n--- page 2 ---\nbody\n[Page 3]\ntail";
    expect(pageOffsets(text)).toEqual([0, 6, 26]);
  });

  it("returns an empty table rather than guessing when nothing marks a page", () => {
    expect(pageOffsets("just prose\nwith lines\nand no pages")).toEqual([]);
  });
});

describe("citationRequests", () => {
  it("reads the fenced summary's citations array, tolerating junk", () => {
    expect(
      citationRequests({
        citations: [
          { id: "c1", source: "s1", quote: "  a real quote  " },
          { id: "c1", source: "s1", quote: "duplicate id" },
          { id: "", source: "s1", quote: "no id" },
          { id: "c2", source_id: "s2", quote: "alternate key" },
          { id: "c3", source: "s3" },
          "nonsense",
        ],
      })
    ).toEqual([
      { id: "c1", source: "s1", quote: "a real quote" },
      { id: "c2", source: "s2", quote: "alternate key" },
    ]);
  });

  it("is empty for a summary with no citations at all", () => {
    expect(citationRequests({ findings: [] })).toEqual([]);
    expect(citationRequests(undefined)).toEqual([]);
  });
});

describe("normalizeSource", () => {
  it("lowercases and strips trailing slashes so one url is one document", () => {
    expect(normalizeSource("https://EX.test/A/")).toBe("https://ex.test/a");
    expect(normalizeSource("  https://ex.test/a//  ")).toBe("https://ex.test/a");
  });
});

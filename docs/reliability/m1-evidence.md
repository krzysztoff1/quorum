# M1: evidence on the subscription path

PRD 10 §1.6 and §7 (M1). P1's live run proved that a keyless Claude-subscription run captured no
evidence: grounding was `none`, the claim sweep was skipped, and the validators filed blocking
"no evidence was captured" objections, so every run ended `inconclusive`. This step makes every
subscription run capture snapshots with no API key.

Owner decision: the engine's own **direct** fetch only. No Jina Reader, no third-party reader, and
Tavily/Brave stay optional.

## What changed

**Hybrid tools on the `claude-code` backend** (`engine/src/claudeCode.ts`)
- Discovery: the CLI's built-in `WebSearch` when there is no search key, `mcp__quorum__web_search`
  when there is one.
- Reading: always `mcp__quorum__web_fetch`. The CLI's own `WebFetch` is never allowed, because
  nothing it reads can be snapshotted.
- The engine's MCP server is attached to every research call, and `spawn_inquiry` is offered whenever
  the run gave the angle a spawn directory (it used to need a search key).

**Direct fetch** (`engine/src/directFetch.ts`, replaces the Jina path in `SearchClient.fetch`)
- Plain HTTP with a `Quorum/0.1 (research assistant; …)` user agent, manual redirect following (5
  hops, http/https only), 20 s timeout, 20 MB cap checked on the declared length and while streaming.
- Extraction: `<article>`, then `<main>`, then `role="main"`, then the body minus
  nav/header/footer/aside/form chrome. Headings and list items are kept, paragraphs stay apart,
  entities are decoded, and the title is `og:title` or `<title>`.
- PDFs are detected by content type or `%PDF` magic and extracted page by page with `unpdf`. Pages
  are joined with form feeds, so `page_offsets` works. The original bytes are kept for the app's
  PDFKit highlight.
- `robots.txt` is fetched once per origin and honoured (agent group, `*` and `$` patterns, longest
  match wins). A missing or unreachable `robots.txt` allows the fetch.
- Politeness: requests to one host are serialized with a 750 ms gap, and the existing semaphore caps
  concurrency overall. 429 and 5xx are retried with backoff, honouring `Retry-After` up to 5 s.

**Every failure is explicit.** `FetchFailure` carries a kind, the tool tells the model what failed
and to try another source, and the failure is filed in the run's evidence directory
(`failures.jsonl`) as a `capture_failure` event plus an entry in `run_result.capture_failures`
(`stage: "fetch"`).

| Kind | When |
| --- | --- |
| `blocked` | 401, 403, 451 |
| `paywall` | 402, or a short page carrying "subscribe to continue" style text |
| `not_found` | 404, 410 |
| `http_error` | other 4xx, or 429/5xx after retries |
| `timeout`, `network` | aborted or unreachable |
| `too_large` | over the byte cap |
| `unsupported` | images, archives, other binaries, non-http schemes, unreadable PDFs |
| `js_only` | almost no text and a script shell |
| `empty` | almost no text and no script, or a PDF with no extractable text (a scan) |
| `robots` | disallowed by `robots.txt` |
| `redirects` | more than 5 hops |

**`web_fetch` offset parity.** The MCP tool now returns at most 12 000 characters per call with
`offset`, `total_chars` and `next_offset`, continuing through the same captured copy without
fetching again. This is the same behaviour as the BYOK tool.

**Grounding is a fetch-capability check.** `groundingTier(env, fetchesWithoutKey)`: a `claude-code`
angle model is `captured` with no key. A Codex or BYOK run without a search key is still `none`,
because its built-in search leaves nothing behind. `none` is now an incident rather than the default.

**Source type at capture.** Each document carries `source_type`: `primary`, `vendor`, `seo`,
`academic` or `news`. It is decided from host lists first (`.gov`, `.edu`, standards bodies and
official project sites, news organisations, content farms) and then URL and title patterns for
SEO (listicles, "best … in 2026", "vs", "alternatives"). Anything else falls back to `vendor`. It is
stored in `documents.jsonl` and sent in `document` events and `run_result.documents`, and
`EvidenceStore.sourceTypeCounts()` gives the "7 of 13 are vendor or SEO" numbers. Wikipedia and
Britannica are filed under `academic` because the five types have no "reference" bucket.

## Things the live run found along the way

- **`selfMcpCommand` was broken in a compiled binary.** `process.argv[1]` is a virtual
  `/$bunfs/root/…` path there, so the CLI was handed a bogus script argument and `mcp-serve` never
  started. The keyed path had the same bug and had never been exercised with a built binary. The
  first live run had no `web_fetch` tool at all, and the model searched 12 times and read nothing.
- **The claim verifier was cut off by its own 5-cent cap** after writing seven complete verdicts. The
  CLI returned no `result`, so every claim read as unjudged. The CLI backend now keeps the last
  assistant text when there is no result, and the sweep cap is 10 cents, matching the critics.
- **The sweep saw zero claims when the synthesis JSON was malformed** (Haiku left a quote
  unescaped), although the angles had located citations. The sweep now falls back to the run's
  located citations for footnote markers the synthesis kept.

## Live verification

One real run through the subscription CLI with the compiled binary: `quorum-engine run`,
`claude-code/claude-haiku-4-5` for every role, 1 angle, 1 round, spawning off, effort low, no
Tavily or Brave key in the environment. The question was "What is PEP 703 and what is the current
status of free-threaded (no-GIL) CPython?"

- **Time and cost:** 137 s, $0.146 total, of which $0.047 was validation.
- **Snapshots exist.** Three pages were read through the engine's `web_fetch` (PEP 703, the
  free-threading HOWTO, PEP 779), each with a snapshot under `evidence/sources/` and classified
  `primary`. No capture failures.
- **The claim sweep ran on them.** It found 4 claims, checked all 4 against located quotes, and
  returned 1 supported and 3 unsupported. The three critics also ran.
- **The run ended `inconclusive`, but not for missing evidence.** The 5 blocking objections are about
  substance: whether Python 3.14 has shipped, an unverified memory-overhead figure, and a claim cut
  off mid-sentence. This is the validator loop doing its job on a Haiku answer, and no objection says
  evidence is absent.

Earlier attempts in the same session, for the record: one run with `env -i` returned "Not logged
in" at $0, one before the `mcp-serve` fix read nothing ($0.39), and two reached the sweep but hit the
budget-cap and malformed-JSON problems above ($0.22, $0.20). About $0.96 in total across five runs.

## Not verified, and known limits

- **No JavaScript rendering.** A client-rendered page is reported as `js_only`, not read. The
  paywall and JS-shell detectors are heuristics and have only been tested on fixtures.
- **Politeness is per process.** Each angle's `mcp-serve` child has its own host-gap tracker, so two
  parallel angles can hit the same host at the same time. `robots.txt` is cached per process too.
- **PDF extraction was verified in the compiled binary on one arXiv paper and on synthetic PDFs
  only.** The live run did not read a PDF. Scanned PDFs return `empty`.
- **Source type is a heuristic.** Unknown commercial hosts default to `vendor`. No labelled set was
  used to measure its accuracy.
- **The Swift app ignores the new fields.** `source_type`, `capture_failure` events and the fetch
  stage are on the wire but not decoded or displayed. Swift decoding tolerates them, and
  `swift build` and `swift test` pass unchanged.
- **Codex.** Its keyless path still uses the built-in search and still ends `none`. Only the
  `claude-code` backend was moved to the hybrid.
- **BYOK pricing.** `fetch.jina` in the price table is now a misnomer, since Jina is gone, and the
  fee is still 0.
- **`Not logged in` still ends a run `complete`.** When the CLI cannot authenticate it prints "Not
  logged in · Please run /login" as an ordinary result, and the engine treats that as a finished
  answer with cost $0 (the first run showed it). It should be a hard failure. That is outside M1 and
  not fixed here.
- **`engine/dist`** must be rebuilt (`scripts/bundle-engine.sh`) for the app to pick this up.

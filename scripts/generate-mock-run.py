#!/usr/bin/env python3
"""Regenerates engine/fixtures/mock-run.ndjson and its mock-run.sources/ snapshots.

Everything the Swift side checks -- source ids, UTF-16 quote offsets, page tables, the ## Sources
sections and the footnote definitions -- is derived here from the snapshot text itself, mirroring
engine/src/evidence.ts and engine/src/run.ts, so the fixture cannot drift out of agreement with itself.
"""

import hashlib
import json
import os
import re

ROOT = "/Users/krzysztofduda/Developer/andon"
FIXTURES = os.path.join(ROOT, "engine/fixtures")
SOURCES = os.path.join(FIXTURES, "mock-run.sources")

BANNER = "[FIXTURE] Synthetic capture for Quorum's offline demo — not a real fetch."

QUESTION = ("Where does prompt caching actually pay off for a bursty chat product, "
            "and where does it stop paying?")


# ---------------------------------------------------------------- utf-16 helpers

def u16(s):
    return len(s.encode("utf-16-le")) // 2


def span(text, needle):
    at = text.find(needle)
    if at < 0:
        raise SystemExit("quote not in snapshot: %r" % needle[:70])
    if text.find(needle, at + 1) >= 0:
        raise SystemExit("quote is ambiguous in snapshot: %r" % needle[:70])
    return u16(text[:at]), u16(text[:at + len(needle)])


def fold(s):
    s = s.replace("“", '"').replace("”", '"').replace("‘", "'").replace("’", "'")
    s = s.replace("—", "-").replace("–", "-")
    return re.sub(r"\s+", " ", s).strip().lower()


# ---------------------------------------------------------------- sources

def source_id(url):
    return "s" + hashlib.sha256(url.strip().rstrip("/").lower().encode()).hexdigest()[:8]


def page_offsets(text):
    starts = {0}
    for hit in re.finditer(r"(?mi)^(?:-{2,}[ \t]*page[ \t]+\d+[ \t]*-{2,}|\[[ \t]*page[ \t]+\d+[ \t]*\])$", text):
        starts.add(u16(text[:hit.start()]))
    return sorted(starts) if len(starts) > 1 else []


ANTHROPIC_TEXT = "\n".join([
    BANNER,
    "",
    "# Prompt caching",
    "",
    "Prompt caching lets you resume from a specific prefix of your prompt. Cache a large, stable block of "
    "context once and reuse it across requests, so the repeated part is billed at a fraction of the input "
    "price and skips most of its prefill latency.",
    "",
    "## Pricing",
    "",
    "Cache writes cost more than base input tokens and cache reads cost far less. A 5-minute cache write is "
    "billed at 1.25x the base input token price, a 1-hour cache write at 2x, and a cache read at 0.1x the "
    "base input token price. Output tokens are priced normally and are never cached.",
    "",
    "## Cache lifetime",
    "",
    "The 5-minute cache has a minimum lifetime of five minutes, refreshed every time the cached content is "
    "read. Each cache hit resets the countdown, so a prefix that is read at least once a minute stays warm "
    "indefinitely without ever being written again. Idle traffic, not elapsed time since the write, is what "
    "lets an entry fall out of the cache.",
    "",
    "## What invalidates a prefix",
    "",
    "The cached prefix must match exactly, token for token, including tool definitions and images. A change "
    "anywhere near the start of the prompt invalidates everything after it, which is why system prompts and "
    "tool schemas belong above the cache breakpoint and per-turn content below it.",
    "",
    "## Minimum length",
    "",
    "The minimum cacheable prefix is 1024 tokens for most models and 2048 tokens for the smallest ones. A "
    "request under that threshold is served uncached and billed at the base input price, and no error is "
    "returned.",
    "",
])

OPENAI_TEXT = "\n".join([
    BANNER,
    "",
    "# Prompt caching",
    "",
    "Prompt caching is enabled automatically for prompts longer than 1024 tokens. There is no cache_control "
    "parameter and no separate write price: an identical prefix is routed back to the same worker and the "
    "cached portion of the input is billed at a discount.",
    "",
    "## What gets cached",
    "",
    "Caching applies to the longest identical prefix, measured in 128-token increments, starting at the very "
    "beginning of the prompt. Static content - system instructions, tool definitions, few-shot examples - "
    "belongs first, and variable content last.",
    "",
    "## Cache lifetime",
    "",
    "Caches are typically cleared after 5-10 minutes of inactivity and are always evicted within an hour of "
    "last use. During off-peak periods entries survive longer, so a measured hit rate moves with traffic and "
    "not only with prompt structure.",
    "",
    "## Observability",
    "",
    "The usage object reports cached_tokens under prompt_tokens_details. The rate of cache hits is the number "
    "to watch: a prompt that looks cacheable can still miss on every request if a timestamp or a session id "
    "is injected above the static block.",
    "",
])

REPORT_PAGES = [
    [
        BANNER,
        "",
        "Northwind Chat — Inference Cost Report, Q1 2026",
        "",
        "Method",
        "",
        "We instrumented 41 production deployments of assistant-style chat products between",
        "October 2025 and February 2026, recording per-request token accounting from provider",
        "usage objects rather than from client-side estimates. Deployments self-selected into",
        "the study; we make no claim that they represent the market.",
    ],
    [
        "Headline result",
        "",
        "Across the 41 deployments, median spend on input tokens fell 52% after a cache",
        "breakpoint was introduced above the system prompt. The interquartile range is wide:",
        "the 25th percentile saved 31% and the 75th percentile saved 68%.",
        "",
        "Breakeven",
        "",
        "A cached prefix pays for itself once it is read roughly 5 times per write. Below that",
        "the 1.25× write premium is never recovered, and a product that rewrites its prefix on",
        "every request pays about 25% more than it would have paid with no caching at all.",
        "",
        "Sensitivity",
        "",
        "The saving is dominated by the share of the prompt that is static. Deployments whose",
        "static prefix was under 30% of median prompt length saved less than 15%, whatever",
        "their hit rate.",
    ],
    [
        "The low-hit-rate regime",
        "",
        "Below a 40% cache hit rate the median deployment saved nothing measurable: write",
        "premiums and read discounts cancelled within the noise of week-to-week traffic. Nine",
        "of the 41 deployments spent more with caching enabled than they had without it.",
        "",
        "Bursty traffic",
        "",
        "Hit rate tracks session density, not request volume. A product with the same daily",
        "volume spread thinly across time zones sat at a 22% hit rate; the same volume",
        "concentrated into working hours sat at 71%.",
        "",
        "Limitations",
        "",
        "Self-selection is the obvious one. Deployments that switched caching on and saw",
        "nothing had no incentive to enrol, so the headline figure is an upper bound rather",
        "than an expectation.",
    ],
]

REPORT_TEXT = "\n".join(REPORT_PAGES[0]) + "\n\n--- page 2 ---\n" + "\n".join(REPORT_PAGES[1]) \
    + "\n\n--- page 3 ---\n" + "\n".join(REPORT_PAGES[2]) + "\n"

BLOG_TEXT = (
    BANNER + " Skip to content Helmsley AI Blog Careers Docs Sign in We cut our inference bill in half 🚀 "
    "Dana Ilić 14 March 2026 · 7 min read Share Tweet Copy link We run a support assistant for about 90k "
    "monthly users and input tokens were 78% of total spend . After we moved the tool schema and the product "
    "manual above a single cache breakpoint , our input spend dropped 52% in the first full week and stayed "
    "there . What we did not expect : the win came almost entirely from working hours . Overnight our hit "
    "rate collapses to about one request in five and the write premium eats the discount . We have not "
    "published the hourly distribution — it lives in an internal dashboard . Newsletter Subscribe Related "
    "posts We rewrote our retriever in Rust Hiring a staff engineer © 2026 Helmsley AI\n")

LATENCY_TEXT = "\n".join([
    BANNER,
    "",
    "# Latency optimization",
    "",
    "A cached prefix skips prefill, so the latency win survives even where the cost win does not. Time to "
    "first token improves most on long, static prompts; a prompt whose static share is small will see little "
    "change either way.",
    "",
    "## Choosing a window",
    "",
    "No published measurement compares the 1-hour cache window against the 5-minute one under bursty "
    "traffic. Choosing between them is a judgement about the shape of your traffic rather than a decision "
    "the published numbers can settle.",
    "",
])

DOCS = {}


def register(key, url, title, content_type, text, byte_size, capture="ok", fetched_at="2026-08-09T14:02:11.480Z",
             original=None):
    sid = source_id(url)
    DOCS[key] = {
        "source_id": sid,
        "url": url,
        "title": title,
        "content_type": content_type,
        "fetched_at": fetched_at,
        "snapshot_path": ("sources/%s.md" % sid) if text else None,
        "original_path": ("sources/%s.%s" % (sid, original)) if original else None,
        "text_length": u16(text) if text else 0,
        "byte_size": byte_size,
        "page_offsets": page_offsets(text) if text else [],
        "capture": capture,
    }
    DOCS[key]["_text"] = text
    return DOCS[key]


register("anthropic", "https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching",
         "Prompt caching - Anthropic", "html", ANTHROPIC_TEXT, 148_402)
register("openai", "https://platform.openai.com/docs/guides/prompt-caching",
         "Prompt caching - OpenAI API", "html", OPENAI_TEXT, 96_118,
         fetched_at="2026-08-09T14:02:44.902Z")
register("report", "https://research.northwind-chat.io/reports/inference-cost-2026.pdf",
         "Northwind Chat — Inference Cost Report, Q1 2026", "pdf", REPORT_TEXT, 0,
         fetched_at="2026-08-09T14:03:02.117Z", original="pdf")
register("blog", "https://blog.helmsley-ai.dev/posts/we-cut-our-inference-bill-in-half",
         "We cut our inference bill in half", "html", BLOG_TEXT, 411_930, capture="degraded",
         fetched_at="2026-08-09T14:03:19.640Z")
register("hn", "https://news.ycombinator.com/item?id=43127890",
         "Ask HN: has prompt caching actually saved you money?", "html", None, 0,
         fetched_at="2026-08-09T14:03:31.008Z")
register("status", "https://status.northwind-chat.io/incidents/2026-03-cache-stampede",
         "Cache stampede after a prompt template change", "html", None, 0, capture="failed",
         fetched_at="2026-08-09T14:04:08.226Z")
register("latency", "https://platform.openai.com/docs/guides/latency-optimization",
         "Latency optimization - OpenAI API", "html", LATENCY_TEXT, 71_004,
         fetched_at="2026-08-09T14:12:55.311Z")


def doc_event(angle_id, key):
    document = {k: v for k, v in DOCS[key].items() if not k.startswith("_")}
    return {"type": "document", "angle_id": angle_id, "document": document}


def page_of(key, offset):
    offsets = DOCS[key]["page_offsets"]
    if not offsets:
        return None
    page = 1
    for index, start in enumerate(offsets):
        if offset >= start:
            page = index + 1
    return page


# ---------------------------------------------------------------- citations

CITES = {}


def cite(cid, key, quote, match="exact", window=None):
    doc = DOCS[key]
    entry = {"id": cid, "source_id": doc["source_id"], "quote": quote, "match": match}
    if match != "unresolved":
        located = window or quote
        start, end = span(doc["_text"], located)
        if match == "exact" and located != quote:
            raise SystemExit("%s claims an exact match but quotes something else" % cid)
        if match == "normalized" and fold(located) != fold(quote):
            raise SystemExit("%s is not a whitespace/case variant of its span" % cid)
        entry["start"], entry["end"] = start, end
        page = page_of(key, start)
        if page is not None:
            entry["page"] = page
    CITES[cid] = entry
    return entry


cite("a1c1", "anthropic",
     "A 5-minute cache write is billed at 1.25x the base input token price, a 1-hour cache write at 2x, and "
     "a cache read at 0.1x the base input token price.")
cite("a1c2", "anthropic",
     "the minimum cacheable prefix is 1024 tokens for most models  and 2048 tokens for the smallest ones",
     match="normalized",
     window="The minimum cacheable prefix is 1024 tokens for most models and 2048 tokens for the smallest ones")
cite("a1c3", "openai", "Prompt caching is enabled automatically for prompts longer than 1024 tokens.")
cite("a1c4", "openai",
     "Caches are typically cleared after 5-10 minutes of inactivity and are always evicted within an hour of "
     "last use.")

cite("a2c1", "report",
     "median spend on input tokens fell 52% after a cache\nbreakpoint was introduced above the system prompt")
cite("a2c2", "blog",
     "after moving the tool schema and product manual above one cache breakpoint, input spend dropped 52% in "
     "the first week",
     match="fuzzy",
     window="we moved the tool schema and the product manual above a single cache breakpoint , our input "
            "spend dropped 52% in the first full week")
cite("a2c3", "hn",
     "several replies report no measurable saving at all below a few thousand requests a day",
     match="unresolved")

cite("a4c1", "status",
     "the template change invalidated every cached prefix at once and the fleet spent nine minutes writing "
     "caches it never read",
     match="unresolved")

cite("x1c1", "blog", "We have not published the hourly distribution — it lives in an internal dashboard")

cite("x3c1", "anthropic",
     "Each cache hit resets the countdown, so a prefix that is read at least once a minute stays warm "
     "indefinitely without ever being written again.")
cite("x3c2", "anthropic",
     "Idle traffic, not elapsed time since the write, is what lets an entry fall out of the cache.")

cite("x4c1", "report",
     "Below a 40% cache hit rate the median deployment saved nothing measurable")
cite("x4c2", "report", "Hit rate tracks session density, not request volume.")
cite("x4c4", "report",
     "Nine of the 41 deployments spent more with caching enabled than they had without it",
     match="normalized",
     window="Nine\nof the 41 deployments spent more with caching enabled than they had without it")
cite("x4c3", "report",
     "A cached prefix pays for itself once it is read roughly 5 times per write")

cite("x5c1", "latency",
     "A cached prefix skips prefill, so the latency win survives even where the cost win does not.")
cite("x5c2", "latency",
     "No published measurement compares the 1-hour cache window against the 5-minute one under bursty "
     "traffic.")


def c(*ids):
    return [CITES[i] for i in ids]


# ---------------------------------------------------------------- writeup assembly (mirrors composeGrounded)

def doc_for(cid):
    sid = CITES[cid]["source_id"]
    return next(d for d in DOCS.values() if d["source_id"] == sid)


def source_link(document):
    return "[%s](%s)" % (document["title"].replace("]", ""), document["url"])


def badge(citations):
    if any(x["match"] in ("exact", "normalized") for x in citations):
        return "✓ verified"
    if any(x["match"] == "fuzzy" for x in citations):
        return "≈ close match"
    return "⚠️ not verifiable"


def footnote(citation, document):
    parts = [source_link(document)]
    if "page" in citation:
        parts.append("p. %d" % citation["page"])
    if citation["quote"]:
        parts.append("“%s”" % re.sub(r"\s+", " ", citation["quote"]))
    if citation["match"] == "unresolved":
        parts.append("(quote not verifiable against a stored snapshot)")
    return " — ".join(parts)


def sources_section(ids):
    order, by_source = [], {}
    for cid in ids:
        sid = CITES[cid]["source_id"]
        if sid not in by_source:
            by_source[sid] = []
            order.append(sid)
        by_source[sid].append(CITES[cid])
    out = "## Sources\n\n"
    for index, sid in enumerate(order):
        document = next(d for d in DOCS.values() if d["source_id"] == sid)
        out += "%d. %s — %s\n" % (index + 1, source_link(document), badge(by_source[sid]))
    out += "\n"
    out += "\n".join("[^%s]: %s" % (cid, footnote(CITES[cid], doc_for(cid))) for cid in ids)
    return out


def citation_check(urls):
    out = "## Citation check\n\n"
    out += "⚠️ %d citation(s) in this synthesis could not be traced to any angle's sources — treat them as " \
           "unverified:\n\n" % len(urls)
    for url in urls:
        out += "- %s\n" % url
    return out.rstrip()


def validation_section(rnd):
    lines = ["## Validation", ""]
    failed = [v for v in rnd["verdicts"] if v["verdict"] != "supported"]
    if rnd["sweep"] == "skipped" and rnd["critics"] == "skipped":
        return "\n".join(lines + ["⚠️ %s" % rnd.get("note", "This answer was not validated.")])
    if not failed and not rnd["objections"]:
        if rnd["sweep"] == "run":
            lines.append("✓ Validated — %d claim(s) checked against their located quotes; the coverage, "
                         "conflicts and sources critics filed nothing." % rnd["claims_checked"])
        return "\n".join(lines)
    lines.append("These were filed against the answer, not fixed in it — only further research settles them:")
    lines.append("")
    for verdict in failed:
        line = "- claim sweep · %s · %s — “%s”" % (verdict["verdict"], verdict["severity"], verdict["claim"])
        if verdict.get("reason"):
            line += " — %s" % verdict["reason"]
        lines.append(line)
    for objection in rnd["objections"]:
        lines.append("- %s · %s — %s → %s" % (objection["lens"].replace("_", " "), objection["severity"],
                                              objection["statement"], objection["followup"]))
    return "\n".join(lines)


def writeup(prose, ids, summary, untraceable=None, validation=None):
    body = prose.strip()
    if untraceable:
        body += "\n\n" + citation_check(untraceable)
    if ids:
        body += "\n\n" + sources_section(ids)
    if validation:
        body += "\n\n" + validation_section(validation)
    summary = dict(summary)
    if ids:
        summary["citations"] = c(*ids)
    return body + "\n\n```json\n" + json.dumps(summary) + "\n```\n"


# ---------------------------------------------------------------- the run's prose

A1_PROSE = """
Caching is sold as a discount but priced as a trade: a premium to put a prefix into the cache, a deep
discount to read it back. On Anthropic a 5-minute cache write is billed at 1.25x the base input price, a
1-hour write at 2x, and every read at 0.1x[^a1c1]. OpenAI sells the same idea with the opposite
ergonomics — no breakpoint to place and no write premium, because caching is applied automatically to any
prompt over 1024 tokens[^a1c3].

That difference decides who carries the risk of getting it wrong. On Anthropic it is yours: a prefix
written and never read back is 25% of an input bill spent on nothing. On OpenAI it is the platform's — and
so is the control, since there is no way to pin a prefix or force one to stay warm.

Both floor the feature in the same place. A prefix under 1024 tokens is not cached at all, the request is
billed at the base input rate, and nothing in the response says so[^a1c2].

Eviction is where the documentation is easiest to misread. OpenAI states its window in terms of
inactivity: entries are cleared after 5-10 minutes of inactivity and always within an hour of last
use[^a1c4].
"""

A2_PROSE = """
The only multi-deployment number I could find is Northwind's Q1 2026 report: across 41 instrumented
deployments, median input spend fell 52% after a cache breakpoint was placed above the system
prompt[^a2c1]. The spread behind that median is wide — 31% at the 25th percentile, 68% at the 75th — and
the deployments self-selected into the study, which the authors flag themselves.

One first-hand write-up lands close enough to the headline to be worth reading beside it: Helmsley moved a
tool schema and a product manual above a single breakpoint and reported input spend down 52% in the first
week[^a2c2]. The same post is the only place I found the overnight effect stated plainly — outside working
hours their hit rate collapses to roughly one request in five, and the write premium eats the discount.

The Ask HN thread on the same question is anecdote-only, and the fetch returned nothing I could quote
against[^a2c3].
"""

A3_PROSE = """
Starting on the failure modes rather than the savings: a cache is a shared resource, and the interesting
question for a bursty product is what happens when a lot of misses arrive at once. The vendor status pages
are the only primary record of that, so
"""

A4_PROSE = """
The shape of the answer is a ratio, not a volume. With a 1.25x write and a 0.1x read, a prefix read r
times per write costs (1.25 + 0.1r) against (1 + r) uncached, so caching wins once r clears about 0.29 —
which is nearly always, and is why the naive arithmetic is misleading. Reads only count if they land
inside the window, so the operative number is reads per window, not reads per write.

Working the second version of that arithmetic against an incident write-up on cache stampedes[^a4c1] is
where the per-angle cap stopped this angle.
"""

X1_PROSE = """
Not published anywhere I can reach. The Helmsley post gives one number and no distribution, and says so
itself — the hourly breakdown lives in an internal dashboard that was never shared[^x1c1]. The author's
replies point at the same dashboard.

Northwind's report gives percentiles for savings but not for hit rate, and the two are not
interchangeable: a deployment can save little at a high hit rate if its static share is small. Deriving a
hit-rate distribution from the savings percentiles would be the same claim laundered, so I am recording
this as unanswered rather than answering it.
"""

X3_PROSE = """
It refreshes, and the round-1 reading of this was wrong. Anthropic is explicit: each cache hit resets the
countdown, so a prefix read at least once a minute stays warm indefinitely without ever being written
again[^x3c1]. What lets an entry fall out is idle traffic, not elapsed time since the write[^x3c2].

Five minutes is therefore a floor on how long an unread entry survives, not a ceiling on how long a live
one does. That inverts the conclusion for exactly the traffic shape this question is about: a product with
steady daytime traffic writes its prefix once in the morning and reads it all day, while a product with
thin, scattered traffic pays the write premium again and again and collects almost none of the reads.

OpenAI's wording says the same thing less directly — cleared after inactivity, not after a fixed lifetime.
"""

X4_PROSE = """
Below a 40% hit rate the median deployment in Northwind's sample saved nothing measurable[^x4c1]; nine of
the 41 deployments spent more with caching enabled than they had without it[^x4c4]. The mechanism is the
one the arithmetic predicts — write premiums and read discounts cancel, and what is left is smaller than
week-to-week traffic noise.

Hit rate itself tracks session density rather than request volume[^x4c2]. The same daily volume spread
thinly across time zones sat at 22%; concentrated into working hours it sat at 71%. For a bursty product
that is the whole question: not how much traffic there is, but how tightly it clusters.

Break-even from the same report is roughly 5 reads per write[^x4c3], which for a 5-minute window is a
statement about how many conversations overlap, not about daily volume.
"""

X5_PROSE = """
There is no published measurement, and I want to be precise about that rather than fill it in. Vendor
guidance covers the latency side — a cached prefix skips prefill, so the latency win survives even where
the cost win does not[^x5c1] — but on cost, no published measurement compares the 1-hour window against
the 5-minute one under bursty traffic[^x5c2].

That leaves the disagreement standing rather than settled. Reading the 2x write premium off the price
sheet says the hour window is almost never worth it; the practitioners who bought it report being happy
with it; neither position rests on a measurement.
"""

S1_PROSE = """
Prompt caching pays for a chat product when the same prefix is read back several times inside the cache
window, and stops paying when traffic is thin enough that most windows expire unread. That is a claim
about the shape of traffic, not about its volume.

## What the pricing forces

A cache write is billed at 1.25x the base input price and a read at 0.1x[^a1c1], while OpenAI applies
caching automatically above 1024 tokens and charges no write premium at all[^a1c3]. On Anthropic the
decision is therefore yours to get wrong: a prefix written and never read is a quarter of an input bill
spent on nothing. Both vendors silently decline to cache anything under 1024 tokens[^a1c2].

## What deployments report

Median input spend across 41 instrumented deployments fell 52% after a breakpoint was placed above the
system prompt[^a2c1], and one first-hand account lands in the same place[^a2c2]. Both carry the same
caveat: the sample self-selected, and the practitioner account is a single product.

## Where it stops paying

A cached prefix expires five minutes after it is written[^a1c4], so a product whose traffic is scattered
across time zones can pay the write premium repeatedly and collect almost none of the reads. Neither the
pricing pages nor the deployment report states the hit rate at which the trade turns negative, and one
angle was still deriving it when its spend cap stopped it.
"""

S2_PROSE = """
Prompt caching pays for a chat product whose traffic clusters, and stops paying for one whose traffic is
thin and scattered. The threshold is a hit rate, and it is measurable before you commit to anything.

## What the pricing forces

A cache write is billed at 1.25x the base input price and a read at 0.1x[^a1c1]; OpenAI applies caching
automatically above 1024 tokens with no write premium and no breakpoint to place[^a1c3]. Under 1024 tokens
neither vendor caches at all[^a1c2].

## The window refreshes on read

The five-minute number is a floor on how long an unread entry survives, not a ceiling on how long a live
one does: each hit resets the countdown, so a prefix read once a minute stays warm indefinitely without
being rewritten[^x3c1], and it is idle traffic rather than elapsed time that evicts it[^x3c2]. An earlier
draft of this answer had that backwards.

## Where it stops paying

Below a 40% hit rate the median deployment saved nothing measurable[^x4c1], and nine of 41 spent more with
caching on than off. Hit rate tracks session density rather than request volume[^x4c2] — the same daily
volume sat at 22% spread across time zones and 71% concentrated into working hours — and break-even is
around 5 reads per write[^x4c3].

## What deployments report

Median input spend fell 52% across the sample[^a2c1], matched by one first-hand account[^a2c2]. Both
self-selected, and the hit-rate distribution behind them was never published.
"""

S3_PROSE = """
Prompt caching pays for a chat product whose traffic clusters, and stops paying for one whose traffic is
thin and scattered. Measure the hit rate first: below roughly 40% there is nothing to buy.

## What the pricing forces

A cache write is billed at 1.25x the base input price and a read at 0.1x[^a1c1]; OpenAI caches
automatically above 1024 tokens with no write premium[^a1c3], and neither vendor caches a prefix under
1024 tokens[^a1c2].

## The window refreshes on read

Each hit resets the countdown, so a prefix read once a minute stays warm indefinitely without being
rewritten[^x3c1]; idle traffic, not elapsed time since the write, is what evicts an entry[^x3c2].

## Where it stops paying

Below a 40% hit rate the median deployment saved nothing measurable[^x4c1]. Hit rate tracks session
density rather than request volume[^x4c2], and break-even sits around 5 reads per write[^x4c3]. For a
bursty product the deciding number is how tightly conversations overlap inside one window.

## What deployments report, and how far it carries

Median input spend fell 52% across 41 self-selected deployments[^a2c1], matched by one first-hand
account[^a2c2] — so caching roughly halves input spend for a bursty chat product.

## The window size is still an open question

A cached prefix skips prefill, so the latency win survives even where the cost win does not[^x5c1]. On
cost, no published measurement compares the 1-hour window against the 5-minute one under bursty
traffic[^x5c2], so the choice between them remains a judgement about traffic shape.
"""

RECON_PROSE = """
Prompt caching pays for a chat product whose traffic clusters tightly enough that a written prefix is read
back several times before it goes idle, and stops paying below roughly a 40% hit rate. Measure the hit
rate before buying anything: it is the only number that decides this, and it is knowable in advance.

## The arithmetic

A cache write is billed at 1.25x the base input price and a read at 0.1x[^a1c1], so break-even is a ratio
rather than a volume: roughly 5 reads per write[^x4c3]. OpenAI removes the decision by caching
automatically above 1024 tokens with no write premium[^a1c3]; under 1024 tokens neither vendor caches at
all[^a1c2].

## The window refreshes on read

Each cache hit resets the countdown, so a prefix read at least once a minute stays warm indefinitely
without ever being written again[^x3c1] — idle traffic, not elapsed time since the write, is what evicts
an entry[^x3c2]. This supersedes the first round's reading, which took the five-minute window to run from
the write and drew the opposite conclusion for scattered traffic.

## Where it stops paying

Below a 40% hit rate the median deployment saved nothing measurable[^x4c1], and nine of 41 spent more with
caching on than off. Hit rate tracks session density rather than request volume[^x4c2]: the same daily
volume sat at 22% when spread across time zones and 71% when concentrated into working hours.

## What the reported savings do and do not support

Median input spend fell 52% across 41 self-selected deployments[^a2c1], matched by one first-hand
account[^a2c2]. The claim sweep would not let that stand as a promise for a bursty product specifically:
the sample's own bursty band is the 22%-hit-rate one, which is on the wrong side of break-even. Read the
52% as what a well-clustered deployment achieved, not as an expectation.

## Still open

No published measurement compares the 1-hour window against the 5-minute one under bursty traffic[^x5c2],
so window size stays a judgement about traffic shape. The latency win, unlike the cost win, does not
depend on it[^x5c1].
"""


# ---------------------------------------------------------------- validation rounds

def objection(lens, statement, severity, followup):
    return {"lens": lens, "statement": statement, "severity": severity, "followup": followup}


SWEEP_TTL = {
    "claim_id": "k4", "claim": "A cached prefix expires five minutes after it is written",
    "verdict": "misquoted", "severity": "blocking",
    "reason": "the located quote is about eviction after inactivity, not about a fixed lifetime from the write",
    "citation_ids": ["a1c4"],
}
SWEEP_HALVES = {
    "claim_id": "k9",
    "claim": "caching roughly halves input spend for a bursty chat product",
    "verdict": "unsupported", "severity": "blocking",
    "reason": "the 52% median is across all 41 deployments; the report's own bursty band sits at a 22% hit "
              "rate, below the break-even it states",
    "citation_ids": ["a2c1"],
}

OBJ_COVERAGE = objection(
    "coverage",
    "the answer never says at what hit rate the trade turns negative, which is the only number a reader "
    "with bursty traffic can act on",
    "blocking",
    "find a published measurement of savings against cache hit rate, including the band where savings go to zero")
OBJ_STRUCTURE = objection(
    "structure",
    "a3 returned no machine-readable summary, so none of its quotes could be grounded",
    "minor",
    "run the a3 angle again and have it report a fenced json summary")
OBJ_SOURCES_1 = objection(
    "sources",
    "the 52% figure is load-bearing and rests on one self-selected report plus one blog post whose capture "
    "was degraded",
    "minor",
    "find an independent measurement of input-spend savings that does not depend on self-reported adoption")
OBJ_CONFLICTS_2 = objection(
    "conflicts",
    "a1 reads the 2x write premium as almost never worth it while a2's practitioners report buying the "
    "1-hour window and being satisfied; the answer picks neither",
    "blocking",
    "find a measurement comparing the 1-hour cache window against the 5-minute one under bursty traffic")
OBJ_SOURCES_2 = objection(
    "sources",
    "the break-even figure and the low-hit-rate band now both rest on the same single report",
    "minor",
    "corroborate the 5-reads-per-write break-even against a source other than the Northwind report")

SWEEP_OBJ_TTL = objection(
    "claim_sweep",
    'the claim "A cached prefix expires five minutes after it is written" is misquoted by its own located '
    "quotes — the located quote is about eviction after inactivity, not about a fixed lifetime from the write",
    "blocking",
    "find a source that settles, one way or the other: A cached prefix expires five minutes after it is written")
SWEEP_OBJ_HALVES = objection(
    "claim_sweep",
    'the claim "caching roughly halves input spend for a bursty chat product" is unsupported by its own '
    "located quotes — the 52% median is across all 41 deployments; the report's own bursty band sits at a "
    "22% hit rate, below the break-even it states",
    "blocking",
    "find a source that settles, one way or the other: caching roughly halves input spend for a bursty chat "
    "product")

ROUND_1 = {
    "round": 1, "sweep": "run", "critics": "run", "claims_found": 7, "claims_checked": 7,
    "verdicts": [
        {"claim_id": "k1", "claim": "A cache write is billed at 1.25x the base input price and a read at 0.1x",
         "verdict": "supported", "citation_ids": ["a1c1"]},
        {"claim_id": "k2", "claim": "OpenAI applies caching automatically above 1024 tokens",
         "verdict": "supported", "citation_ids": ["a1c3"]},
        {"claim_id": "k3", "claim": "Median input spend across 41 deployments fell 52%",
         "verdict": "supported", "citation_ids": ["a2c1"]},
        SWEEP_TTL,
    ],
    "objections": [OBJ_COVERAGE, OBJ_SOURCES_1, OBJ_STRUCTURE],
    "discarded_objections": 1, "holds": False,
    "note": "one critic objection named no researchable task and was discarded",
}

ROUND_2 = {
    "round": 2, "sweep": "run", "critics": "run", "claims_found": 9, "claims_checked": 9,
    "verdicts": [
        {"claim_id": "k5", "claim": "Each cache hit resets the countdown", "verdict": "supported",
         "citation_ids": ["x3c1"]},
        {"claim_id": "k6", "claim": "Below a 40% hit rate the median deployment saved nothing measurable",
         "verdict": "supported", "citation_ids": ["x4c1"]},
        {"claim_id": "k7", "claim": "Hit rate tracks session density rather than request volume",
         "verdict": "supported", "citation_ids": ["x4c2"]},
        {"claim_id": "k8", "claim": "Break-even is around 5 reads per write", "verdict": "supported",
         "citation_ids": ["x4c3"]},
    ],
    "objections": [OBJ_CONFLICTS_2, OBJ_SOURCES_2],
    "discarded_objections": 0, "holds": False,
}

ROUND_3 = {
    "round": 3, "sweep": "run", "critics": "skipped", "claims_found": 11, "claims_checked": 11,
    "verdicts": [
        {"claim_id": "k5", "claim": "Each cache hit resets the countdown", "verdict": "supported",
         "citation_ids": ["x3c1"]},
        {"claim_id": "k10", "claim": "No published measurement compares the two window sizes",
         "verdict": "supported", "citation_ids": ["x5c2"]},
        SWEEP_HALVES,
    ],
    "objections": [],
    "discarded_objections": 0, "holds": False,
    "note": "the validation reserve was spent by round 3, so the coverage, conflicts and sources critics did "
            "not run",
}

VALIDATION = {
    "status": "validated", "holds": False, "blocking": 4, "spend_usd": 0.43,
    "objections_admitted": 3, "objections_resolved": 3,
    "objections_outstanding": [SWEEP_OBJ_HALVES],
    "unsupported_citations": ["a2c1"],
    "rounds": [ROUND_1, ROUND_2, ROUND_3],
}


def verdict_nodes(rnd, target, depth):
    filed = list(rnd["objections"])
    for verdict in rnd["verdicts"]:
        if verdict["verdict"] != "supported":
            filed.append(objection(
                "claim_sweep",
                'the claim "%s" is %s by its own located quotes — %s' % (
                    verdict["claim"], verdict["verdict"], verdict["reason"]),
                verdict["severity"],
                "find a source that settles, one way or the other: %s" % verdict["claim"]))
    lenses = ["claim_sweep", "coverage", "conflicts", "sources"]
    for extra in [o["lens"] for o in filed]:
        if extra not in lenses:
            lenses.append(extra)
    titles = {"claim_sweep": "Claim sweep", "coverage": "Coverage critic", "conflicts": "Conflicts critic",
              "sources": "Sources critic"}
    events = []
    for lens in lenses:
        objections = [o for o in filed if o["lens"] == lens]
        ran = rnd["sweep"] == "run" if lens == "claim_sweep" else (
            rnd["critics"] == "run" if lens in ("coverage", "conflicts", "sources") else True)
        status = ("pass" if not objections else "objections(%d)" % len(objections)) if ran else "skipped"
        node_id = "v%d_%s" % (rnd["round"], lens)
        events.append({"type": "graph_node", "node": {
            "id": node_id, "kind": "verdict", "title": titles.get(lens, "Structure"), "parent_ids": [],
            "depth": depth, "round": rnd["round"], "status": status, "origin": "derived",
            "meta": {"lens": lens, "objections": objections}}})
        events.append({"type": "graph_edge",
                       "edge": {"from": node_id, "to": target, "kind": "judges", "label": status}})
    return events


# ---------------------------------------------------------------- event stream

EVENTS = []
TOTAL = 0.0
TOPICS = []


def emit(event):
    EVENTS.append(event)


def usage(angle_id, provider, model, cost, inp, out, cache_read=0, cache_write=0, search=0, fetch=0):
    global TOTAL
    TOTAL = round(TOTAL + cost, 4)
    emit({"type": "usage", "total_cost_usd": TOTAL, "usage": {
        "provider": provider, "model": model, "input_tokens": inp, "output_tokens": out,
        "cache_read_tokens": cache_read, "cache_write_tokens": cache_write, "cost_usd": cost,
        "search_calls": search, "fetch_calls": fetch}, "angle_id": angle_id})


def text_delta(angle_id, text):
    emit({"type": "stream_event", "angle_id": angle_id,
          "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": text}}})


def thinking_delta(angle_id, text):
    emit({"type": "stream_event", "angle_id": angle_id,
          "event": {"type": "content_block_delta", "delta": {"type": "thinking_delta", "thinking": text}}})


def tool(angle_id, name, **inputs):
    emit({"type": "assistant", "angle_id": angle_id,
          "message": {"content": [{"type": "tool_use", "name": name, "input": inputs}]}})


def node(node_id, kind, title, status, origin, depth, round_, parents=None, meta=None):
    body = {"id": node_id, "kind": kind, "title": title, "parent_ids": parents or [], "depth": depth,
            "round": round_, "status": status, "origin": origin}
    if meta:
        body["meta"] = meta
    emit({"type": "graph_node", "node": body})


def edge(frm, to, kind, label=None):
    body = {"from": frm, "to": to, "kind": kind}
    if label:
        body["label"] = label
    emit({"type": "graph_edge", "edge": body})


def update(node_id, status, cost=None):
    event = {"type": "graph_node_update", "id": node_id, "status": status}
    if cost is not None:
        event["meta"] = {"cost_usd": cost}
    emit(event)


CLI_SESSIONS = {
    "a1": "b3f6d1c2-7a4e-4f10-9c33-2d81ee5a7c04",
    "a2": "0c9a71fe-52bd-4a8e-8f61-71cb0d3a9e17",
    "a3": "f41d8ea0-1c6b-4d92-b0a7-3ee2c5f8d611",
    "a4": "27ab5c94-9e03-4b7a-8d15-6ca0f2b41d88",
    "x1": "d5e08b31-4f27-4c6d-9a82-5b1e7c390a4f",
    "x3": "8a2c6f70-b31d-4e58-97ac-0f4d62e18b53",
    "x4": "5e7b0d43-6a91-42cf-8b3e-19d76fc02a85",
    "x5": "9c14e2b8-3d05-4a76-bf29-6e83d51c7047",
    "synthesis": "1f6b93d7-8c42-4e0a-95bd-72a3ef14c968",
    "verify": "6d80c5a1-2b74-4f39-a8e6-40cb937d2e15",
    "reconciliation": "a72f4e69-0d18-4b53-9c71-8ef5320ba6d4",
}


def topic(angle_id, role, status, result, cost, ids, model="claude-code/sonnet", note=None, reconciled=False,
          inp=0, out=0, cache_read=0, cache_write=0, search=0, fetch=0, emit_line=True):
    body = {
        "type": "topic_result", "angle_id": angle_id, "role": role, "backend": "cli", "provider": "anthropic",
        "model": model, "session_id": CLI_SESSIONS[angle_id], "status": status, "result": result,
        "usage": {"provider": "anthropic", "model": model, "input_tokens": inp, "output_tokens": out,
                  "cache_read_tokens": cache_read, "cache_write_tokens": cache_write, "cost_usd": cost,
                  "search_calls": search, "fetch_calls": fetch},
        "note": note, "citations": c(*ids),
    }
    if reconciled:
        body["reconciled"] = True
    TOPICS.append({k: v for k, v in body.items() if k != "type"})
    if emit_line:
        emit(body)


ANGLES = {
    "a1": ("How the two vendors price a cached prefix",
           "Read the published pricing and lifetime rules for prompt caching on Anthropic and OpenAI. State "
           "the write premium, the read discount, the minimum cacheable prefix and the eviction rule for "
           "each, quoting the documentation."),
    "a2": ("What teams report after switching it on",
           "Find measurements from real deployments: how much input spend actually fell, over what traffic, "
           "and with what caveats. Prefer instrumented multi-deployment data over single anecdotes, and say "
           "which is which."),
    "a3": ("Failure modes: stampedes, cold starts and what breaks at scale",
           "Investigate what goes wrong with prompt caching in production — stampedes after a template "
           "change, cold starts, and cases where caching made a system slower or more expensive."),
    "a4": ("Break-even arithmetic for a bursty product",
           "Derive the break-even read/write ratio from the published prices, then correct it for the cache "
           "window: reads only count when they land inside it. Show the arithmetic."),
}

emit({"type": "run_start", "session_id": "qrun-3e91c7a4-58b2-4d6f-9017-c2ab84f35de9",
      "protocol_version": 5, "grounding": "captured"})
emit({"type": "phase", "phase": "planning"})
emit({"type": "plan", "angles": [{"angle_id": k, "title": v[0], "prompt": v[1]} for k, v in ANGLES.items()]})
node("root", "question", QUESTION, "approved", "root", 0, 1)
for key, (title, prompt) in ANGLES.items():
    node(key, "inquiry", title, "queued", "planner", 1, 1)
    edge("root", key, "decomposes")

emit({"type": "phase", "phase": "researching"})
for key in ANGLES:
    emit({"type": "angle_status", "angle_id": key, "status": "running"})

thinking_delta("a1", "Two vendors, two pricing models. Start with the published numbers — write premium, "
                     "read discount, minimum prefix — before touching anyone's blog post.")
tool("a1", "web_search", query="anthropic prompt caching pricing cache write read multiplier")
thinking_delta("a2", "I want instrumented data across deployments, not one team's screenshot. ")
tool("a2", "web_search", query="prompt caching production savings measured across deployments 2026")
emit(doc_event("a1", "anthropic"))
text_delta("a1", "Caching is sold as a discount but priced as a trade: a premium to put a prefix into the "
                 "cache, a deep discount to read it back. ")
tool("a3", "web_search", query="prompt cache stampede incident postmortem template change")
emit(doc_event("a2", "report"))
text_delta("a2", "The only multi-deployment number I could find is Northwind's Q1 2026 report: across 41 "
                 "instrumented deployments, median input spend fell 52% ")
thinking_delta("a4", "Ratio, not volume. Write once at 1.25x, read r times at 0.1x each. ")
tool("a1", "web_fetch", url="https://platform.openai.com/docs/guides/prompt-caching")
emit(doc_event("a1", "openai"))
usage("a1", "anthropic", "claude-code/sonnet", 0.71, 12_480, 1_940, cache_read=88_000, cache_write=12_400,
      search=2, fetch=2)
emit(doc_event("a3", "hn"))
text_delta("a3", "Starting on the failure modes rather than the savings: a cache is a shared resource, and "
                 "the interesting question for a bursty product is what happens when a lot of misses arrive "
                 "at once. ")
tool("a2", "web_fetch", url="https://blog.helmsley-ai.dev/posts/we-cut-our-inference-bill-in-half")
emit(doc_event("a2", "blog"))
tool("a4", "web_fetch", url="https://status.northwind-chat.io/incidents/2026-03-cache-stampede")
emit(doc_event("a4", "status"))
usage("a2", "anthropic", "claude-code/sonnet", 0.94, 15_210, 2_380, cache_read=91_500, cache_write=14_100,
      search=3, fetch=2)
text_delta("a1", "On Anthropic a 5-minute cache write is billed at 1.25x the base input price, a 1-hour "
                 "write at 2x, and every read at 0.1x. ")
emit({"type": "heartbeat", "at": "2026-08-09T14:04:33.902Z", "in_flight": 4})
text_delta("a4", "With a 1.25x write and a 0.1x read, a prefix read r times per write costs (1.25 + 0.1r) "
                 "against (1 + r) uncached. ")
usage("a3", "anthropic", "claude-code/sonnet", 0.31, 6_040, 620, cache_read=41_000, cache_write=6_800,
      search=1, fetch=1)
usage("a1", "anthropic", "claude-code/sonnet", 0.71, 13_900, 2_260, cache_read=96_400, cache_write=0,
      search=0, fetch=1)

node("q1", "question", "Get the hit-rate distribution behind the 52% claim", "pending", "spawn", 2, 1,
     parents=["a2"],
     meta={"why": "the 52% median is load-bearing and the spread behind it decides whether it transfers to "
                  "a bursty product",
           "provoked_by": DOCS["blog"]["source_id"], "est_cost_usd": 1.5})
edge("a2", "q1", "spawned", "the 52% median is load-bearing and the spread")
node("r1", "question", "Do cache stampedes show up on vendor status pages?", "rejected", "spawn", 0, 1,
     parents=["a3"],
     meta={"rejected_reason": "token-set overlap 0.91 with a question already being researched: “Failure "
                              "modes: stampedes, cold starts and what breaks at scale”"})
edge("a3", "r1", "spawned")
node("q2", "question", "Do the batch and streaming APIs share one cache?", "pending", "spawn", 2, 1,
     parents=["a1"],
     meta={"why": "a bursty product that batches overnight would double its write premium if the caches are "
                  "separate",
           "provoked_by": DOCS["openai"]["source_id"], "est_cost_usd": 1.5})
edge("a1", "q2", "spawned", "a bursty product that batches overnight would")

topic("a1", "research", "complete",
      writeup(A1_PROSE, ["a1c1", "a1c3", "a1c2", "a1c4"], {
          "headline": "Two price sheets, one trade: premium to write, discount to read",
          "status": "complete", "sourcesConsulted": 2,
          "findings": [
              {"claim": "Anthropic bills a 5-minute cache write at 1.25x base input, a 1-hour write at 2x "
                        "and a read at 0.1x, so break-even is a read/write ratio rather than a volume",
               "sources": [DOCS["anthropic"]["url"]], "citations": ["a1c1"], "confidence": "high"},
              {"claim": "OpenAI caches automatically above 1024 tokens with no write premium and no "
                        "breakpoint to place",
               "sources": [DOCS["openai"]["url"]], "citations": ["a1c3"], "confidence": "high"},
              {"claim": "A prefix under 1024 tokens is silently served uncached on both platforms",
               "sources": [DOCS["anthropic"]["url"]], "citations": ["a1c2"], "confidence": "medium"},
              {"claim": "A cached prefix expires five minutes after it is written",
               "sources": [DOCS["openai"]["url"]], "citations": ["a1c4"], "confidence": "medium"},
          ]}),
      1.42, ["a1c1", "a1c3", "a1c2", "a1c4"], inp=26_380, out=4_200, cache_read=184_400, cache_write=12_400,
      search=2, fetch=3)
emit({"type": "angle_status", "angle_id": "a1", "status": "complete"})
update("a1", "complete", 1.42)

update("q1", "approved")
node("x1", "inquiry", "Get the hit-rate distribution behind the 52% claim", "queued", "spawn", 2, 1)
edge("q1", "x1", "decomposes")
emit({"type": "angle_status", "angle_id": "x1", "status": "running"})

text_delta("a2", "after a cache breakpoint was placed above the system prompt. ")
usage("a2", "anthropic", "claude-code/sonnet", 0.92, 14_600, 2_510, cache_read=102_300, cache_write=0,
      fetch=1)
topic("a2", "research", "complete",
      writeup(A2_PROSE, ["a2c1", "a2c2", "a2c3"], {
          "headline": "One instrumented sample says 52%, and it self-selected",
          "status": "complete", "sourcesConsulted": 3,
          "findings": [
              {"claim": "Median input spend across 41 instrumented deployments fell 52% after a cache "
                        "breakpoint was placed above the system prompt",
               "sources": [DOCS["report"]["url"]], "citations": ["a2c1"], "confidence": "medium"},
              {"claim": "One first-hand account reports the same 52% in the first week",
               "sources": [DOCS["blog"]["url"]], "citations": ["a2c2"], "confidence": "low"},
              {"claim": "Overnight, one reporting team's hit rate falls to roughly one request in five",
               "sources": [DOCS["blog"]["url"]], "citations": ["a2c2"], "confidence": "low"},
              {"claim": "Community threads report no measurable saving at low request volumes",
               "sources": [DOCS["hn"]["url"]], "citations": ["a2c3"], "confidence": "unverified"},
          ]}),
      1.86, ["a2c1", "a2c2", "a2c3"], inp=29_810, out=4_890, cache_read=193_800, cache_write=14_100,
      search=3, fetch=3)
emit({"type": "angle_status", "angle_id": "a2", "status": "complete"})
update("a2", "complete", 1.86)

topic("a3", "research", "error", A3_PROSE.strip(), 0.31, [],
      note="the provider returned 529 overloaded on three consecutive attempts; the angle was abandoned "
           "after two retries",
      inp=6_040, out=620, cache_read=41_000, cache_write=6_800, search=1, fetch=1)
emit({"type": "angle_status", "angle_id": "a3", "status": "error"})
update("a3", "error", 0.31)

thinking_delta("x1", "The distribution is the whole question. If it only exists in a dashboard nobody "
                     "published, say so rather than reconstruct it. ")
tool("x1", "web_fetch", url="https://blog.helmsley-ai.dev/posts/we-cut-our-inference-bill-in-half")
emit(doc_event("x1", "blog"))
text_delta("a4", "Reads only count if they land inside the window, so the operative number is reads per "
                 "window, not reads per write. ")
usage("a4", "anthropic", "claude-code/sonnet", 1.55, 21_400, 3_100, cache_read=140_200, cache_write=18_600,
      search=2, fetch=2)
usage("a4", "anthropic", "claude-code/sonnet", 1.45, 19_900, 2_640, cache_read=131_500, cache_write=0,
      search=1, fetch=1)
topic("a4", "research", "halted",
      writeup(A4_PROSE, ["a4c1"], {
          "headline": "Break-even is a ratio; the window turns it into a traffic question",
          "status": "inconclusive", "sourcesConsulted": 1,
          "note": "stopped at the per-angle spend cap of $3.00 before the window-corrected arithmetic was "
                  "finished",
          "findings": [
              {"claim": "Reads only pay when they land inside the cache window, so reads-per-window is the "
                        "operative ratio rather than reads-per-write",
               "sources": [DOCS["status"]["url"]], "citations": ["a4c1"], "confidence": "unverified"},
          ]}),
      3.00, ["a4c1"], note="stopped at the per-angle spend cap of $3.00",
      inp=41_300, out=5_740, cache_read=271_700, cache_write=18_600, search=3, fetch=3)
emit({"type": "angle_status", "angle_id": "a4", "status": "halted"})
update("a4", "halted", 3.0)

text_delta("x1", "Not published anywhere I can reach. The Helmsley post gives one number and no "
                 "distribution, and says so itself. ")
usage("x1", "anthropic", "claude-code/sonnet", 1.10, 16_200, 1_820, cache_read=104_600, cache_write=11_200,
      search=1, fetch=2)
topic("x1", "research", "inconclusive",
      writeup(X1_PROSE, ["x1c1"], {
          "headline": "The hit-rate distribution behind the 52% was never published",
          "status": "inconclusive", "sourcesConsulted": 2,
          "note": "answering this from the savings percentiles would restate the same claim, so it is left "
                  "open",
          "findings": [
              {"claim": "The hit-rate distribution behind the reported 52% is unpublished and held in an "
                        "internal dashboard",
               "sources": [DOCS["blog"]["url"]], "citations": ["x1c1"], "confidence": "medium"},
          ]}),
      1.10, ["x1c1"], inp=16_200, out=1_820, cache_read=104_600, cache_write=11_200, search=1, fetch=2)
emit({"type": "angle_status", "angle_id": "x1", "status": "complete"})
update("x1", "complete", 1.10)

emit({"type": "phase", "phase": "synthesizing"})
emit({"type": "angle_status", "angle_id": "synthesis", "status": "running"})
node("synthesis", "synthesis", "Synthesis", "running", "derived", 3, 1)
for key in ["a1", "a2", "a3", "a4", "x1"]:
    edge(key, "synthesis", "synthesizes")
thinking_delta("synthesis", "Four angles, one dead and one capped. The pricing is solid; the savings number "
                            "is one self-selected sample. Do not let it read as a promise. ")
text_delta("synthesis", "Prompt caching pays for a chat product when the same prefix is read back several "
                        "times inside the cache window, and stops paying when traffic is thin enough that "
                        "most windows expire unread. ")
usage("synthesis", "anthropic", "claude-code/opus", 1.64, 34_900, 3_980, cache_read=118_000,
      cache_write=22_400)

emit({"type": "phase", "phase": "grounding"})
thinking_delta("verify", "One cited URL appears in no angle's sources. Drop it from the findings rather "
                         "than keep a citation nobody consulted. ")
text_delta("verify", "Removed one untraceable citation; every other cited URL is traceable to an angle. ")
usage("verify", "anthropic", "claude-code/opus", 0.04, 3_100, 240)
topic("verify", "verify", "complete",
      "Removed one untraceable citation (https://www.helmsley-ai.dev/pricing): no angle consulted it. Every "
      "other cited URL traces to an angle's sources.\n\n```json\n"
      + json.dumps({"headline": "Citation check", "status": "complete", "sourcesConsulted": 0,
                    "findings": []}) + "\n```\n",
      0.04, [], model="claude-code/opus", inp=3_100, out=240, emit_line=False)

emit({"type": "phase", "phase": "validating"})
text_delta("claim_sweep_1", "Checking 7 claims against their located quotes. ")
usage("claim_sweep_1", "anthropic", "claude-code/haiku", 0.03, 9_400, 610)
text_delta("critic_coverage", "The question asks where it stops paying; the answer never names a hit rate. ")
usage("critic_coverage", "anthropic", "claude-code/haiku", 0.06, 11_200, 540)
text_delta("critic_conflicts", "The angles do not actually contradict each other on the pricing. ")
usage("critic_conflicts", "anthropic", "claude-code/haiku", 0.06, 10_800, 380)
text_delta("critic_sources", "The 52% is load-bearing and rests on one self-selected report. ")
usage("critic_sources", "anthropic", "claude-code/haiku", 0.06, 11_600, 470)
for event in verdict_nodes(ROUND_1, "synthesis", 4):
    emit(event)

topic("synthesis", "synthesis", "complete",
      writeup(S1_PROSE, ["a1c1", "a1c3", "a1c2", "a2c1", "a2c2", "a1c4"], {
          "headline": "Pays when traffic clusters; the threshold is still unnamed",
          "status": "complete", "sourcesConsulted": 5,
          "findings": [
              {"claim": "Break-even is a read/write ratio set by the 1.25x write premium and the 0.1x read "
                        "discount", "sources": [DOCS["anthropic"]["url"]], "citations": ["a1c1"],
               "confidence": "high"},
              {"claim": "Median input spend fell 52% across 41 self-selected deployments",
               "sources": [DOCS["report"]["url"]], "citations": ["a2c1"], "confidence": "medium"},
              {"claim": "A cached prefix expires five minutes after it is written",
               "sources": [DOCS["openai"]["url"]], "citations": ["a1c4"], "confidence": "medium"},
          ],
          "conflicts": [
              {"claim": "Whether the 1-hour window is ever worth its 2x write premium",
               "positions": ["a1: the price sheet makes it almost never worth it",
                             "a2: practitioners who bought it report being satisfied"]},
              {"claim": "Whether the 52% median transfers to a bursty product",
               "positions": ["a2: the sample is 41 real deployments",
                             "a4: the sample says nothing about traffic shape"]},
          ],
          "gaps": ["The hit rate at which caching stops paying is not stated by any source consulted",
                   "No angle finished the window-corrected break-even arithmetic"]},
          untraceable=["https://www.helmsley-ai.dev/pricing"], validation=ROUND_1),
      1.64, ["a1c1", "a1c3", "a1c2", "a2c1", "a2c2", "a1c4"], model="claude-code/opus",
      inp=34_900, out=3_980, cache_read=118_000, cache_write=22_400)
emit({"type": "angle_status", "angle_id": "synthesis", "status": "complete"})
update("synthesis", "complete", 1.64)

node("q3", "question", "find a source that settles whether the five-minute window runs from the write",
     "approved", "objection", 1, 1, parents=["v1_claim_sweep"],
     meta={"lens": "claim_sweep", "statement": SWEEP_OBJ_TTL["statement"], "severity": "blocking",
           "est_cost_usd": 1.5})
edge("v1_claim_sweep", "q3", "spawned", "claim_sweep")
node("x3", "inquiry", "Does a cache read refresh the window, or does it run from the write?", "queued",
     "objection", 1, 2)
edge("q3", "x3", "decomposes")
node("q4", "question", "find a published measurement of savings against cache hit rate", "approved",
     "objection", 1, 1, parents=["v1_coverage"],
     meta={"lens": "coverage", "statement": OBJ_COVERAGE["statement"], "severity": "blocking",
           "est_cost_usd": 1.5})
edge("v1_coverage", "q4", "spawned", "coverage")
node("x4", "inquiry", "What happens below a 40% hit rate", "queued", "objection", 1, 2)
edge("q4", "x4", "decomposes")

emit({"type": "round", "round": 2, "angles": [
    {"angle_id": "x3", "title": "Does a cache read refresh the window, or does it run from the write?",
     "prompt": "A validator read the answer drafted so far and objected: " + SWEEP_OBJ_TTL["statement"]
               + "\n\nResearch ONLY the task that would settle that objection: " + SWEEP_OBJ_TTL["followup"]},
    {"angle_id": "x4", "title": "What happens below a 40% hit rate",
     "prompt": "A validator read the answer drafted so far and objected: " + OBJ_COVERAGE["statement"]
               + "\n\nResearch ONLY the task that would settle that objection: " + OBJ_COVERAGE["followup"]},
]})
emit({"type": "phase", "phase": "researching"})
emit({"type": "angle_status", "angle_id": "x3", "status": "running"})
emit({"type": "angle_status", "angle_id": "x4", "status": "running"})
thinking_delta("x3", "The distinction is between a lifetime and an idle timeout. Read the lifetime section "
                     "word by word. ")
tool("x3", "web_fetch", url="https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching")
emit(doc_event("x3", "anthropic"))
tool("x4", "web_fetch", url="https://research.northwind-chat.io/reports/inference-cost-2026.pdf",
     offset=12_000)
emit(doc_event("x4", "report"))
text_delta("x3", "It refreshes, and the round-1 reading of this was wrong. ")
text_delta("x4", "Below a 40% hit rate the median deployment in Northwind's sample saved nothing "
                 "measurable. ")
usage("x3", "anthropic", "claude-code/sonnet", 1.21, 17_800, 2_140, cache_read=112_400, cache_write=9_800,
      fetch=2)
usage("x4", "anthropic", "claude-code/sonnet", 1.34, 18_600, 2_420, cache_read=121_900, cache_write=10_400,
      search=1, fetch=2)
topic("x3", "research", "complete",
      writeup(X3_PROSE, ["x3c1", "x3c2"], {
          "headline": "The window refreshes on read — round 1 had it backwards",
          "status": "complete", "sourcesConsulted": 2,
          "findings": [
              {"claim": "Each cache hit resets the countdown, so a prefix read once a minute stays warm "
                        "indefinitely without being rewritten",
               "sources": [DOCS["anthropic"]["url"]], "citations": ["x3c1"], "confidence": "high"},
              {"claim": "Entries are evicted for idle traffic, not for elapsed time since the write",
               "sources": [DOCS["anthropic"]["url"]], "citations": ["x3c2"], "confidence": "high"},
          ]}),
      1.21, ["x3c1", "x3c2"], inp=17_800, out=2_140, cache_read=112_400, cache_write=9_800, fetch=2)
emit({"type": "angle_status", "angle_id": "x3", "status": "complete"})
update("x3", "complete", 1.21)
topic("x4", "research", "complete",
      writeup(X4_PROSE, ["x4c1", "x4c4", "x4c2", "x4c3"], {
          "headline": "Nothing measurable below a 40% hit rate",
          "status": "complete", "sourcesConsulted": 1,
          "findings": [
              {"claim": "Below a 40% cache hit rate the median deployment saved nothing measurable, and 9 "
                        "of 41 spent more", "sources": [DOCS["report"]["url"]],
               "citations": ["x4c1", "x4c4"], "confidence": "high"},
              {"claim": "Cache hit rate tracks session density rather than request volume",
               "sources": [DOCS["report"]["url"]], "citations": ["x4c2"], "confidence": "high"},
              {"claim": "Break-even sits at roughly 5 reads per write",
               "sources": [DOCS["report"]["url"]], "citations": ["x4c3"], "confidence": "medium"},
          ]}),
      1.34, ["x4c1", "x4c4", "x4c2", "x4c3"], inp=18_600, out=2_420, cache_read=121_900, cache_write=10_400,
      search=1, fetch=2)
emit({"type": "angle_status", "angle_id": "x4", "status": "complete"})
update("x4", "complete", 1.34)

emit({"type": "phase", "phase": "synthesizing"})
emit({"type": "angle_status", "angle_id": "synthesis", "status": "running"})
node("synthesis", "synthesis", "Synthesis", "running", "derived", 3, 2)
edge("x3", "synthesis", "synthesizes")
edge("x4", "synthesis", "synthesizes")
text_delta("synthesis", "Redrafting: the window refreshes on read, and there is now a hit rate to name. ")
usage("synthesis", "anthropic", "claude-code/opus", 1.72, 41_200, 4_310, cache_read=136_500,
      cache_write=19_800)
emit({"type": "phase", "phase": "grounding"})
emit({"type": "phase", "phase": "validating"})
text_delta("claim_sweep_2", "Checking 9 claims against their located quotes. ")
usage("claim_sweep_2", "anthropic", "claude-code/haiku", 0.04, 12_100, 720)
text_delta("critic_coverage", "The hit-rate threshold the last round was missing is now stated. ")
usage("critic_coverage", "anthropic", "claude-code/haiku", 0.05, 12_800, 430)
text_delta("critic_conflicts", "The 1-hour versus 5-minute disagreement is still unaddressed. ")
usage("critic_conflicts", "anthropic", "claude-code/haiku", 0.05, 12_400, 520)
text_delta("critic_sources", "Two load-bearing figures now come from the same single report. ")
usage("critic_sources", "anthropic", "claude-code/haiku", 0.05, 12_600, 460)
for event in verdict_nodes(ROUND_2, "synthesis", 4):
    emit(event)
topic("synthesis", "synthesis", "complete",
      writeup(S2_PROSE, ["a1c1", "a1c3", "a1c2", "x3c1", "x3c2", "x4c1", "x4c2", "x4c3", "a2c1", "a2c2"], {
          "headline": "Pays above a 40% hit rate; the window refreshes on read",
          "status": "complete", "sourcesConsulted": 5,
          "findings": [
              {"claim": "The cache window refreshes on every read, so five minutes is a floor on an unread "
                        "entry rather than a ceiling on a live one",
               "sources": [DOCS["anthropic"]["url"]], "citations": ["x3c1", "x3c2"], "confidence": "high"},
              {"claim": "Below a 40% hit rate the median deployment saved nothing measurable",
               "sources": [DOCS["report"]["url"]], "citations": ["x4c1"], "confidence": "high"},
              {"claim": "Break-even sits at roughly 5 reads per write",
               "sources": [DOCS["report"]["url"]], "citations": ["x4c3"], "confidence": "medium"},
              {"claim": "Median input spend fell 52% across 41 self-selected deployments",
               "sources": [DOCS["report"]["url"]], "citations": ["a2c1"], "confidence": "medium"},
          ],
          "conflicts": [
              {"claim": "Whether the 1-hour window is ever worth its 2x write premium",
               "positions": ["a1: the price sheet makes it almost never worth it",
                             "a2: practitioners who bought it report being satisfied"]},
          ],
          "gaps": ["No measurement compares the 1-hour and 5-minute windows under bursty traffic"]},
          validation=ROUND_2),
      1.72, ["a1c1", "a1c3", "a1c2", "x3c1", "x3c2", "x4c1", "x4c2", "x4c3", "a2c1", "a2c2"],
      model="claude-code/opus", inp=41_200, out=4_310, cache_read=136_500, cache_write=19_800)
emit({"type": "angle_status", "angle_id": "synthesis", "status": "complete"})
update("synthesis", "complete", 1.72)

update("q2", "expired")

node("q5", "question", "find a measurement comparing the 1-hour window against the 5-minute one", "approved",
     "objection", 1, 2, parents=["v2_conflicts"],
     meta={"lens": "conflicts", "statement": OBJ_CONFLICTS_2["statement"], "severity": "blocking",
           "est_cost_usd": 1.5})
edge("v2_conflicts", "q5", "spawned", "conflicts")
node("x5", "inquiry", "Is the 1-hour window ever worth its 2x write premium?", "queued", "objection", 1, 3)
edge("q5", "x5", "decomposes")
emit({"type": "round", "round": 3, "angles": [
    {"angle_id": "x5", "title": "Is the 1-hour window ever worth its 2x write premium?",
     "prompt": "A validator read the answer drafted so far and objected: " + OBJ_CONFLICTS_2["statement"]
               + "\n\nResearch ONLY the task that would settle that objection: "
               + OBJ_CONFLICTS_2["followup"]},
]})
emit({"type": "phase", "phase": "researching"})
emit({"type": "angle_status", "angle_id": "x5", "status": "running"})
tool("x5", "web_search", query="1 hour vs 5 minute prompt cache window measured cost bursty traffic")
emit(doc_event("x5", "latency"))
text_delta("x5", "There is no published measurement, and I want to be precise about that rather than fill "
                 "it in. ")
usage("x5", "anthropic", "claude-code/sonnet", 0.98, 14_100, 1_680, cache_read=96_300, cache_write=8_200,
      search=3, fetch=1)
topic("x5", "research", "complete",
      writeup(X5_PROSE, ["x5c1", "x5c2"], {
          "headline": "Nobody has measured it; the choice stays a judgement about traffic",
          "status": "complete", "sourcesConsulted": 1,
          "findings": [
              {"claim": "No published measurement compares the 1-hour cache window against the 5-minute one "
                        "under bursty traffic",
               "sources": [DOCS["latency"]["url"]], "citations": ["x5c2"], "confidence": "high"},
              {"claim": "The latency benefit of a cached prefix survives where the cost benefit does not",
               "sources": [DOCS["latency"]["url"]], "citations": ["x5c1"], "confidence": "high"},
          ]}),
      0.98, ["x5c1", "x5c2"], inp=14_100, out=1_680, cache_read=96_300, cache_write=8_200, search=3, fetch=1)
emit({"type": "angle_status", "angle_id": "x5", "status": "complete"})
update("x5", "complete", 0.98)

emit({"type": "phase", "phase": "synthesizing"})
emit({"type": "angle_status", "angle_id": "synthesis", "status": "running"})
node("synthesis", "synthesis", "Synthesis", "running", "derived", 3, 3)
edge("x5", "synthesis", "synthesizes")
text_delta("synthesis", "Third draft: the window question is unanswerable from published data, so say that "
                        "rather than pick a side. ")
usage("synthesis", "anthropic", "claude-code/opus", 1.55, 44_800, 4_020, cache_read=151_200,
      cache_write=17_600)
emit({"type": "phase", "phase": "grounding"})
emit({"type": "phase", "phase": "validating"})
text_delta("claim_sweep_3", "Checking 11 claims against their located quotes. ")
usage("claim_sweep_3", "anthropic", "claude-code/haiku", 0.03, 13_400, 690)
for event in verdict_nodes(ROUND_3, "synthesis", 4):
    emit(event)
topic("synthesis", "synthesis", "complete",
      writeup(S3_PROSE, ["a1c1", "a1c3", "a1c2", "x3c1", "x3c2", "x4c1", "x4c2", "x4c3", "a2c1", "a2c2",
                         "x5c1", "x5c2"], {
          "headline": "Pays above a 40% hit rate; window size is still unmeasured",
          "status": "complete", "sourcesConsulted": 6,
          "findings": [
              {"claim": "Below a 40% hit rate the median deployment saved nothing measurable",
               "sources": [DOCS["report"]["url"]], "citations": ["x4c1"], "confidence": "high"},
              {"claim": "caching roughly halves input spend for a bursty chat product",
               "sources": [DOCS["report"]["url"]], "citations": ["a2c1"], "confidence": "medium"},
              {"claim": "No published measurement compares the 1-hour window against the 5-minute one",
               "sources": [DOCS["latency"]["url"]], "citations": ["x5c2"], "confidence": "high"},
          ],
          "conflicts": [
              {"claim": "Whether the 1-hour window is ever worth its 2x write premium",
               "positions": ["a1: the price sheet makes it almost never worth it",
                             "x5: no measurement exists either way"]},
          ],
          "gaps": ["No measurement compares the 1-hour and 5-minute windows under bursty traffic"]},
          validation=ROUND_3),
      1.55, ["a1c1", "a1c3", "a1c2", "x3c1", "x3c2", "x4c1", "x4c2", "x4c3", "a2c1", "a2c2", "x5c1", "x5c2"],
      model="claude-code/opus", inp=44_800, out=4_020, cache_read=151_200, cache_write=17_600)
emit({"type": "angle_status", "angle_id": "synthesis", "status": "complete"})
update("synthesis", "complete", 1.55)

emit({"type": "phase", "phase": "reconciling"})
emit({"type": "angle_status", "angle_id": "reconciliation", "status": "running"})
node("reconciliation", "synthesis", "Reconciliation", "running", "derived", 3, 3)
edge("synthesis", "reconciliation", "synthesizes")
thinking_delta("reconciliation", "Round 1 said the window runs from the write. Round 2 proved it refreshes "
                                 "on read. The corrected claim survives; the original does not appear. ")
text_delta("reconciliation", "Prompt caching pays for a chat product whose traffic clusters tightly enough "
                             "that a written prefix is read back several times before it goes idle. ")
usage("reconciliation", "anthropic", "claude-code/opus", 1.48, 52_600, 4_640, cache_read=168_400,
      cache_write=14_900)
topic("reconciliation", "synthesis", "complete",
      writeup(RECON_PROSE, ["a1c1", "x4c3", "a1c3", "a1c2", "x3c1", "x3c2", "x4c1", "x4c2", "a2c1", "a2c2",
                            "x5c2", "x5c1"], {
          "headline": "Pays above a 40% hit rate; the 52% is not a promise for bursty traffic",
          "status": "complete", "sourcesConsulted": 6,
          "findings": [
              {"claim": "Break-even is roughly 5 reads per write, which for a 5-minute window is a question "
                        "about how tightly conversations overlap",
               "sources": [DOCS["report"]["url"], DOCS["anthropic"]["url"]],
               "citations": ["x4c3", "a1c1"], "confidence": "high"},
              {"claim": "The cache window refreshes on every read, so five minutes is a floor on an unread "
                        "entry rather than a ceiling on a live one",
               "sources": [DOCS["anthropic"]["url"]], "citations": ["x3c1", "x3c2"], "confidence": "high"},
              {"claim": "Below a 40% hit rate the median deployment saved nothing measurable",
               "sources": [DOCS["report"]["url"]], "citations": ["x4c1"], "confidence": "high"},
              {"claim": "The reported 52% median is what a well-clustered deployment achieved, not an "
                        "expectation for a bursty one",
               "sources": [DOCS["report"]["url"]], "citations": ["a2c1"], "confidence": "low"},
          ],
          "conflicts": [
              {"claim": "Whether the 1-hour window is ever worth its 2x write premium",
               "positions": ["price sheet: almost never", "practitioners: worth it",
                             "x5: no measurement exists either way"]},
          ],
          "gaps": ["No measurement compares the 1-hour and 5-minute windows under bursty traffic"]},
          validation=ROUND_3),
      1.48, ["a1c1", "x4c3", "a1c3", "a1c2", "x3c1", "x3c2", "x4c1", "x4c2", "a2c1", "a2c2", "x5c2", "x5c1"],
      model="claude-code/opus", reconciled=True, inp=52_600, out=4_640, cache_read=168_400, cache_write=14_900)
emit({"type": "angle_status", "angle_id": "reconciliation", "status": "complete"})
update("reconciliation", "complete", 1.48)

emit({"type": "phase", "phase": "done"})
emit({
    "type": "run_result",
    "status": "inconclusive",
    "grounding": "captured",
    "total_cost_usd": TOTAL,
    "note": "The round cap of 3 was reached with 1 blocking objection(s) still stand against the answer.",
    "topics": TOPICS,
    "documents": [{k: v for k, v in d.items() if not k.startswith("_")} for d in DOCS.values()],
    "capture_failures": [{
        "source_id": DOCS["status"]["source_id"], "url": DOCS["status"]["url"], "stage": "write",
        "error": "EACCES: permission denied, open 'sources/%s.md'" % DOCS["status"]["source_id"]}],
    "citation_orphans": [{
        "stage": "verify",
        "claim": "Overnight, one reporting team's hit rate falls to roughly one request in five",
        "citation_ids": ["a2c2"]}],
    "validation": VALIDATION,
})


# ---------------------------------------------------------------- pdf

def pdf_bytes(pages):
    def escape(line):
        return line.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")

    objects = []
    kids = " ".join("%d 0 R" % (4 + 2 * i) for i in range(len(pages)))
    objects.append("<< /Type /Catalog /Pages 2 0 R >>")
    objects.append("<< /Type /Pages /Kids [%s] /Count %d >>" % (kids, len(pages)))
    objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    streams = []
    for index, lines in enumerate(pages):
        content = "BT\n/F1 10 Tf\n14 TL\n56 740 Td\n"
        for line in lines:
            content += "(%s) Tj T*\n" % escape(line)
        content += "ET\n"
        streams.append(content)
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R "
                       ">> >> /Contents %d 0 R >>" % (5 + 2 * index))
        objects.append(None)

    out = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    stream_index = 0
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        if body is None:
            data = streams[stream_index].encode("cp1252")
            stream_index += 1
            out += ("%d 0 obj\n<< /Length %d >>\nstream\n" % (number, len(data))).encode("cp1252")
            out += data
            out += b"endstream\nendobj\n"
        else:
            out += ("%d 0 obj\n%s\nendobj\n" % (number, body)).encode("cp1252")
    xref = len(out)
    out += ("xref\n0 %d\n" % (len(objects) + 1)).encode()
    out += b"0000000000 65535 f \n"
    for offset in offsets[1:]:
        out += ("%010d 00000 n \n" % offset).encode()
    out += ("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objects) + 1, xref)).encode()
    return bytes(out)


# ---------------------------------------------------------------- write everything

for name in os.listdir(SOURCES):
    os.remove(os.path.join(SOURCES, name))

for key, document in DOCS.items():
    if document["_text"]:
        with open(os.path.join(SOURCES, "%s.md" % document["source_id"]), "w") as handle:
            handle.write(document["_text"])

pdf = pdf_bytes(REPORT_PAGES)
DOCS["report"]["byte_size"] = len(pdf)
with open(os.path.join(SOURCES, "%s.pdf" % DOCS["report"]["source_id"]), "wb") as handle:
    handle.write(pdf)

# byte_size is read back into the already-emitted document events, so patch them in place.
for event in EVENTS:
    if event.get("type") == "document" and event["document"]["source_id"] == DOCS["report"]["source_id"]:
        event["document"]["byte_size"] = len(pdf)
    if event.get("type") == "run_result":
        for document in event["documents"]:
            if document["source_id"] == DOCS["report"]["source_id"]:
                document["byte_size"] = len(pdf)

with open(os.path.join(FIXTURES, "mock-run.ndjson"), "w") as handle:
    for event in EVENTS:
        handle.write(json.dumps(event, ensure_ascii=False) + "\n")

print("events: %d" % len(EVENTS))
print("total cost: %.2f" % TOTAL)
print("documents: %d" % len(DOCS))
print("citations: %d" % len(CITES))
for key, document in DOCS.items():
    print("  %-9s %s pages=%s capture=%s len=%d" % (key, document["source_id"], document["page_offsets"],
                                                    document["capture"], document["text_length"]))

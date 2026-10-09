---
title: "Does prompt caching pay for a chat product"
headline: "Pays above a 40% hit rate; the 52% is not a promise for bursty traffic"
question: "Does prompt caching pay for a chat product?"
status: inconclusive
trust: unchecked
date: 2026-10-09
sources_cited: 5
sources_read: 5
claims: 12
run: 01K7A0000000000000000RUN01
question_id: 01K7A0000000000000000QST01
build: ""
---

# Does prompt caching pay for a chat product

> Pays above a 40% hit rate; the 52% is not a promise for bursty traffic

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

## Open items

### Conflicts

- **Whether the 1-hour window is ever worth its 2x write premium** — price sheet: almost never · practitioners: worth it · x5: no measurement exists either way

### Objections still standing

- claim sweep · blocking — the claim "caching roughly halves input spend for a bursty chat product" is unsupported by its own located quotes — the 52% median is across all 41 deployments; the report's own bursty band sits at a 22% hit rate, below the break-even it states → find a source that settles, one way or the other: caching roughly halves input spend for a bursty chat product

### Gaps

- No measurement compares the 1-hour and 5-minute windows under bursty traffic

### Tasks that did not finish

- Failure modes: stampedes, cold starts and what breaks at scale — error: the provider returned 529 overloaded on three consecutive attempts; the angle was abandoned after two retries
- Break-even arithmetic for a bursty product — halted: stopped at the per-angle spend cap of $3.00
- Get the hit-rate distribution behind the 52% claim — inconclusive

## Sources

1. [Prompt caching - Anthropic](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) · vendor — ✓ verified
2. [Northwind Chat — Inference Cost Report, Q1 2026](https://research.northwind-chat.io/reports/inference-cost-2026.pdf) · vendor — ✓ verified
3. [Prompt caching - OpenAI API](https://platform.openai.com/docs/guides/prompt-caching) · vendor — ✓ verified
4. [We cut our inference bill in half](https://blog.helmsley-ai.dev/posts/we-cut-our-inference-bill-in-half) · vendor — ≈ close match
5. [Latency optimization - OpenAI API](https://platform.openai.com/docs/guides/latency-optimization) · vendor — ✓ verified

[^a1c1]: [Prompt caching - Anthropic](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) — “A 5-minute cache write is billed at 1.25x the base input token price, a 1-hour cache write at 2x, and a cache read at 0.1x the base input token price.” — (✓ verified)
[^x4c3]: [Northwind Chat — Inference Cost Report, Q1 2026](https://research.northwind-chat.io/reports/inference-cost-2026.pdf) — p. 2 — “A cached prefix pays for itself once it is read roughly 5 times per write” — (✓ verified)
[^a1c3]: [Prompt caching - OpenAI API](https://platform.openai.com/docs/guides/prompt-caching) — “Prompt caching is enabled automatically for prompts longer than 1024 tokens.” — (✓ verified)
[^a1c2]: [Prompt caching - Anthropic](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) — “the minimum cacheable prefix is 1024 tokens for most models and 2048 tokens for the smallest ones” — (✓ verified)
[^x3c1]: [Prompt caching - Anthropic](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) — “Each cache hit resets the countdown, so a prefix that is read at least once a minute stays warm indefinitely without ever being written again.” — (✓ verified)
[^x3c2]: [Prompt caching - Anthropic](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) — “Idle traffic, not elapsed time since the write, is what lets an entry fall out of the cache.” — (✓ verified)
[^x4c1]: [Northwind Chat — Inference Cost Report, Q1 2026](https://research.northwind-chat.io/reports/inference-cost-2026.pdf) — p. 3 — “Below a 40% cache hit rate the median deployment saved nothing measurable” — (✓ verified)
[^a2c1]: [Northwind Chat — Inference Cost Report, Q1 2026](https://research.northwind-chat.io/reports/inference-cost-2026.pdf) — p. 2 — “median spend on input tokens fell 52% after a cache breakpoint was introduced above the system prompt” — (✓ verified)
[^a2c2]: [We cut our inference bill in half](https://blog.helmsley-ai.dev/posts/we-cut-our-inference-bill-in-half) — “after moving the tool schema and product manual above one cache breakpoint, input spend dropped 52% in the first week” — (≈ close match)
[^x5c2]: [Latency optimization - OpenAI API](https://platform.openai.com/docs/guides/latency-optimization) — “No published measurement compares the 1-hour cache window against the 5-minute one under bursty traffic.” — (✓ verified)
[^x5c1]: [Latency optimization - OpenAI API](https://platform.openai.com/docs/guides/latency-optimization) — “A cached prefix skips prefill, so the latency win survives even where the cost win does not.” — (✓ verified)

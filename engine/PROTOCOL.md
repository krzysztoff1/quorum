# Quorum engine NDJSON protocol
Every stdout line is one JSON object (NDJSON), consumable UNCHANGED by the Swift ResearchOutputParser.

Fields the Swift parser reads (do not rename): `type`, `total_cost_usd` (cumulative, monotonic),
`session_id`, `result`, `message.content[]` with `{type:"text"|"thinking"|"tool_use", text, thinking, name, input}`,
`input.{query|url|prompt|file_path|pattern}`, `delta.{type,text,thinking}` (type ∈ {text_delta, thinking_delta}),
also nested as `event.delta`.

Event lines in order:
1. Handshake (FIRST line): {"type":"system","subtype":"init","engine":"quorum-engine","engine_version":"0.1.0","protocol_version":4,"session_id":"<uuid>","model":"deepseek/deepseek-chat"}
2. Text/thinking deltas: {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}} (and thinking_delta)
3. Tool use (sources): {"type":"assistant","message":{"content":[{"type":"tool_use","name":"web_search","input":{"query":"..."}}]}} and name "web_fetch" with input {"url":"...","offset":<int, optional>}
4. Per-step usage (one per model call, carries cumulative total_cost_usd): {"type":"usage","total_cost_usd":0.0031,"usage":{"provider":"deepseek","model":"deepseek-chat","input_tokens":1200,"output_tokens":800,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.0007,"search_calls":1,"fetch_calls":0}}
4b. Captured source (v2, one per newly registered document — see "Evidence" below): {"type":"document","document":{…}}
5. Final result (result = COMPLETE assistant markdown writeup INCLUDING the trailing fenced ```json summary; usage = run totals): {"type":"result","subtype":"success","total_cost_usd":0.0142,"session_id":"<uuid>","result":"<writeup + fenced json>","usage":{"provider":"deepseek","model":"deepseek-chat","input_tokens":5000,"output_tokens":3200,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.0142,"search_calls":4,"fetch_calls":6}}
6. Wind-down/error: still emit a result whose fenced json has "status":"inconclusive" + a note; missing key → {"type":"error","error":"...","provider":"..."} then graceful inconclusive result.

The trailing fenced ```json block:
{"headline":"...","status":"complete|inconclusive","sourcesConsulted":<int>,"citations":[{"id":"c1","source":"s3f9a1c2","quote":"verbatim span"}],"findings":[{"claim":"...","sources":["url"],"citations":["c1"],"confidence":"high|medium|low|unverified"}],"conflicts":[{"claim":"...","positions":["..."]}],"gaps":["..."],"note":"optional"}
(conflicts/gaps only for synthesis-style prompts; for a normal single-topic run, findings + headline + status + sourcesConsulted are the core.)

`citations` and `findings[].citations` are v2 (evidence grounding). The MODEL writes `{"id","source","quote"}`,
where `source` is the `source_id` a `web_fetch` returned and `quote` is 10–300 characters copied
CHARACTER-FOR-CHARACTER from that source's fetched text. Each `[^c1]` marker in the prose needs one entry.
The `run` command REWRITES that array into RESOLVED citations (`source_id`, `match`, `start`, `end`, `page`)
before it emits the topic, so a persisted writeup carries verified evidence rather than a claim about it.
Consumers accept either spelling of the source field.

## run command (fan-out orchestration in the engine)

`quorum-engine run` reads ONE JSON config object on **stdin** (NO secrets — keys stay in env) and runs
the whole fan-out: plan → parallel angles → synthesis → citation grounding → validation → (for a dive that
ran more than one round) reconciliation into one current answer. Each role runs on the config's model — `"claude-code[/alias]"` spawns the `claude` CLI
(subscription OAuth stays inside the CLI; the engine never reads the token), any `"provider/model-id"`
runs the AI-SDK BYOK loop. Own-search MCP is wired to claude when a search key is in env.

stdin config: `{ question, angleCount, angles?, angleModel, synthesisModel, validatorModel?, effort, perTopicBudgetUSD,
runBudgetUSD, perTopicTimeoutSec, priorNotesExcerpt, template, rounds, angleConcurrency?, useProjectContext,
projectDir, evidenceDir, runDeadlineSec?, approvalWindowSec?, spawnMode?, spawnDir? }`. `rounds` is the
validator loop's ROUND CAP (default 4), not a round count: a round past the first runs only while blocking
objections stand. `angleConcurrency` (default 4) is how many angles may be in flight at once — each is a
model loop with an `mcp-serve` child, so a wide frontier is worked a few at a time. `approvalWindowSec`
(default 300) is how long a pending spawn stays approvable, NOT a wait: the run never blocks on a verdict,
and an offer nobody takes inside the window expires. `validatorModel` (default: the synthesis model) is who judges the answer — cheap, tool-less, and routed by the
app to a different family than the one that drafted it, or to the CLI's small model when there is no key.
`angles` (optional `[{title,prompt}]`) are user-pre-approved round-1 angles —
when present the engine SKIPS its own round-1 planning and uses them verbatim (still emitting `plan`). `evidenceDir` (v2) is where captured sources are written — usually
`<runDir>/evidence`; absent, the run still verifies quotes in memory but stores no snapshot the app can
open, and the engine falls back to `QUORUM_EVIDENCE_DIR` in the environment.

stdout NDJSON events (angle work namespaced by `angle_id`; synthesis uses `angle_id:"synthesis"`):
- {"type":"run_start","session_id":"qrun-<uuid>","protocol_version":4,"grounding":"captured|none"}
- {"type":"phase","phase":"planning|researching|synthesizing|grounding|validating|reconciling|done"}   // v2/v3
  transcripts may carry an `awaiting_approval` phase, which the app maps to its own waiting state; no v4 run
  emits it — the run researches on while a spawn is pending
- {"type":"plan","angles":[{"angle_id","title","prompt"}]}
- {"type":"round","round":<n>,"angles":[{"angle_id","title","prompt"}]}   // rounds ≥2: the frontier of
  objection-born questions the loop admitted. Self-reported conflicts/gaps no longer launch a round.
- {"type":"angle_status","angle_id","status":"running|complete|halted|error"}
- per-angle live: the single-topic stream_event / assistant / usage / document events, each carrying `angle_id`
- {"type":"topic_result","angle_id","role":"research|synthesis","backend":"cli|engine","provider","model","session_id","status","result":"<writeup+fenced json>","usage":{…},"note":null,"citations":[<resolved citations>],"reconciled":true}
  `reconciled` marks the ONE current answer a multi-round dive was fused into (see Reconciliation); it is
  absent on every other topic. The consumer files it as the standing answer, superseding the per-round
  sections it collapses, rather than appending another one.
- {"type":"run_result","status":"complete|inconclusive|halted","grounding":"captured|none","total_cost_usd":<n>,"topics":[<all topic_result objects>],"documents":[<the deduped run-wide registry>],"capture_failures":[{"source_id","url","stage":"write|read|index","error"}],"citation_orphans":[{"stage":"verify","claim","citation_ids":["a2c1"]}],"validation":{…}}
`backend`="cli" for claude-code (session_id = the CLI's real resumable id), "engine" for BYOK (synthetic
`qeng-<uuid>`). `status` is "complete" only when every angle completed AND the final validation round held;
a failed angle, a standing blocking objection, or a wall makes it "inconclusive" with a `note` saying which.
Run-level budget wall stops launching + winds down inconclusive/halted; SIGTERM winds
down each in-flight topic to a halted `topic_result` then a halted `run_result`. Golden run fixture:
`fixtures/run-transcript.ndjson`; the validated two-round one (verdicts, an objection-born question, the
round that settles it) is `fixtures/run-validated-transcript.ndjson`; the reconciled two-round one is
`fixtures/run-reconciled-transcript.ndjson`.

**Citation grounding (the `grounding` phase).** Two checks, both run before the synthesis `topic_result`
is emitted:

*Quotes, deterministically.* Every claimed quote is located in the stored snapshot of the source it names —
no model is asked, because a string search answers it for free and cannot be talked out of the answer. A
finding left with no resolved citation has its confidence floored to `"unverified"`; nothing is ever
dropped. Flooring only applies when the run actually captured snapshots — with no search key there is
nothing to check against, and an uncited claim is not evidence of a bad claim.

*URLs, as before.* Synthesis-cited URLs are checked against everything the angles cited (findings JSON +
prose links). Untraceable citations trigger ONE gated low-effort verify call on the synthesis model (capped
at min($0.05, remaining run budget), no tools) that corrects the findings; whatever stays untraceable is
listed in an honest `## Citation check` section appended to the synthesis writeup. The verify call streams
live under `angle_id:"verify"` like any other topic, but emits no top-level `topic_result`: it appears only
inside `run_result.topics` with `role:"verify"` so its spend is on the ledger.

*Markers across a rewrite.* A pass that rewrites cited prose is required to carry each finding's marker ids
back with it, and is handed them in its context. When one comes back without them, the link is re-attached by
matching the rewritten claim against the original — word overlap and word order, at a looser bar than a
verbatim span is held to. A marker no rewritten finding ends up carrying is reported on
`run_result.citation_orphans` (the claim it stood behind, and which ids were lost) instead of vanishing into
an unexplained confidence downgrade.

The synthesis writeup also gains a `## Sources` list (each cited document with a verification badge) and
the markdown footnote definitions for its markers (`[^c1]: [Title](url) — “quote”`), so the note still
reads as a cited document in Obsidian or on GitHub with no Quorum involved.

**Validation (the `validating` phase).** After grounding, the answer is judged by agents that did not
write it, and never edited by them: a validator files verdicts and objections, and only further research
resolves one.

*The claim sweep.* Every sentence of the writeup that leans on a marker the deterministic layer RESOLVED is
judged against exactly those located quotes — batched ≤ 10 claims per call, in parallel, tool-less,
`maxTurns:1`, low effort, capped at $0.05 per batch. A verdict is `supported`, `unsupported` (the quotes do
not entail the claim) or `misquoted` (the quote decorates a different assertion); every non-supported verdict
carries `severity` (`blocking|minor`, blocking when the judge did not say otherwise) and a one-line reason. A
run with `grounding:"none"` captured no snapshot, so it has no located quote to judge against: the sweep is
skipped and the run is reported `status:"unvalidated"` rather than passed. A claim the verifier never ruled
on is reported unjudged and files an objection instead of counting as checked.

*The critics.* Three tool-less lenses — coverage (what the question asked that the answer does not say),
conflicts (where the angles actually disagree, read from their findings JSON) and sources (which
load-bearing claims stand on one weak source) — run in parallel after the sweep, blind to each other, each
capped at 3 objections per round and $0.10. Every objection carries a severity and a CONCRETE follow-up
task; one whose follow-up names no researchable task is discarded and counted in `discarded_objections`.

Validator calls stream live under their own `angle_id` (`claim_sweep_<n>`, `critic_<lens>`) so judging the
answer is watchable rather than a gap in the run, but they emit no `topic_result` and do NOT appear in
`run_result.topics`: they researched nothing. Their spend counts toward the run budget and is reported on
`run_result.validation.spend_usd`, which the app carries into the digest's cost ledger as its own row. They
run on `validatorModel`, capped per call at $0.05 (a sweep batch) / $0.10 (a critic), `maxTurns:1`, low
effort — and out of a **validation reserve** of 15% of the run budget that the spawn/objection gate holds
back alongside the synthesis reserve, so a run can never dig itself into an answer it cannot afford to
check. Validation is
skipped, with a note, when the synthesis did not complete or the run budget is already spent. What the
readers get is a `## Validation` section appended to the synthesis writeup — the failed verdicts and the
standing objections, or one line saying the answer was checked and held. `holds` on the summary is the LAST
round's verdict on the answer, not every round's: an objection the loop researched and settled is history.

*The loop.* While blocking objections stand and the walls allow: each one becomes a `question` node with
`origin:"objection"`, admitted through the same gates as any mid-run question — the run-wide inquiry cap,
the budget headroom (with the synthesis reserve held back), the spawn freeze, and the Dice dedup, which runs
against every question already asked INCLUDING the objections earlier rounds already researched, so a
re-filed objection is drawn `rejected` rather than bought twice. No human rules on one: the person already
approved the budget and can prune on the canvas. Admitted objections become the next round's frontier
(announced as `{"type":"round"}`), the answer is redrafted from all rounds' research, and the sweep and the
critics judge the redraft. The answer HOLDS when the sweep returns no blocking non-supported verdict and
the critics file no blocking objection. The walls are `rounds` (the round cap), the run budget, and
`runDeadlineSec`; whichever stops the loop is named in `run_result.note`, with the objections still standing
reported in `validation.objections_outstanding`.

A blocking verdict from the sweep joins the loop as an objection too — naming the research task that would
settle a claim is the orchestrator's job, never the verifier's, which only ever returns a verdict.

**Reconciliation (the `reconciling` phase).** The rounds are not the answer. When the loop ran more than
one round, the run ends with ONE current answer composed by a tool-less reconciler that reads the rounds in
order — each round's findings, writeup, unresolved conflicts and gaps, and the objections its validators
left standing — and is told that a claim a later round corrected does not survive into it. It is emitted as
the terminal `topic_result` with `reconciled:true` and `role:"synthesis"` (`angle_id:"reconciliation"`),
grounded by the same deterministic quote check every synthesis gets, and carrying the final round's
`## Validation` section when anything still stands against the answer.

Nothing is fused, and the per-round answers stand as they are, when: the dive ran one round; the rounds only
restated each other (no round reported a conflict, and the final round introduced no claim an earlier round
did not already have — fusing then would be pure reformatting nobody should pay for); a topic's worth of the
run budget is no longer left; the run was cancelled; or the fuse itself came back empty or failed — a bad
fuse must never leave a worse answer than the rounds already had. A fuse that came back unusable still
appears in `run_result.topics`, so what it cost is on the ledger.

*Objections nobody asked a model for.* Two are filed deterministically against the answer, before any
validator runs: a writeup whose fenced summary will not parse (`lens:"structure"`, minor — nothing a
researcher could look up fixes it, but the run stops silently skipping its grounding), and a claim whose
markers a rewrite dropped (`lens:"claim_sweep"`, blocking — the claim is still asserted with its evidence
gone, and that IS researchable).

```json
{"validation":{"status":"validated|unvalidated","holds":true,"blocking":0,"spend_usd":0.04,
  "objections_admitted":1,"objections_resolved":1,"objections_outstanding":[<objections still standing>],
  "rounds":[{"round":1,"sweep":"run|skipped","critics":"run|skipped","claims_found":3,"claims_checked":3,
    "verdicts":[{"claim_id":"k1","claim":"…","verdict":"supported|unsupported|misquoted",
                 "severity":"blocking|minor","reason":"…"}],
    "objections":[{"lens":"coverage|conflicts|sources|claim_sweep|structure","statement":"…",
                   "severity":"blocking|minor","followup":"the concrete task that would settle it"}],
    "discarded_objections":0,"holds":true,"note":"…"}]}}
```

**Evidence (v2).** Each angle gets its own store over the shared `evidenceDir`; its citation ids are then
prefixed into run-unique `<angle_id>c<n>` form (`a2`'s `c1` becomes `a2c1`) in the ids, in the writeup's
markers and in `findings[].citations`, so ids never collide within a run. The synthesis is handed each
angle's RESOLVED citations and reuses those ids verbatim — a reused id keeps its verification instead of
being re-checked.

Captured document event (once per newly registered source, namespaced by `angle_id`):
```json
{"type":"document","angle_id":"a1","document":{
  "source_id":"s3f9a1c2","url":"https://…","title":"…","content_type":"pdf|html|text",
  "fetched_at":"2026-07-27T10:00:00.000Z","snapshot_path":"sources/s3f9a1c2.md",
  "original_path":"sources/s3f9a1c2.pdf","text_length":48213,"byte_size":1048576,
  "page_offsets":[0,1820,3944],"capture":"ok|failed|degraded"}}
```
Resolved citation, on `topic_result.citations` and each `run_result.topics[].citations`:
```json
{"id":"a2c1","source_id":"s3f9a1c2","quote":"…","start":1840,"end":1904,
 "match":"exact|normalized|fuzzy|unresolved","page":4}
```
`start`/`end` index the SNAPSHOT file and are omitted when `match` is `unresolved`. `page` comes from
`page_offsets` and is omitted when the source is not paginated.

Match ladder, best first: `exact` (indexOf hit) → `normalized` (hit after collapsing whitespace runs,
flattening smart quotes and dashes, case-folding; offsets still index the original file) → `fuzzy` (best
word-window Dice overlap ≥ 0.82 AND an LCS word-order ratio ≥ 0.6 over that window, offsets approximate) →
`unresolved` (no hit, no order, or the source has no snapshot). An `unresolved` citation is kept and rendered as "cannot verify" — doubt is surfaced as data.

Evidence on disk, under `evidenceDir` (paths in a document are relative to it):
```
documents.jsonl     one document per line, append-only; deduped by normalized url on read
sources/<id>.md     the extracted text — citation offsets index THIS file
sources/<id>.pdf    the original bytes, when the fetch produced them
```
`source_id` is derived from the normalized url (`s` + 8 hex of its sha256), not counted out: the directory
has several concurrent writers — parallel angles plus one `mcp-serve` subprocess per Claude Code angle — and
a counter would hand the same `s3` to two different urls, which would silently point a citation at the wrong
snapshot. Deriving it makes dedupe-by-url and dedupe-by-id the same thing, with no coordination.

`page_offsets` is filled only when the extracted text actually carries page separators (a form feed, or a
`--- page N ---` / `[Page N]` line). Otherwise it is `[]` — never guessed; the reader falls back to PDFKit's
own text search for the visual highlight.

**Grounding tier (v3).** `run_start.grounding` and `run_result.grounding` declare up front what the run can
promise. `"captured"` means own-search is configured and fetches leave snapshots a quote can be checked
against; `"none"` means there is no search key, so angles read through the CLI's built-in web search, which
returns content to the model and keeps nothing. A `"none"` run renders no verified-style badge or chip
anywhere and carries an "unvalidated — no evidence was captured" notice into its synthesis.

**Capture outcome (v3).** `document.capture` says what the run kept: `ok`, `degraded` (the text is
`stripHtml` tag soup from the fallback extractor, not a reader extraction — quotes will rarely locate in
it), or `failed` (the snapshot could not be written, or cannot be read back). `run_result.capture_failures`
lists what went wrong and where, so an unresolvable citation has a stated reason instead of an inferred one.

**Read parity (v3).** `web_fetch` returns at most 12 000 characters per call, plus `offset`, `total_chars`
and — while there is more — `next_offset`. Calling again with that offset continues through the snapshot
already on disk: no second network fetch, no second snapshot, no second `document` event, and the citation
offsets keep indexing the one stored copy. Without it a claim could only ever cite a long source's head, and
its tail would be unfalsifiable.

Capture is best-effort by design: the own-search MCP (`web_search`/`web_fetch`) returns document text to us,
so it works on the BYOK loop AND the Claude Code backend, which fetches through `mcp-serve` — that
subprocess reads `QUORUM_EVIDENCE_DIR` (the engine puts it in the CLI's environment) and appends there, and
the engine loads what it wrote once the angle finishes. Anthropic's built-in `WebSearch`/`WebFetch` return
content only to the model, so with no search key configured there are no snapshots and citations stay
URL-only and honestly unverifiable. URLs seen only in search results register with no snapshot for the same
reason.

**Version handshake.** The consumer must read `run_start.protocol_version` and refuse a version above
the one it was built against (a missing version is tolerated). The app enforces this via
`RunStreamParser.supportedProtocolVersion` — bump both sides in lockstep. Every version is additive, so a
v2 or v3 transcript still renders: it simply carries no verdicts, no `judges` edges and no
`run_result.validation`, and a run with none of those is reported as never validated rather than as passed.

## The research graph (v3, verdicts in v4)

The run's shape is state, not code. One graph, owned by the orchestrator, emitted as deltas: **only the
orchestrator creates nodes** — an agent may ask for one, never declare one — so what the app draws is what
actually happened rather than a model's account of it.

```json
{"type":"graph_node","node":{"id":"q1","kind":"question|inquiry|source|finding|conflict|gap|synthesis|verification|verdict",
  "title":"…","parent_ids":["a1"],"depth":2,"round":1,
  "status":"pending|approved|rejected|expired | queued|running|complete|halted|error | pass|objections(<n>)|skipped",
  "origin":"root|planner|followup|spawn|dig|objection|derived",
  "meta":{"why":"…","provoked_by":"s3f9a1c2","est_cost_usd":2.5,"rejected_reason":"…","cost_usd":0.42,
          "lens":"coverage","objections":[{"lens","statement","severity","followup"}]}}}
{"type":"graph_edge","edge":{"from":"a1","to":"q1","kind":"decomposes|spawned|reports|cites|corroborates|contradicts|surfaces|resolves|synthesizes|verifies|judges","label":"…"}}
{"type":"graph_node_update","id":"a1","status":"complete","meta":{"cost_usd":0.42}}
```

A `question` node's status is its admission lifecycle; an `inquiry`'s is its work lifecycle; a `verdict`'s
is what it made of the answer. They are read from the same field but never mean the same thing, so the
consumer branches on `kind`.

**The answer and its verdicts (v4).** The synthesis is a `synthesis` node (`id:"synthesis"`, one per run —
a later round redrafts the same answer rather than writing a second one) that each research inquiry
`synthesizes` into. Every validator task then gets one `verdict` node per round — `v<round>_claim_sweep`,
`v<round>_coverage`, `v<round>_conflicts`, `v<round>_sources`, plus `v<round>_structure` when the
deterministic layer filed something — carrying `meta.objections` (what it filed, verbatim) and pointing at
the answer it read through a `judges` edge. A task that could not run is `skipped`, never `pass`. The
questions those objections become arrive as ordinary `graph_node`s with `origin:"objection"`, so the loop's
shape IS the graph. `judges`, like `corroborates` and `verifies`, points from the judgement back at what it
judged — a consumer walking parents must not follow it downward.

Source, finding, conflict and gap nodes are **derived by the consumer** from the `document` events and
fenced JSON already on the wire — re-transmitting them would create two accounts that can disagree.

## Spawning (v3)

A research angle gets one extra tool:

```
spawn_inquiry({question, why, provoked_by}) → {verdict: "pending"|"approved"|"rejected", reason?, inquiry_id?, est_cost_usd?}
```

It executes nothing and returns at once — the run rules on it and schedules it; the angle carries on
without the answer. `provoked_by` (a `source_id` or a finding) is required: a question that cannot name
what raised it is the vague spawn that wastes a run.

**Stage 1 — machine gates**, all checked before a node exists, each producing a drawn `rejected` node
carrying its reason rather than a silent refusal: depth ≤ 3 (L0 root, **L1 the approved angles**, so
spawning gets two generations) · at most 2 children per inquiry · token-set Dice dedup against every
question already asked · a run-wide cap of 12 inquiries counting approved angles and anything still
pending · past the spawn freeze (70% of `runDeadlineSec`) · a missing `provoked_by`.

**Budget.** Gating reads **actual spend**, not reserved ceilings — reserving N angle ceilings plus a
synthesis commits the whole run budget before the first angle starts, so a gate reading reservations would
refuse every spawn forever. A child's ceiling decays with depth (`perTopicBudgetUSD × 0.5^(depth-1)`), and
pending ceilings count as committed so the gate never offers what it could not fund.

**Stage 2 — the human**, in the default `ask` mode. Survivors are emitted as `pending` question nodes.
`auto` applies stage 1 only; `off` withholds the tool entirely.

**Controls travel back on stdin**, which now stays open for the run's duration: the config arrives first
(found by structure, so it may span lines) and one control per line follows:

```json
{"type":"approve","id":"x1","verdict":"approved"}
{"type":"prune","id":"q1"}
{"type":"retry","id":"a1"}
```

`id` is either the offer's `inquiry_id` — what `spawn_inquiry` returned to the angle — or the id of the
`pending` question node it was drawn as (`q1`). The canvas only ever shows the latter, so both are taken;
they name one offer. A verdict is answered with a `graph_node_update` on the QUESTION node, approved or
rejected, so the canvas stops offering a question that has been ruled on. A control naming something the run
does not have yet — a verdict that raced the offer it answers, a retry of an angle still running — is HELD
and tried again on the next drain rather than dropped.

`prune` withdraws an offer the run has not spent anything on: the question is drawn `rejected` and never
becomes work. `retry` puts an inquiry the run already finished back into the wave, at most once per id and
only while a wave is still running — neither command can un-spend work already paid for, and neither
pretends to.

**A pending offer never costs the run time.** It sits OUTSIDE the frontier: the wave carries on, and each
time an angle finishes the run reads whatever verdicts have arrived and admits the approved ones into the
wave that is still running. An offer expires — drawn as expired, not refused, because the run declined to
wait rather than the user declining the question — at the spawn freeze, at `approvalWindowSec` after it was
filed, or when the run ends. A run whose user walked away researches, synthesizes, and finishes on time.

**The frontier replaces rounds.** Planned angles and approved spawns run through one queue; the run
synthesizes when the frontier is dry. What refills it for a next round is the validator loop below — never
the synthesis's own account of its conflicts and gaps.

**The Claude Code backend files instead of calling.** Its `mcp-serve` child is a separate process, so its
`spawn_inquiry` appends to `<spawnDir>/spawn-requests.jsonl` (one JSON object per line, `request_id`,
`angle_id`, `question`, `why`, `provoked_by`, `origin`) and the engine rules on them once the angle
finishes — the same route captured evidence takes. `origin:"dig"` marks a question the user raised from a
node on the canvas: it passes every gate but needs no approval, because the person who would approve it
asked for it.

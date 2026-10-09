# Quorum engine NDJSON protocol
Every stdout line is one JSON object (NDJSON), consumable UNCHANGED by the Swift ResearchOutputParser.

Fields the Swift parser reads (do not rename): `type`, `total_cost_usd` (cumulative, monotonic),
`session_id`, `result`, `message.content[]` with `{type:"text"|"thinking"|"tool_use", text, thinking, name, input}`,
`input.{query|url|prompt|file_path|pattern}`, `delta.{type,text,thinking}` (type ∈ {text_delta, thinking_delta}),
also nested as `event.delta`.

Event lines in order:
1. Handshake (FIRST line): {"type":"system","subtype":"init","engine":"quorum-engine","engine_version":"0.1.0","protocol_version":5,"session_id":"<uuid>","model":"deepseek/deepseek-chat"}
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

## Commands (protocol v5)

Every command is JSON in, JSON out, and none keeps a control channel open: the run reads its config and nothing after it.

| Command | Input | Output |
|---|---|---|
| `version` | none | one handshake line (below) |
| `doctor [--json] [--store DIR]` | none | `{ok, checks:[{id, ok, detail, fix}]}`, or one line per check; exit 1 when a check fails |
| `scope` | stdin `{question, answers?, parent_run_id?}` | `{needs_scoping:false, brief:{question, language, title}}`. A stub until M7: it never asks anything |
| `run [--store DIR] [--detach]` | stdin: the run config | attached: the NDJSON stream below. `--detach`: one `run.created` line, then the engine exits and the run goes on |
| `cancel RUN_ID [--store DIR]` | none | `{ok:true, run_id, signalled:"group"\|"process"\|"none"}` or `{ok:false, run_id, error}` (exit 1) |
| `list [--store DIR]` | none | one `{type:"run", question_id, run_id, dir, title, status, created_at, updated_at, finished_at?, pid?, heartbeat_at?, cost_usd}` line per run, newest first |
| `check <run-dir> [--json]` | none | the integrity report (below) |
| `export --md <run-dir> [--out FILE]` | none | markdown |
| `migrate [--store DIR]` | none | `{scanned, current, upgraded:[{kind, id, from, to}], unknown:[{kind, id, schema}], unreadable:[{path, problem}]}` |
| `mcp-serve` | internal | the tool server the CLI angles use (`web_fetch`, and `web_search` when a search key exists) |

`--store` defaults to `~/Quorum`. `doctor` checks, in order: `claude_cli` (found, with its version), `claude_login`
(`claude auth status`; a login that cannot be confirmed passes with a note), `fetch` (a HEAD against
`QUORUM_DOCTOR_FETCH_URL`, default `https://example.com/`), `store` (writable), `migrate` (records waiting for an
upgrade) and `rate_limit` (reported as not tracked yet). A failing check carries its `fix`.

`migrate` walks a table of record-schema upgrades (`src/migrate.ts`, empty while `quorum.run/1` and
`quorum.question/1` are the only schemas): a record under an older schema is upgraded in place, one under a newer
schema is reported and left alone. It never imports the legacy runs of the pre-record app.

`list` also settles liveness. A run whose record says `running`, whose last heartbeat is more than 30 s old and
whose pid is gone is `crashed`; so is one whose heartbeat stopped more than 10 minutes ago whatever the pid says
(it may belong to another process by now). `list` writes that into `run.json` (status `crashed`, a note, the
unfinished tasks `halted`), so every reader agrees. A record from before heartbeats counts its `updated_at` as its
heartbeat.

`cancel` signals the run's process group (`SIGTERM` to `-pid`), which reaches the CLI children that share it, and
falls back to the process alone for an attached run, whose engine leads no group. The engine winds down to a
`halted` record. If the record says `running` but its process is gone, `cancel` marks it `cancelled` itself.

## Detached runs (M6)

`run --detach --store DIR` reads the config, allocates the question and run ids, and starts the engine again in its
own session (`detached: true`, so it leads its own process group) with the config on its stdin, the ids in the
config and its stderr in `<run dir>/engine.stderr.log`. Once the run's `run.json` exists it prints

```json
{"type":"run.created","protocol_version":5,"question_id":"<ULID>","run_id":"<ULID>","dir":"<run dir>","pid":4242}
```

and exits. If the child dies first, or no record appears within 15 s, it prints `{"type":"error","error":"…"}` and
exits 1. The run then outlives its caller: the app can quit, crash or be rebuilt. The caller follows it by reading
`<run dir>/run.json` (the truth) and tailing `<run dir>/events.ndjson` (every line the stream would have carried).
Re-attaching is the same read from the top of the log. `--replay <fixture>` is passed through to the child.

The engine keeps the Mac awake for as long as it runs (`caffeinate -i -w <pid>`, macOS only), which replaces the
power assertion the app used to hold.

## Liveness

`run.json` is the truth; these events only let a watcher feel the run move.

- `{"type":"run.progress","stage":"research|draft|check|answer","stage_index":2,"stage_count":5,"tasks_done","tasks_total","sources_read","eta_s"?}`
  The UX proposal's five stages, with Scope as the composer's step 1: `planning` and `researching` are stage 2,
  `synthesizing` is 3, `grounding`, `validating` and `reconciling` are 4, `done` is 5. Emitted on every phase
  change, every finished research task and every heartbeat, so at least every 5 s. `eta_s` is absent: it needs
  durations from past runs, which no tier records yet.
- `{"type":"heartbeat","pid":4242}` every 5 s while the run is hosted by a process. The record keeps the latest as
  `pipeline.heartbeat_at`, and `run_start` carries the same `pid` (kept as `pipeline.pid`).

A run that is driven without a hosting process (a unit test) emits neither `pid` nor heartbeats.

## version command (the app's handshake)
`quorum-engine version` prints ONE line and exits, spending nothing:
{"type":"version","engine":"quorum-engine","engine_version":"0.1.0","protocol_version":5,"record_schema":"quorum.run/1","build":"<git sha>[-dirty]|source"}
The app probes every candidate in a fixed order (QUORUM_ENGINE_BIN → in a checkout, `bun engine/src/index.ts` →
bundle Resources → `engine/dist/quorum-engine`) and takes the first whose `protocol_version` equals the one it reads;
anything else is rejected with the reason recorded. A binary older than this command answers in research mode
instead, and its `system/init` line still carries `protocol_version`, so a stale build is named rather than run. A
run that finds no usable engine is refused: the app runs nothing, says why, and its Doctor view lists every
candidate and its verdict. `record_schema` names the run record this engine writes; the app also refuses a
candidate whose record schema it does not read. A run records `pipeline.engine_version`, `build` and `protocol` in
its `run.json`. `build` is stamped by `scripts/bundle-engine.sh` (`source` when run from source).


## run command (fan-out orchestration in the engine)

`quorum-engine run` reads ONE JSON config object on **stdin** (NO secrets — keys stay in env) and runs
the whole fan-out: plan → parallel angles → synthesis → citation grounding → validation → (for a dive that
ran more than one round) reconciliation into one current answer. Each role runs on the config's model — `"claude-code[/alias]"` spawns the `claude` CLI
(subscription OAuth stays inside the CLI; the engine never reads the token), any `"provider/model-id"`
runs the AI-SDK BYOK loop. Own-search MCP is wired to claude when a search key is in env.

stdin config: `{ question, angleCount, angles?, angleModel, synthesisModel, validatorModel?, effort, perTopicBudgetUSD,
runBudgetUSD, perTopicTimeoutSec, priorNotesExcerpt, template, rounds, angleConcurrency?, useProjectContext,
projectDir, evidenceDir, brainDir?, runDir?, runDeadlineSec?, questionId?, runId? }`. The config is the ONLY thing read from
stdin: the engine takes the first complete JSON value, and nothing is read after it, so a caller may close the pipe.
`--store DIR` overrides `brainDir`. `questionId` and `runId` are the ids a detaching parent allocated. `rounds` is the
validator loop's ROUND CAP (default 4), not a round count: a round past the first runs only while blocking
objections stand. `angleConcurrency` (default 4) is how many angles may be in flight at once — each is a
model loop with an `mcp-serve` child, so a wide frontier is worked a few at a time. `validatorModel` (default: the synthesis model) is who judges the answer — cheap, tool-less, and routed by the
app to a different family than the one that drafted it, or to the CLI's small model when there is no key.
`angles` (optional `[{title,prompt}]`) are caller-supplied round-1 angles —
when present the engine SKIPS its own round-1 planning and uses them verbatim (still emitting `plan`); the app sends none. `evidenceDir` (v2) is where captured sources are written — usually
`<runDir>/evidence`; absent, the run still verifies quotes in memory but stores no snapshot the app can
open, and the engine falls back to `QUORUM_EVIDENCE_DIR` in the environment. `runDir` (optional) is the run's
directory: the engine keeps every line it emits in `<runDir>/events.ndjson`, and `evidenceDir` defaults to
`<runDir>/evidence`, so `quorum-engine check <runDir>` can audit the run afterwards. `brainDir` (M4, what the app
sends) is the user's brain folder: the engine allocates a question id and a run id (ULIDs) and lays the run out as
`<brainDir>/questions/<question_id>/question.json` plus `runs/<run_id>/` (`run.json`, `events.ndjson`, `evidence/`,
`transcripts/<task>.ndjson`), and on finish writes the markdown export to `<brainDir>/answers/<slug>-<id tail>.md`.
`brainDir` wins over `runDir`. See "The run record" below.

stdout NDJSON events (angle work namespaced by `angle_id`; synthesis uses `angle_id:"synthesis"`):
- {"type":"run_start","session_id":"qrun-<uuid>","protocol_version":5,"engine_version","build","grounding":"captured|none","pid"?,"run_id"?,"question_id"?,"run_dir"?}
  `run_id`, `question_id` and `run_dir` are present whenever the run keeps a directory (`brainDir` or `runDir`);
  `run_dir` is where its `run.json` is.
- {"type":"phase","phase":"planning|researching|synthesizing|grounding|validating|reconciling|done"}   // v2/v3
- {"type":"run.progress",…} and {"type":"heartbeat","pid"} — see Liveness
- {"type":"plan","angles":[{"angle_id","title","prompt"}]}
- {"type":"round","round":<n>,"angles":[{"angle_id","title","prompt"}]}   // rounds ≥2: the frontier of
  objection-born questions the loop admitted. Self-reported conflicts/gaps no longer launch a round.
- {"type":"angle_status","angle_id","status":"running|complete|halted|error"}
- per-angle live: the single-topic stream_event / assistant / usage / document events, each carrying `angle_id`
- {"type":"topic_result","angle_id","role":"research|synthesis","backend":"cli|engine","provider","model","session_id","status","result":"<writeup+fenced json>","usage":{…},"note":null,"citations":[<resolved citations>],"reconciled":true}
  `reconciled` marks the ONE current answer a multi-round dive was fused into (see Reconciliation); it is
  absent on every other topic. The consumer files it as the standing answer, superseding the per-round
  sections it collapses, rather than appending another one.
- {"type":"run_result","status":"complete|inconclusive|halted","grounding":"captured|none","total_cost_usd":<n>,"topics":[<all topic_result objects>],"documents":[<the deduped run-wide registry>],"capture_failures":[{"source_id","url","stage":"write|read|index","error"}],"citation_orphans":[{"stage":"verify","claim","citation_ids":["a2c1"]}],"stripped_markers":[{"angle_id","marker"}],"validation":{…},"refusal":{"kind":"not_logged_in","reason"},"checks":{"ok","failed","warnings","results":[{"id","name","status":"pass|fail|warn","detail"}]}}
`refusal` is present when the run stopped because the engine would not go on — today only a Claude CLI that is
not logged in — and the process then exits 3. `checks` is `quorum-engine check` evaluated over the run's own
events, evidence and record the moment before it finished. `stripped_markers` lists every `[^id]` a topic wrote
with no citation behind it: at grounding, a marker the run already verified elsewhere (an angle's `a2c3` reused by
the synthesis) is resolved into that topic's citations, and any other is stripped from the prose and from the
findings, then listed here so `check` flags it (`markers` and `references` warn) instead of shipping a dangling
footnote.
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
effort — and out of a **validation reserve** of 15% of the run budget that the admission gate holds
back alongside the synthesis reserve, so a run can never dig itself into an answer it cannot afford to
check. Validation is
skipped, with a note, when the synthesis did not complete or the run budget is already spent. What the
readers get is a `## Validation` section appended to the synthesis writeup — the failed verdicts and the
standing objections, or one line saying the answer was checked and held. `holds` on the summary is the LAST
round's verdict on the answer, not every round's: an objection the loop researched and settled is history.

*The loop.* While blocking objections stand and the walls allow: each one becomes a `question` node with
`origin:"objection"`, admitted through the admission gate — the run-wide inquiry cap,
the budget headroom (with the synthesis reserve held back), the freeze, and the Dice dedup, which runs
against every question already asked INCLUDING the objections earlier rounds already researched, so a
re-filed objection is drawn `rejected` rather than bought twice. No human rules on one: nothing asks a person mid-run. Admitted objections become the next round's frontier
(announced as `{"type":"round"}`), the answer is redrafted from all rounds' research, and the sweep and the
critics judge the redraft. The answer HOLDS when the sweep returns no blocking non-supported verdict and
the critics file no blocking objection. The walls are `rounds` (the round cap), the run budget, and
`runDeadlineSec`; whichever stops the loop is named in `run_result.note`, with the objections still standing
reported in `validation.objections_outstanding` and the quotes still failing their claim in
`validation.unsupported_citations` — the LAST round's, since a claim a later round rewrote is history. Those
ids are what the reader draws as `⚠` rather than as verified: located, but not carrying the sentence.

A blocking verdict from the sweep joins the loop as an objection too — naming the research task that would
settle a claim is the orchestrator's job, never the verifier's, which only ever returns a verdict.

A `conflict` the synthesis reported buys a round on the same terms, under the `conflicts` lens: the answer
naming two sources that cannot both be right has named the one thing another round could settle, and a run
that stops there leaves a primary lookup undone. It never counts against `holds` — reporting a conflict is
the answer being honest, not the answer being wrong — so it decides only whether there is research left
worth doing.

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
  "unsupported_citations":["a2c1"],
  "rounds":[{"round":1,"sweep":"run|skipped","critics":"run|skipped","claims_found":3,"claims_checked":3,
    "verdicts":[{"claim_id":"k1","claim":"…","verdict":"supported|unsupported|misquoted",
                 "severity":"blocking|minor","reason":"…","citation_ids":["a2c1"]}],
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

**Version handshake.** The consumer must read `run_start.protocol_version` and refuse any version but the one it
was built against, a missing version included: there is no "older is tolerated". The app enforces this via
`RunStreamParser.supportedProtocolVersion` — bump both sides in lockstep. v5 deleted the stdin control channel,
`spawn_inquiry` and the spawn log, so a v4 engine and a v5 app (or the reverse) cannot talk.

## The research graph (v3, verdicts in v4)

The run's shape is state, not code. One graph, owned by the orchestrator, emitted as deltas: **only the
orchestrator creates nodes** — an agent may ask for one, never declare one — so what the app draws is what
actually happened rather than a model's account of it.

```json
{"type":"graph_node","node":{"id":"q1","kind":"question|inquiry|source|finding|conflict|gap|synthesis|verification|verdict",
  "title":"…","parent_ids":["a1"],"depth":2,"round":1,
  "status":"approved|rejected | queued|running|complete|halted|error | pass|objections(<n>)|skipped",
  "origin":"root|planner|followup|objection|derived",
  "meta":{"why":"…","provoked_by":"coverage","est_cost_usd":2.5,"rejected_reason":"…","cost_usd":0.42,
          "lens":"coverage","objections":[{"lens","statement","severity","followup"}]}}}
{"type":"graph_edge","edge":{"from":"a1","to":"q1","kind":"decomposes|spawned|reports|cites|corroborates|contradicts|surfaces|resolves|synthesizes|verifies|judges","label":"…"}}
{"type":"graph_node_update","id":"a1","status":"complete","meta":{"cost_usd":0.42}}
```

A `question` node's status is its admission ruling (`approved`, or `rejected` with `meta.rejected_reason`); an `inquiry`'s is its work lifecycle; a `verdict`'s
is what it made of the answer. They are read from the same field but never mean the same thing, so the
consumer branches on `kind`.

**The answer and its verdicts (v4).** The synthesis is a `synthesis` node (`id:"synthesis"`, one per run —
a later round redrafts the same answer rather than writing a second one) that each research inquiry
`synthesizes` into. Every validator task then gets one `verdict` node per round — `v<round>_claim_sweep`,
`v<round>_coverage`, `v<round>_conflicts`, `v<round>_sources`, plus `v<round>_structure` when the
deterministic layer filed something — carrying `meta.objections` (what it filed, verbatim) and pointing at
the answer it read through a `judges` edge. A task that could not run is `skipped`, never `pass`. The
questions those objections become arrive as ordinary `graph_node`s with `origin:"objection"`, parented to
the verdict that filed them (`spawned`, labelled with the lens) and decomposing into the next round's
inquiry — so the loop's shape IS the graph: verdict → question → the round it bought. `judges`, like
`corroborates` and `verifies`, points from the judgement back at what it judged — a consumer walking
parents must not follow it downward.

Source, finding, conflict and gap nodes are **derived by the consumer** from the `document` events and
fenced JSON already on the wire — re-transmitting them would create two accounts that can disagree.

## Admission of follow-ups (v5)

Nothing in a run raises a question of its own and nothing asks a person to rule on one: v5 deleted `spawn_inquiry`,
the approve/prune/retry controls, the pending and expired states and the spawn log. What is left of the old gate is
`AdmissionGate` (`src/admission.ts`), which rules, with no human in the loop, on the follow-ups the validators file
against a draft (an objection's `followup`). A follow-up is drawn as a `question` node whose status is `approved` or
`rejected` with its reason. The gates:

- depth at most 3 (L0 the question, L1 the planned angles)
- at most 12 inquiries per run
- token-set Dice dedup against every question already asked
- budget headroom: a child's ceiling decays with depth (`perTopicBudgetUSD × 0.5^(depth-1)`) and must fit in the
  run budget less the synthesis reserve, the validation reserve (15%) and what has actually been spent
- past the freeze (70% of `runDeadlineSec`) nothing more is admitted

**The frontier replaces rounds.** Planned angles and admitted follow-ups run through one queue; the run
synthesizes when the frontier is dry. What refills it for a next round is the validator loop — never the
synthesis's own account of its conflicts and gaps.

## planning (the engine owns the whole run)
When the `run` config carries no `angles`, the engine plans them itself: one tool-less model call (role `plan`,
topic id `planning`, on the angle model) decomposes the question into `angleCount` self-contained angles in the
question's language. Its stream is attributed to `angle_id: "planning"`, its cost counts against the run, and an
unusable plan emits an `error` line and falls back to generic facets of the question.

## run --replay <fixture> (dev/demo)
`quorum-engine run --replay <fixture.ndjson> [--replay-delay-ms N]` reads the usual stdin config, then streams the
recorded run line by line (default 140 ms apart) instead of researching, and copies the snapshots in
`<fixture>.sources/` into `<evidenceDir>/sources/` without overwriting. It spends nothing and needs no keys. Given
a `brainDir`, a replay lays out and writes the run record exactly as a live run does, and adds `run_id`,
`question_id`, `run_dir` and its `pid` to the recorded `run_start` (taking the ids from `questionId` and `runId`
when a detaching parent allocated them). It beats like a real run, so `list`, `cancel` and the app treat it as one.

## The run record (M4, `quorum.run/1`)

The engine is the only writer of a run. `run.json` is rewritten atomically (temp file + rename) on every
structural event — `run_start`, phases, the plan, rounds, statuses, documents, graph changes, every
`topic_result` — and a last time after `run_result`, so a reader always finds a whole record, `status:"running"`
until the run reports. It is a fold of the event stream (`src/record/build.ts`), so the same events always give
the same record. The Zod source is `src/record/schema.ts`; `bun run schema` writes `schema/run.schema.json`,
`schema/question.schema.json` and the Swift envelope types in `Sources/QuorumCore/RunRecord.generated.swift`, and a
test fails while any of them is stale.

- `pipeline.pid` and `pipeline.heartbeat_at` are the hosting process and the time of its last heartbeat (v5);
  both are absent on a record from before them or from a run with no hosting process.
- `answer` is `{format:"markdown", task_id, headline, markdown}`: the answering task's writeup with the fenced
  summary, the stream-only appendices (`## Sources`, `## Citation check`, `## Validation`, the unvalidated notice)
  and leading process narration removed. M5 replaces it with the QVS spec.
- `claims` are the answer's sentences that carry a marker, each with the claim sweep's verdict (or `unjudged`),
  `strength` (`solid` = supported AND two independent sources or one primary source) and a `confidence` derived
  from both. Each task keeps its own structured `findings`.
- `stats` is computed once, by the engine, from the arrays in the record (`src/record/stats.ts`), and `check`
  recomputes it. Every count a surface shows is read from it: `sources_read` (distinct documents with captured
  text), `sources_cited` (distinct sources behind a located citation the answer uses), `sources_by_type` /
  `cited_by_type` (M1's `source_type`), claims by strength and verdict, open conflicts, gaps and objections,
  stripped markers, tasks and failed tasks, rounds, `cost_usd`, `duration_s` and `trust_level`
  (`unchecked` when nothing was captured or judged; `shaky` when the answer does not hold or under 40% of its
  claims are solid; `solid` at 70% or more with every claim judged; `moderate` otherwise).
- `checks` is the same report `run_result.checks` carries.

## export command

`quorum-engine export --md <run-dir> [--out <file.md>]` prints the run as self-contained markdown (or writes it to
`--out`): frontmatter from the question, the brief and `stats`; the lead; the answer; open items (conflicts with
both sides, standing objections, gaps, tasks that did not finish); the cited sources with their type and match
badge; and one footnote definition for every marker it keeps. A marker that names no citation is dropped rather
than left undefined. It is a pure function of `run.json` plus `question.json`, golden-tested
(`fixtures/record/mock-run.md`).

## check command

`quorum-engine check <run-dir> [--json]` audits a finished run from `<run-dir>/run.json`, the `question.json` two
levels up, `<run-dir>/events.ndjson` and `<run-dir>/evidence/`, spends nothing, and exits 1 when any check fails.
Checks over the stream: `stamp` (build stamp present, protocol current), `stream` (begins `run_start`, ends one `run_result`,
no unreadable lines), `markers` (every `[^id]` and every finding citation names a declared citation),
`sources` (every citation's source was captured, with a snapshot or a recorded failure), `spans` (resolved
spans lie inside their snapshots, and an exact match's quote is at its span), `snapshots` (files exist and
match the index), `counts` (stream and evidence index agree on documents and fetch failures, total cost covers
its topics), `verdicts` (every claim has a verdict or is reported unjudged, a finished answer was validated),
`grounding` (captured, or the failures explain why not), `refusal` (a refused run is never complete).
`spans` and `snapshots` warn, rather than pass, when the run kept no evidence directory; `markers` warns when the
engine stripped a dangling marker. Checks over the record (M4): `record` (fails when there is no `run.json`),
`schema` (`run.json` and `question.json` validate), `stats` (the stored `stats` and every source's `cited` flag
recompute from the arrays), `references` (every marker in the answer and the task writeups, every claim and finding
citation, every citation's source and every open item resolve; warns on stripped markers), `answer` (a complete
run holds an answer from a completed task), `title` (the question's title is not a clarifier, an apology or a
question; warns with no `question.json`), `language` (warns when the answer reads in another language than the
question) and `limits` (warns over the cost cap or the deadline). With `--json` the report is one line, with a
`run` summary (build, status, cost, snapshots, claims checked, trust level, sources cited and read, stripped markers).

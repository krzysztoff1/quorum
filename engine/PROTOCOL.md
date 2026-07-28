# Quorum engine NDJSON protocol
Every stdout line is one JSON object (NDJSON), consumable UNCHANGED by the Swift ResearchOutputParser.

Fields the Swift parser reads (do not rename): `type`, `total_cost_usd` (cumulative, monotonic),
`session_id`, `result`, `message.content[]` with `{type:"text"|"thinking"|"tool_use", text, thinking, name, input}`,
`input.{query|url|prompt|file_path|pattern}`, `delta.{type,text,thinking}` (type ∈ {text_delta, thinking_delta}),
also nested as `event.delta`.

Event lines in order:
1. Handshake (FIRST line): {"type":"system","subtype":"init","engine":"quorum-engine","engine_version":"0.1.0","protocol_version":2,"session_id":"<uuid>","model":"deepseek/deepseek-chat"}
2. Text/thinking deltas: {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}} (and thinking_delta)
3. Tool use (sources): {"type":"assistant","message":{"content":[{"type":"tool_use","name":"web_search","input":{"query":"..."}}]}} and name "web_fetch" with input {"url":"..."}
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
the whole fan-out: plan → parallel angles → synthesis → citation grounding → optional autoresearch
rounds. Each role runs on the config's model — `"claude-code[/alias]"` spawns the `claude` CLI
(subscription OAuth stays inside the CLI; the engine never reads the token), any `"provider/model-id"`
runs the AI-SDK BYOK loop. Own-search MCP is wired to claude when a search key is in env.

stdin config: `{ question, angleCount, angles?, angleModel, synthesisModel, effort, perTopicBudgetUSD,
runBudgetUSD, perTopicTimeoutSec, priorNotesExcerpt, template, rounds, autoresearch, useProjectContext,
projectDir, evidenceDir }`. `angles` (optional `[{title,prompt}]`) are user-pre-approved round-1 angles —
when present the engine SKIPS its own round-1 planning and uses them verbatim (still emitting `plan`, still
planning rounds ≥2 for autoresearch). `evidenceDir` (v2) is where captured sources are written — usually
`<runDir>/evidence`; absent, the run still verifies quotes in memory but stores no snapshot the app can
open, and the engine falls back to `QUORUM_EVIDENCE_DIR` in the environment.

stdout NDJSON events (angle work namespaced by `angle_id`; synthesis uses `angle_id:"synthesis"`):
- {"type":"run_start","session_id":"qrun-<uuid>","protocol_version":2}
- {"type":"phase","phase":"planning|researching|synthesizing|grounding|reconciling|done"}
- {"type":"plan","angles":[{"angle_id","title","prompt"}]}
- {"type":"round","round":<n>,"angles":[{"angle_id","title"}]}   // autoresearch rounds ≥2
- {"type":"angle_status","angle_id","status":"running|complete|halted|error"}
- per-angle live: the single-topic stream_event / assistant / usage / document events, each carrying `angle_id`
- {"type":"topic_result","angle_id","role":"research|synthesis","backend":"cli|engine","provider","model","session_id","status","result":"<writeup+fenced json>","usage":{…},"note":null,"citations":[<resolved citations>]}
- {"type":"run_result","status":"complete|inconclusive|halted","total_cost_usd":<n>,"topics":[<all topic_result objects>],"documents":[<the deduped run-wide registry>]}
`backend`="cli" for claude-code (session_id = the CLI's real resumable id), "engine" for BYOK (synthetic
`qeng-<uuid>`). Run-level budget wall stops launching + winds down inconclusive/halted; SIGTERM winds
down each in-flight topic to a halted `topic_result` then a halted `run_result`. Golden run fixture:
`fixtures/run-transcript.ndjson`.

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
listed in an honest `## Citation check` section appended to the synthesis writeup. The verify call emits NO
top-level `topic_result` and no live events — it appears only inside `run_result.topics` with
`role:"verify"` so its spend is on the ledger.

The synthesis writeup also gains a `## Sources` list (each cited document with a verification badge) and
the markdown footnote definitions for its markers (`[^c1]: [Title](url) — “quote”`), so the note still
reads as a cited document in Obsidian or on GitHub with no Quorum involved.

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
  "page_offsets":[0,1820,3944]}}
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
word-window Dice overlap ≥ 0.82, offsets approximate) → `unresolved` (no hit, or the source has no
snapshot). An `unresolved` citation is kept and rendered as "cannot verify" — doubt is surfaced as data.

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

Capture is best-effort by design: the own-search MCP (`web_search`/`web_fetch`) returns document text to us,
so it works on the BYOK loop AND the Claude Code backend, which fetches through `mcp-serve` — that
subprocess reads `QUORUM_EVIDENCE_DIR` (the engine puts it in the CLI's environment) and appends there, and
the engine loads what it wrote once the angle finishes. Anthropic's built-in `WebSearch`/`WebFetch` return
content only to the model, so with no search key configured there are no snapshots and citations stay
URL-only and honestly unverifiable. URLs seen only in search results register with no snapshot for the same
reason.

**Version handshake.** The consumer must read `run_start.protocol_version` and refuse a version above
the one it was built against (a missing version is tolerated). The app enforces this via
`RunStreamParser.supportedProtocolVersion` — bump both sides in lockstep.

# Quorum engine NDJSON protocol
Every stdout line is one JSON object (NDJSON), consumable UNCHANGED by the Swift ResearchOutputParser.

Fields the Swift parser reads (do not rename): `type`, `total_cost_usd` (cumulative, monotonic),
`session_id`, `result`, `message.content[]` with `{type:"text"|"thinking"|"tool_use", text, thinking, name, input}`,
`input.{query|url|prompt|file_path|pattern}`, `delta.{type,text,thinking}` (type ∈ {text_delta, thinking_delta}),
also nested as `event.delta`.

Event lines in order:
1. Handshake (FIRST line): {"type":"system","subtype":"init","engine":"quorum-engine","engine_version":"0.1.0","protocol_version":1,"session_id":"<uuid>","model":"deepseek/deepseek-chat"}
2. Text/thinking deltas: {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}} (and thinking_delta)
3. Tool use (sources): {"type":"assistant","message":{"content":[{"type":"tool_use","name":"web_search","input":{"query":"..."}}]}} and name "web_fetch" with input {"url":"..."}
4. Per-step usage (one per model call, carries cumulative total_cost_usd): {"type":"usage","total_cost_usd":0.0031,"usage":{"provider":"deepseek","model":"deepseek-chat","input_tokens":1200,"output_tokens":800,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.0007,"search_calls":1,"fetch_calls":0}}
5. Final result (result = COMPLETE assistant markdown writeup INCLUDING the trailing fenced ```json summary; usage = run totals): {"type":"result","subtype":"success","total_cost_usd":0.0142,"session_id":"<uuid>","result":"<writeup + fenced json>","usage":{"provider":"deepseek","model":"deepseek-chat","input_tokens":5000,"output_tokens":3200,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.0142,"search_calls":4,"fetch_calls":6}}
6. Wind-down/error: still emit a result whose fenced json has "status":"inconclusive" + a note; missing key → {"type":"error","error":"...","provider":"..."} then graceful inconclusive result.

The trailing fenced ```json block (unchanged existing contract):
{"headline":"...","status":"complete|inconclusive","sourcesConsulted":<int>,"findings":[{"claim":"...","sources":["url"],"confidence":"high|medium|low|unverified"}],"conflicts":[{"claim":"...","positions":["..."]}],"gaps":["..."],"note":"optional"}
(conflicts/gaps only for synthesis-style prompts; for a normal single-topic run, findings + headline + status + sourcesConsulted are the core.)

## run command (fan-out orchestration in the engine)

`quorum-engine run` reads ONE JSON config object on **stdin** (NO secrets — keys stay in env) and runs
the whole fan-out: plan → parallel angles → synthesis → citation grounding → optional autoresearch
rounds. Each role runs on the config's model — `"claude-code[/alias]"` spawns the `claude` CLI
(subscription OAuth stays inside the CLI; the engine never reads the token), any `"provider/model-id"`
runs the AI-SDK BYOK loop. Own-search MCP is wired to claude when a search key is in env.

stdin config: `{ question, angleCount, angles?, angleModel, synthesisModel, effort, perTopicBudgetUSD,
runBudgetUSD, perTopicTimeoutSec, priorNotesExcerpt, template, rounds, autoresearch, useProjectContext,
projectDir }`. `angles` (optional `[{title,prompt}]`) are user-pre-approved round-1 angles — when
present the engine SKIPS its own round-1 planning and uses them verbatim (still emitting `plan`, still
planning rounds ≥2 for autoresearch).

stdout NDJSON events (angle work namespaced by `angle_id`; synthesis uses `angle_id:"synthesis"`):
- {"type":"run_start","session_id":"qrun-<uuid>","protocol_version":1}
- {"type":"phase","phase":"planning|researching|synthesizing|grounding|reconciling|done"}
- {"type":"plan","angles":[{"angle_id","title","prompt"}]}
- {"type":"round","round":<n>,"angles":[{"angle_id","title"}]}   // autoresearch rounds ≥2
- {"type":"angle_status","angle_id","status":"running|complete|halted|error"}
- per-angle live: the single-topic stream_event / assistant / usage events, each carrying `angle_id`
- {"type":"topic_result","angle_id","role":"research|synthesis","backend":"cli|engine","provider","model","session_id","status","result":"<writeup+fenced json>","usage":{…},"note":null}
- {"type":"run_result","status":"complete|inconclusive|halted","total_cost_usd":<n>,"topics":[<all topic_result objects>]}
`backend`="cli" for claude-code (session_id = the CLI's real resumable id), "engine" for BYOK (synthetic
`qeng-<uuid>`). Run-level budget wall stops launching + winds down inconclusive/halted; SIGTERM winds
down each in-flight topic to a halted `topic_result` then a halted `run_result`. Golden run fixture:
`fixtures/run-transcript.ndjson`.

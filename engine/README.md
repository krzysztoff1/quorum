# quorum-engine

A standalone research engine binary for [Quorum](../). It researches one topic end-to-end on cheap
BYOK models + our own web search, and emits the **exact NDJSON stream shape** the Swift app's
`ResearchOutputParser` already consumes — so the app can route cheap "angle" research here instead of
the Claude Code CLI. It never uses Anthropic subscription auth (that stays CLI-side); only BYOK API
keys from environment variables.

See [`PROTOCOL.md`](./PROTOCOL.md) for the exact wire format (the seam with the Swift parser).

## Run one topic

```sh
quorum-engine -p "What is the status of nuclear fusion energy in 2026?" \
  --model deepseek/deepseek-chat \
  --max-budget-usd 0.25
```

Output is NDJSON on stdout: an init handshake, streamed text/thinking deltas, `tool_use` events for
each `web_search`/`web_fetch`, a per-step `usage` line, and a final `result` whose text ends with the
fenced ```json summary.

### Flags (the subset Quorum passes; unknown flags are ignored)

| Flag | Meaning | Default |
|---|---|---|
| `-p <prompt>` | the research topic | — (required) |
| `--model provider/model-id` | e.g. `deepseek/deepseek-chat`, `anthropic/claude-haiku-4-5`, `openrouter/meta-llama/llama-3.1-8b` | `deepseek/deepseek-chat` |
| `--effort low\|medium\|high\|xhigh\|max` | maps to Anthropic thinking budget where supported, else scales the step budget | `medium` |
| `--max-budget-usd <n>` | hard cost wall, checked before every model step | `0.25` |
| `--max-turns <n>` | backstop step cap | effort-derived |
| `--tools <csv>` | accepted for compatibility (engine is web-only: `web_search`, `web_fetch`) | — |
| `--append-system-prompt <str>` | appended to the engine's research contract | — |

Unpriced model, missing key, or budget/time cap → the engine winds down gracefully with a
`status:"inconclusive"` result (never a dead process).

## Model providers (`provider/model-id`)

- `anthropic/*` — BYOK Claude (`@ai-sdk/anthropic`)
- `deepseek/*`, `glm/*`, `kimi/*`, `groq/*` — OpenAI-compatible endpoints (`@ai-sdk/openai-compatible`)
- `openrouter/*` — the long tail, one key (`@openrouter/ai-sdk-provider`)
- any other `provider/*` — routed through `QUORUM_OPENAI_COMPATIBLE_BASE_URL`
- `claude-code` or `claude-code/<alias>` — spawns the `claude` CLI on your subscription (alias → `claude --model <alias>`); the engine only launches it and never reads the OAuth token. Works in single-topic mode (`--model claude-code`) and per-role in `run`.

## Environment (keys are read from env only — never argv, never logged)

| Var | Used for |
|---|---|
| `QUORUM_ANTHROPIC_KEY` | Anthropic BYOK |
| `QUORUM_OPENROUTER_KEY` | OpenRouter |
| `QUORUM_DEEPSEEK_KEY` | DeepSeek (also `QUORUM_GLM_KEY`, `QUORUM_KIMI_KEY`, `QUORUM_GROQ_KEY`) |
| `QUORUM_OPENAI_COMPATIBLE_KEY` / `QUORUM_OPENAI_COMPATIBLE_BASE_URL` | generic OpenAI-compatible provider |
| `QUORUM_TAVILY_KEY` | web search (primary) |
| `QUORUM_BRAVE_KEY` | web search (used when no Tavily key) |
| `QUORUM_PRICE_TABLE_PATH` | optional JSON overriding the bundled price table |
| `QUORUM_TIMEOUT_MS` | wall-clock backstop (default 300000) |
| `QUORUM_CLAUDE_BIN` | optional path to the `claude` CLI (else resolved via PATH / login shell / common install dirs) |

## Serve the same search backend to the Claude Code CLI

```sh
quorum-engine mcp-serve
```

Runs the identical `web_search` / `web_fetch` backend as a stdio MCP server (they appear to the CLI as
`mcp__quorum__web_search` etc.). Point `claude -p ... --mcp-config` at it so CLI-executor runs can ride
the same search stack instead of Anthropic's server-side WebSearch. One implementation, one key.

## Develop

```sh
bun install
bun run test            # vitest (67 tests, hermetic — no network, no real keys, no real `claude`)
bun run record:fixture  # regenerate fixtures/engine-transcript.ndjson (deterministic)
bun run build:bin       # -> dist/quorum-engine (self-contained darwin-arm64 binary)
```

## `run` — fan-out orchestration

`quorum-engine run` runs a whole fan-out (plan → parallel angles → synthesis → grounding → rounds) and
streams a run-level protocol (see `PROTOCOL.md`). Config is one JSON object on **stdin** — no secrets in
it; keys stay in the environment:

```sh
echo '{"question":"Where does fusion stand?","angleCount":3,"angleModel":"deepseek/deepseek-chat","synthesisModel":"claude-code/claude-opus-4-8","runBudgetUSD":5}' \
  | QUORUM_DEEPSEEK_KEY=… QUORUM_TAVILY_KEY=… quorum-engine run
```

Each role runs on its configured model: `claude-code[/alias]` spawns the `claude` CLI (your Claude
subscription — the engine never reads the OAuth token, it just launches the CLI), any `provider/model`
runs the BYOK loop. Pass caller-supplied round-1 angles as `"angles":[{"title","prompt"}]` to skip the
engine's own round-1 planning. SIGTERM winds the run down gracefully.

The golden transcripts (`fixtures/engine-transcript.ndjson` single-topic, `fixtures/run-transcript.ndjson`
fan-out, `fixtures/run-validated-transcript.ndjson` a run whose critic objected and whose second round
settled it, `fixtures/run-reconciled-transcript.ndjson` a two-round dive fused into one current answer) are
real recorded runs (mocked provider + search) proving the wire format; each is copied into
the Swift test suite so `QuorumCore` proves it parses engine output unchanged.

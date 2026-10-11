# quorum-engine

The research engine behind [Quorum](../). It plans a question into angles, runs them in parallel through the
Claude Code CLI on your subscription (the engine only launches `claude` and never reads the OAuth token),
reconciles and validates the result, and writes the run record the app renders.

See [`PROTOCOL.md`](./PROTOCOL.md) for the wire format and the run record.

## Commands

| Command | What it does |
|---|---|
| `run` | config as JSON on stdin; plans, fans out, synthesises, validates, writes `run.json`; `--detach` returns a run id and keeps going |
| `scope` | turns a question into a `Brief` (clarifying questions or a resolved question) |
| `list`, `cancel`, `migrate` | inspect, stop and upgrade runs in the store (default `~/Quorum`, `--store DIR` overrides) |
| `doctor` | checks the CLI, the store and the engine build |
| `check <run-dir>`, `export --md <run-dir>` | audit a run's record; export it as markdown |
| `mcp-serve` | the stdio MCP server the CLI angles use (`web_fetch`, plus `web_search` when a search key is set) |
| `version` | the handshake line the app reads |

Optional env: `QUORUM_CLAUDE_BIN` (path to `claude`), `QUORUM_TAVILY_KEY` / `QUORUM_BRAVE_KEY` (route web
search through your own key instead of the CLI's WebSearch), `QUORUM_TIMEOUT_MS`.

## Frozen code

`src/frozen/` holds the bring-your-own-key path: the AI SDK research loop (`agent.ts`, `providers.ts`),
price accounting (`pricing.ts`, `priceConfig.ts`), the Codex CLI backend (`codex.ts`), the single-topic runner
(`engine.ts`) and the fixture recorder (`record-fixture.ts`). Nothing on the default path imports it, the
compiled binary does not contain it, and `run` refuses any model that is not `claude-code[/alias]`. Its tests
are in `tests/frozen/` and still run.

## Develop

```sh
bun install
bun run typecheck
bun run test            # hermetic: no network, no keys, no real `claude`
bun run test:e2e        # the compiled engine, end to end
bun run build:bin       # -> dist/quorum-engine
```

Golden transcripts in `fixtures/` are recorded runs with a mocked backend; each is copied into the Swift test
suite so `QuorumCore` proves it parses engine output unchanged. Re-record with `bun run fixtures:update`.

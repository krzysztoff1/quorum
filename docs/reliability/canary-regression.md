# The canary's "no claim checked": a tool name, not M6

`scripts/canary.sh` passed on M4 (62f071a) and then failed intermittently from M5 onward with `0 snapshots · 0 claims
checked · N markers stripped`. M6 (detached runs, liveness, no approvals) was the suspect. It is not the cause.

## Root cause

The research prompt (`RESEARCH_SYSTEM_PROMPT`, unchanged since M1) calls the tools `web_search` and `web_fetch`. On the
`claude-code` backend the CLI exposes them as `WebSearch` and `mcp__quorum__web_fetch`. Haiku sometimes calls the
prompt's name, and the CLI answers:

```
<tool_use_error>Error: No such tool available: web_fetch</tool_use_error>
```

That call never reaches the engine's `mcp-serve`, so nothing is captured and nothing is recorded as a failure. Haiku does
not retry. It writes its answer from search snippets, cites URLs it never read, grounding resolves 0 citations, M4's
marker settlement strips the dangling markers, and the claim sweep has nothing to judge. The engine's own record cannot
show this: it keeps the CLI's `tool_use` lines (normalised to `web_fetch`) and drops every `tool_result` and the `init`
message, so the run looks like "the model chose not to fetch".

## Evidence

Offline, from the runs on disk (`~/.quorum-canary`, `/tmp/m5-*`, `/tmp/m7-brain`), all Haiku, 1 angle:

| Run | Build | web_fetch calls | Sources captured | Cited | Markers stripped |
|---|---|---|---|---|---|
| M4 canary (PASS) | da18491 | 3 | 3 | 3 | 0 |
| M5 canary on main | source | 0 | 0 | 0 | 17 |
| M5 head, 2026-10-11 | 56683c9 | 1 | 0 (no evidence directory at all) | 0 | 8 |
| M7 canary | 841e0d7 | 3 | 1 | 0 | 9 |
| main, 2026-10-11 (this investigation) | 90a2b11 | 4 | 4 | 1 | 0 |

A failing run with one fetch and no document and no capture failure is only explained by a call that never reached the
server. A call that reaches it always leaves a document or a failure.

Live, direct CLI probes with the engine's exact arguments and the engine's `mcp-serve` on the Polish canary question
(the CLI's raw stream recorded, so the tool results are visible):

| Probe | Before the fix | After the fix |
|---|---|---|
| 1 | called `web_fetch`: "No such tool available", 0 pages | |
| 2 | called `web_fetch`: "No such tool available", 0 pages | |
| 3 | called `mcp__quorum__web_fetch`, 2 pages | |
| 4 to 7 | | all called `mcp__quorum__web_fetch`, 2 to 3 pages each |

Two of three failed before, none of four after. Small samples, but the failing calls are the same string every time.

The `quorum` MCP server reported `connected` in every probe's `init`, so `mcp-serve`, the evidence directory and the
detached start were ruled out. Main at 90a2b11 (after M6) also passed a live canary when Haiku used the right name.
So the regression is variance in Haiku's tool-name mapping that has always been there. M4's pass was a lucky draw, and
the M5 and M7 branches saw the same failures on their own builds.

## Fix

`buildClaudeArgs` appends the real tool names to a research angle's system prompt, derived from the same variables
that build `--tools`, so they cannot drift (`engine/src/claudeCode.ts`). Tests in `engine/tests/claudeCode.test.ts`.

## Not fixed here

- **The record hides tool errors.** `runClaudeCode` drops `tool_result` blocks and the `init` message. A "No such tool"
  or a disconnected MCP server is invisible in `events.ndjson`. Recording them would have turned this investigation
  from four live probes into a read of one file.
- **No floor under an angle that read nothing.** A run whose angles captured no source still goes on to synthesis.
  A retry or a named incident would be the deterministic answer to any future cause of the same signature.
- **Research runs inherit the user's Claude Code setup.** The init lists about 70 tools from the user's plugins and
  claude.ai connectors beside the engine's two. M7 isolated only the scoper (`--safe-mode`). Isolating research
  needs `--mcp-config` to survive `--safe-mode`, which was not checked.

## Live runs used

Canary: 3 of 4, plus 7 direct CLI probes of about $0.1 each.

| Canary | Build | Result |
|---|---|---|
| main (shim recording the CLI's raw stream) | 90a2b11 | `PASS 3m56s $0.40 · 1 cited · 4 snapshots · 2 claims checked` (Haiku used the right name) |
| the fix, Polish | 2937f4e-dirty | `FAIL 5m31s`: a page was captured (the fix works) but the run took 330 s and was cancelled while validating. Not a citation failure. |
| the fix, English | 2937f4e-dirty | `PASS 3m58s $0.34 · 2 cited · 3 snapshots · 10 claims checked · 0 markers stripped` |

## A separate, timing failure

The Polish canary ran research 135 s, synthesis 50 s, grounding 90 s and validation 45 s. The 270 s deadline is
already M3's known Quick-wall problem (M3 recorded 298 s). It is not touched here. Either re-baseline
`CANARY_MAX_SECONDS` for the Polish question, or wait for the Quick tier (M8).

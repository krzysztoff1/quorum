# M3: the verification floor

PRD 10 §7.1, step M3, built from [verification.md](verification.md). The aim: "never run live" can no longer be
merged, and the owner dogfoods an **installed** app instead of `swift run`.

**Branch:** `dogfood/m3-verification-floor` · **Base:** `233958d` (M2)

## What each rung guarantees now

| Rung | Job | Guarantees | Does not guarantee |
|---|---|---|---|
| **L0 unit** | `engine` (typecheck + 499 tests), `test` (`swift test`, 511) | Logic in isolation. The engine now typechecks in CI. | Anything across a process boundary. |
| **L1 contract** | Swift decodes the engine's own recorded fixtures from the one directory `engine/fixtures/` | The app parses what the engine wrote. The stale hand copies under `Tests/` are gone, and a `XCTSkip` that hid a parser rejection became a failure. | A generated schema (M4). Swift still hand-decodes. |
| **L2 hermetic e2e** | `e2e` job (`bun run test:e2e`, 3 s) | The **compiled** binary runs the whole `run` path through real process boundaries: planner → 2 angles → `web_fetch` through the engine's own `mcp-serve` child → snapshots on disk → grounding → claim sweep → critics → result. No network, no model. Also: the blocked page is a recorded capture failure, the logged-out CLI is a refusal with exit code 3, and `check` audits the written run directory and catches a snapshot edited afterwards. | That a real model behaves like the script (L4). |
| **L3 replay** | Not built. The fixtures that exist are compared byte for byte. | A fixture never changes silently. | Freshness-stamped real recordings (needs M4's record). |
| **L4 live canary** | `scripts/canary.sh`, on the owner's Mac | The subscription path works today, through the installed engine. | Answer quality. |
| **L5 in-product** | `check` at the end of every run, `Quorum --doctor`, Doctor sheet | Every run audits itself and says so in `run_result.checks`. A logged-out CLI is a named refusal, not a $0 "complete". | A badge on the answer (M4/M9). |

The L2 test was mutation-checked: restoring the M1 `selfMcpCommand` bug (the compiled binary handing the CLI a
bogus `mcp-serve` path) fails 8 of its 11 tests.

## Fixtures: one directory, compared, never overwritten

- `engine/fixtures/` is the only home. Swift reads it through `EngineFixtures` (`#filePath`), the engine through
  `tests/fixtureSupport.ts`.
- The recorded run transcripts are compared byte for byte (`matchFixture`). A difference fails the test and names the
  first differing line. Re-record deliberately with `cd engine && bun run fixtures:update` (`UPDATE_FIXTURES=1`),
  then review the diff. This PR did it once, when `run_start` gained the build stamp and `run_result` gained `checks`.
- Moving to the one directory immediately corrected a stale expectation: the real reconciled recording has two
  round-2 angles, and the old hand copy had one.
- Also in the directory: `cli/not-logged-in.ndjson` (the real CLI stream for a logged-out session, recorded from
  `claude` 2.1.295 with an empty config dir) and `e2e/` (the scripted `fake-claude.ts` and the pages it reads).

## `quorum-engine check <run-dir> [--json]` v0

Audits `<run-dir>/events.ndjson` plus `<run-dir>/evidence/`. Exit 0 or 1. The engine keeps `events.ndjson` itself
when the app (or the canary) gives it a `runDir`, and evaluates the same checks over its own stream just before
`run_result`, attaching them as `run_result.checks`.

| Check | Invariant (PRD 10 §2.4 / verification.md §3) |
|---|---|
| `stamp` | #1. `run_start` has a build stamp, and the protocol is the engine's. |
| `stream` | #10. Begins `run_start`, ends one `run_result`, no unreadable lines. |
| `markers` | #2. Every `[^id]` and every finding citation names a declared citation. |
| `sources` | #2. Every citation's source was captured, with a snapshot or a recorded capture failure. |
| `spans` | #2. Resolved spans lie inside their snapshots; an exact match's quote is at its span. |
| `snapshots` | Snapshot files exist and match the index (length, original, page offsets). |
| `counts` | #5 in spirit. Stream and evidence index agree on documents and fetch failures; total cost covers its topics. |
| `verdicts` | #3. Every claim has a verdict or is reported unjudged; a finished answer was validated. |
| `grounding` | #8. `captured`, or the failures explain why not. |
| `refusal` | A refused run is never `complete`. |

`spans` and `snapshots` warn rather than pass when a run kept no evidence directory.

**Deferred to M4**, because they need the run record: #4 (answer spec against the catalog), #5 proper (recomputing
`stats`), #6 (title from scope), #7 (language), #9 (tier cost and duration warnings).

## "Not logged in" is a hard failure

The CLI reports a logged-out session as an ordinary result (`is_error: true`, "Not logged in · Please run
/login", cost $0), which used to end a run `complete`. Now:

- the engine recognises it (the `authentication_failed` assistant message, or an error result saying so), files
  `run_result.refusal = {kind: "not_logged_in", reason}`, stops launching angles, ends `inconclusive` with the reason as
  its `note`, and exits 3;
- the app reads the refusal, stores it and opens the Doctor sheet on a **Last run** row that says it. Run is also
  disabled up front: the preflight now asks `claude auth status` (free, no model call) instead of guessing from files.

## The installed app

```
scripts/install.sh            # builds, then replaces ~/Applications/Quorum.app
scripts/install.sh --open     # and launches it
scripts/make-app.sh [dir]     # just build build/Quorum.app
Quorum --doctor               # print the Doctor rows headlessly; exit 1 when something is wrong
```

`make-app.sh` builds the release app and the engine from one commit (`bundle-engine.sh` stamps the engine with the git
sha, `-dirty` when `engine/` has uncommitted changes), copies the engine and the SwiftPM resource bundles into
`Contents/Resources`, bakes the engine's build into `Info.plist` as `QuorumEngineBuild`, makes an icon from
`AppIcon.png`, and signs ad hoc. There is no hardened runtime, so the Bun binary needs no JIT entitlement.

The app's bundle candidate is **refused** when its handshake build differs from `QuorumEngineBuild` (a broken
bundle), with "reinstall the app" as the fix. Overrides and source runs are not bound by this. At launch the app logs
which engine it resolved, `public`, to the unified log:

```
/usr/bin/log show --last 5m --info --predicate 'subsystem == "io.github.krzysztoff1.quorum"'
```

Verified here: built the app, installed it, launched it with `open`, saw its window and the log line
`engine: …/Quorum.app/Contents/Resources/quorum-engine · engine 0.1.0 · protocol v4 · build <sha>`, quit it cleanly. A bundled
engine from another build is refused in `EngineResolutionTests`.

## The canary

`scripts/canary.sh [en|pl]` runs one cheap live run: Haiku for every role, 1 angle, 1 round, spawning off, through the
installed engine (`QUORUM_ENGINE_BIN` overrides; `engine/dist` is the fallback). It writes `events.ndjson` and the
evidence to `~/.quorum-canary/<timestamp>/` (so a good run is a fixture candidate), runs `quorum-engine check`, and
prints one line:

```
PASS 2m17s $0.147 build d408bb9 · en · status inconclusive · 3 snapshots · 12 claims checked · <run dir>
```

It fails when: the engine refuses (logged out: one line, in a second, at $0), `check` fails, the run takes longer
than 270 s (`CANARY_MAX_SECONDS`), costs more than $3 (`CANARY_MAX_USD`), grounding is not `captured`, fewer than
`CANARY_MIN_SNAPSHOTS` (1) snapshots exist, the validators did not run or checked no claim, or the engine's build
differs from the installed app's. It deliberately accepts `inconclusive`: Haiku's answers draw blocking
objections (M1), and the canary tests the pipeline, not the answer. The questions alternate by day of the year, a
Polish one about GDPR and diet data and an English one about the AI Act's general-purpose model obligations.

### Running it nightly

Nothing is scheduled by this repo. If the owner wants it (verification.md: about 1% of a usage window per run, decision 4),
use a T3 scheduled task, or `launchd`/`cron` on the Mac that holds the Claude login, for example:

```
0 3 * * *  cd /path/to/quorum && scripts/canary.sh >> ~/.quorum-canary/nightly.log 2>&1
```

It cannot run in GitHub CI: the subscription's OAuth stays on the owner's Mac.

### First live result, and what it found

`scripts/canary.sh en` against the installed app, build `d408bb9`, 2026-10-09:

```
FAIL 4m58s $0.446754 build d408bb9 · en · status inconclusive · 3 snapshots · 12 claims checked · /Users/krzysztofduda/.quorum-canary/20261009-233651
  - quorum-engine check failed: FAIL  markers    marker [^a1c17] names no citation;
  - took 298s, limit 270s
```

The pipeline ran end to end on the subscription: planner, 1 angle, 3 snapshots captured by the engine's own fetch,
19 citations located, synthesis, a claim sweep over 12 claims, 3 critics. It FAILED on two things the new floor exists
to catch. Neither is fixed in M3, and each should be fixed before an engine PR is expected to show a PASS:

1. **A dangling footnote marker.** The research angle wrote `[^a1c17]` in its prose but never declared `a1c17` in its
   `citations`; the synthesis carried the marker through. `check`'s `markers` caught it. The pipeline has no step that
   drops or flags a marker with no citation (P1 only fixed it in the Swift note export). It belongs in M4, where the
   record is written by construction, or earlier as a deterministic strip in `composeGrounded`.
2. **298 s against a 270 s Quick wall.** There is no Quick tier yet (M8): this ran the full recipe with one angle, a
   12-claim sweep and three critics, and the citation-verify call hit its own $0.05 cap (`error_max_budget_usd`, $0.063 spent).
   Either the verify budget and the sweep need to come down, or the canary's limit is re-baselined when M8 lands.

Run total $0.45, and the run ended `inconclusive` with 12 blocking objections standing (the sweep judged claims
unsupported or unjudged), as Haiku runs do.

## Not verified

- **The CI jobs** ran green on PR #10 (`engine` 14 s, `e2e` 13 s, `test` 1m29s), including the e2e job on a Linux runner.
- **No question was typed into the installed app.** Its launch, window and engine resolution were checked, not a run from the
  GUI, so the app → engine `runDir` hand-off, a Doctor sheet showing a refusal, and `run_result.checks` reaching a real
  app-written run directory are covered by unit and e2e tests only. No screenshot was taken.
- **Notifications** from the ad-hoc-signed app, and an Intel Mac build, were not tried.
- The canary has run once, on one question (English), so its thresholds are a first guess.
- The reconciled run fixture records a mock that captured nothing, so its own `checks` read `grounding` as failed. It
  is a faithful recording, and nothing asserts on it.

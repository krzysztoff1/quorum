# M6: contract v5

PRD 10 §7.1, step M6, built from §1.4 (commands, protocol v5), §1.5, §1.8 (detached runs) and §3 (the kill list). Two
owner decisions shaped it: watching a run is optional, and nothing ever asks the user mid-run. So the approval and
spawning machinery is deleted, not frozen, and a Deep run now survives quitting the app.

**Branch:** `dogfood/m6-contract-v5`, on `main` at `62f071a` (M4). M5 (answer spec) runs in parallel on
`dogfood/m5-answer-spec`; this step avoids its areas (synthesis, the record's `answer`, the answer view).

## The contract

Protocol **5**, exact match (`version`, `run_start` and `run.created` all say so; the app refuses anything else).
Full reference: [`engine/PROTOCOL.md`](../../engine/PROTOCOL.md).

| Command | What M6 ships |
|---|---|
| `doctor [--json] [--store]` | `claude_cli`, `claude_login`, `fetch`, `store`, `migrate`, `rate_limit`, each with a `fix` when it fails |
| `scope` | A stub: `{needs_scoping:false, brief:{question, language, title}}`. Real scoping is M7 |
| `run [--store] [--detach]` | `--detach` prints `run.created` once `run.json` exists and exits; the run goes on in its own session |
| `cancel RUN_ID [--store]` | `SIGTERM` to the process group; falls back to the process for an attached run; marks a dead run `cancelled` |
| `list [--store]` | One index line per run; marks runs with a stale heartbeat and a dead pid `crashed`, and writes that into the record |
| `check`, `export` | Unchanged from M3/M4 |
| `migrate [--store]` | A table of record-schema upgrades (empty: `quorum.run/1` is the only schema). Does not import the 22 legacy runs |

`run` reads its config from stdin and nothing after it. There is no control channel.

### Detached runs

`run --detach` allocates the question and run ids, then starts the engine again with `detached: true`, so the child
leads its own process group and the CLI children it spawns share it. The parent waits for `run.json`, prints

```json
{"type":"run.created","protocol_version":5,"question_id":"…","run_id":"…","dir":"…","pid":4242}
```

and exits. The child's stderr is kept in `<run dir>/engine.stderr.log`. The engine also runs `caffeinate -i -w <pid>`
on macOS, which replaces the app's IOKit power assertion (deleted).

The app now **always** starts runs this way and follows them from files: `run.json` is the truth, and
`events.ndjson` is tailed through the same handler the app used for stdout. Re-attaching after a relaunch is the same
read from the top of the log, so there is one code path for "live" and "came back". Quitting the app cancels nothing.
The Stop button and the menu bar's "Stop all runs" call `cancel`.

### Liveness

- `run.progress` carries the UX proposal's five stages (Scope is the composer's step 1; the engine's phases map to
  2 research, 3 draft, 4 check, 5 answer), task and source counts. It is emitted on every phase change, every finished
  research task and every heartbeat. `eta_s` is **absent**: it needs durations from past runs, and no tier records
  them yet.
- `heartbeat {pid}` every 5 s. The record keeps `pipeline.pid` and `pipeline.heartbeat_at`, so liveness reads from
  `run.json` alone. This is the only record-schema change; it is additive, so the schema stays `quorum.run/1`, and
  `schema/*.schema.json` and the generated Swift types were regenerated.
- The run graph already lived in the record (M4). The app re-attaches by replaying the log, which carries the graph
  events too, so the canvas rebuilds exactly as it was drawn live.

A run hosted by no process (a unit test) emits neither, which keeps the recorded fixtures deterministic. The
fixtures were re-recorded on purpose for the protocol bump and the progress events.

### What is *not* in v5 yet

- The rest of PRD 10's event vocabulary (`run.created` replacing `run_start`, `task.started`, `source.captured`,
  `record.updated`, dropping the CLI-shaped deltas). The live canvas still consumes the v4 events, so they stay;
  renaming them is part of the M9 rewrite.
- `catalog` in the `version` line (M5 owns the catalog).
- A real rate-limit window for `doctor` (it says "not tracked yet"; the rate-limit preflight is M8).

## Deleted

| Area | Lines |
|---|---|
| **Swift** `PendingApprovals`, `RunControl`/`RunControlChannel`, approval cards, bulk bar, prune/retry/dig, `DigDownSheet`, the waiting-on-you pill and its notification, `ResearchGraph` steering API, `IOKitPowerManager` and `PowerManager` | 776 source lines net (commit `8c51f31` alone: +14 −832, of which `PendingApprovals` 55, `RunControl` 71, `ResearchGraphView` −145, `ResearchGraph` −59) |
| **Swift tests** `PendingApprovalsTests` (93), `RunSteeringTests` (259) and the awaiting-approval phase test | 358 |
| **Engine** `approvals.ts` (98), `spawnLog.ts` (49), `spawn.ts` (273 → `admission.ts` 153), the `spawn_inquiry` tool in `agent.ts` and `mcp.ts`, the spawn plumbing in `backend.ts`/`claudeCode.ts`/`codex.ts`, the control loop, retry/prune/dig and the approval window in `run.ts` | commit `a3d959e`: engine/src +198 −713 |
| **Engine tests** `approvals.test.ts` (85), `spawn.test.ts` (271 → `admission.test.ts` 139), the spawning and approval blocks of `run.test.ts` | engine tests +184 −712 |

`SpawnGate` shrank to `AdmissionGate`, which still rules on the follow-ups the validators file against a draft
(depth, count, dedup, budget headroom, the freeze). It never waits for anyone.

Added in the same range: the commands, liveness, detach, the Swift engine client (`EngineRunClient`, `EventLogTail`,
`EngineCommand`, `RunProgress`) and their tests. Whole branch against `62f071a`: Swift sources +641 −776, Swift
tests +226 −358, engine sources +989 −760, engine tests and e2e +1343 −731.

## Verification

- `cd engine && bun run typecheck && bun run test`: **621** unit tests (594 at M4).
- `bun run test:e2e`: **25** tests (14 at M4). The new `contract.e2e.ts` drives the **compiled binary** through
  detach (it outlives the process that started it and leads its own group), re-attach from the record and
  `events.ndjson` alone (with heartbeats in the log), cancel of a detached run through the group (the run winds down
  `halted` and nothing of its group survives), cancel of an attached run, refusing to cancel a finished run, a
  killed engine reported `crashed` once its heartbeat is stale, a detached replay, `doctor` against a signed-in and
  a signed-out scripted CLI, `scope` and `migrate`. The cancel tests were checked to be meaningful: a group kill
  that missed the CLI child would leave the group alive and fail them.
- **CI on the PR** (`engine`, `e2e` on a Linux runner, `test`): all green.
- `swift build`, `swift test`: **325** tests (324 at M4: 27 new, 26 removed with the approvals).
- A bug the e2e found: a cancel during planning ended `inconclusive` ("Planning failed") instead of `halted`,
  because the planner's partial output looked like a planning failure. Fixed first, with unit tests (`864feff`).
- **Canary**, live, through the installed app's engine (build `e2c1485`), now started the way the app starts runs
  (`run --detach`, then polling `list`):

  ```
  PASS 3m54s $0.306751 build e2c1485 · en · status inconclusive · trust shaky · 2 cited · 3 snapshots · 6 claims checked · 0 markers stripped · ~/.quorum-canary/20261010-011704/questions/01M4HF9CPQF0EAN4J11Q2NRYG6/runs/01M4HF9CPQQA7E0ZSM9CGAXA97
  ```

  46 heartbeats landed in its `events.ndjson` (every 5 s). The canary also no longer waits five minutes on a
  leftover watchdog `sleep`.
- **Installed app** (`scripts/install.sh`, app and engine build `e2c1485`), pointed at a throwaway brain folder with
  Draft effort and Haiku, driven by keystrokes:
  1. Typed a question and pressed Return. The app started `run --detach`; the header read
     "Researching · step 2 of 5" ([screenshot](screens/m6-reattached-live-run.png) shows the later state).
  2. Quit the app while 5 angles were running. The engine (pid 35798, process group 35798) kept going, and its
     heartbeats kept advancing in `run.json`.
  3. Relaunched 40 s later. The sidebar showed the run, spinner and "researching",
     with no restart ([screenshot](screens/m6-relaunched-sidebar.png)). Opening it showed the live canvas rebuilt from the
     log: five running angles, replayed text and "step 2 of 5 · 0 of 5 tasks"
     ([screenshot](screens/m6-reattached-live-run.png)).
  4. Left the app open. The run finished (`inconclusive` at $0.99 of the $1.00 Draft cap, 6m 46s), the canvas filled
     in, the answer opened in the rail and the app posted its notification
     ([screenshot](screens/m6-reattached-run-finished.png)).

  The macOS dialog in these screenshots is another app's permission prompt ("T3 Code (Nightly)" asking for screen
  recording). It was not dismissed or answered; it only sits on top of the capture.

## Not verified

- **The Stop button in the installed app.** `cancel` is covered end to end against the compiled binary (detached and
  attached), but no one clicked Stop in the GUI.
- **A re-attached run that crashes.** The e2e proves `list` marks a killed engine `crashed`; the app's
  silence-then-`list` path (it asks after 20 s without a log line) is unit-tested only in its pieces, not driven.
- **`doctor` rows in the Doctor sheet** compile and decode in tests, and the command passes against the real and the
  scripted CLI, but the sheet was not opened with them in a screenshot.
- **The Swift graph still decodes the old `pending`/`expired` question states and `spawn`/`dig` origins**, and draws
  them read-only. The recorded mock run used by the offline demo contains them. The engine never emits them now;
  removing them means re-authoring that fixture, left for M9.
- `list` repairs a crashed record on disk when it reads it. That is deliberate (every reader then agrees) but it is a
  write from a read command.
- The app re-attaches only at launch; a brain-folder change mid-session does not re-scan.

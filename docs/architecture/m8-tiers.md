# M8: tiers

Two tiers, `quick` and `deep`, are engine data. The app sends the tier and nothing else about how hard to research. This note is what was built, why the Quick wall is built the way it is, and what was not.

## The table

The table is `engine/src/tiers.ts`. `wide` is reserved and unbuilt.

| | quick | deep |
|---|---|---|
| angles / concurrency | 3 / 3 | 4 / 4 |
| rounds (cap) | 1 | 3 |
| validation | claim sweep (every claim against its quote), no critics | sweep, three critics (coverage, conflicts, sources), the loop, reconciliation |
| effort / max turns | medium / 10 | high / 25 |
| budget per angle / per run | $1 / $3 | $4 / $20 |
| models planner / research / synthesis / validator | haiku, sonnet, sonnet, haiku | sonnet, sonnet, opus, haiku |
| stage timeouts plan / research / synthesis / verify / validate | 20 / 140 / 55 / 15 / 25 s | 60 / 480 / 300 / 60 / 120 s |
| wall | hard 270 s, wind-down at 220 s | none, background |

Every model is on the `claude-code` backend: the subscription CLI, with its OAuth inside the CLI. A tier's value is a default. An explicit knob in the run config still wins, as a developer affordance, and the app does not send any.

## Quick fits by construction

The stages run in sequence, so their timeouts add up: plan 20 + research 140 + synthesis 55 + validate 25 = 240 s, plus a 15 s salvage reserve is 255 s, under the 270 s wall. `tests/tiers.test.ts` asserts that sum, so a later edit to the table cannot break it quietly.

`RunWall` (`engine/src/wall.ts`) clamps each stage's timeout to `min(role timeout, hardAt - now - tail[role])`, where `tail[role]` is what the stages after it still need. Research can use all 140 s and still leave the synthesis its 55 s. A slow planner cannot starve the stages after it either, because the clamp is computed when each stage starts.

## The wall

1. **Wind-down (220 s).** After this no optional stage starts: the claim sweep, the citation verifier and the answer repair are skipped, and the run says so. A synthesis that has no room is not started at all.
2. **Hard stop (255 s).** A timer aborts everything still running, one salvage reserve (15 s) before the 270 s wall so the salvaged answer lands inside it. A CLI that ignores SIGTERM is killed outright after two seconds, and the run stops waiting on pipes a child still holds. The abort is a separate controller from the user's cancel, combined with it, so the engine can tell the two apart: a user's cancel still ends `halted`.
3. **Salvage.** The engine builds the answer from the research that finished: the findings and their quotes, drafted into a valid QVS answer, grounded, and checked. No model is called, so a stop at 270 s cannot be followed by another wait. The run ends `partial` when an answer exists, and `inconclusive` when no angle had finished (nothing is invented).
4. **The record says so.** `status: "partial"`, `limits.wall_hit` (`none`, `wind_down`, `hard`), `stats.partial`, and a note naming the limit and what was cut.

The same salvage runs when a synthesis runs out its own clamped timeout before the hard timer fires. The first version of this missed that case: the fake-claude e2e (below) found it, with a hanging synthesis ending `inconclusive` despite finished research.

Not sent: a soft "wrap up" message to the CLI. That needs stream-json input. A Quick research angle gets a sentence in its prompt instead (about two minutes, at most six tool calls) and the timeout is the enforcement.

## Deep

The full fan-out, the validator loop, conflict checks and reconciliation, in the background, with the budget as its bound and no 4:30 wall.

## Threads: "go deeper"

`run` takes `kind` (`run`, `rerun`, `followup`), `parent_run_id` and `question_id` (snake_case, and the engine's camelCase too). A rerun defaults to `deep`, a follow-up to `quick`. The parent's headline, standing objections, conflicts and gaps seed the new run's prior notes, `record.parent_run_id` keeps the link, and `question_id` appends the run to an existing question. An unknown parent is refused before anything spawns. Engine side only: no app screen sends these yet (M9).

## Rate limits

The CLI reports its five-hour window in a `rate_limit_event`. The engine keeps every window it has seen, one entry each (newest sighting wins), in `<store>/rate-limit.json`. `run` refuses to start only while `five_hour` or `seven_day` is rejected, its reset is ahead, and extra usage is not covering it (`refusal.kind: "rate_limited"`, the reset time in the reason, nothing spent). A model-specific window never refuses, and a rejection with no known reset expires after five hours. A run that meets the limit midway ends the same way, unless the CLI had already finished a result. `doctor` shows the percentage used and fails while exhausted. It also reports `threads` as `ok`, which tells the app this engine takes `kind` and `parent_run_id`.

## ETA

Every run records per-stage seconds (`stats.stage_s`: research, draft, check, answer). `run.progress` carries `eta_s`: the rest of the current stage plus the later ones, each from the median of the last nine complete or partial runs of the same tier (read from the 40 most recently touched records, so the scan stays cheap), or the tier's own estimate while there is no history. It is absent for a run with no tier.

## Review fixes

The Opus review of the PR changed seven things: the SIGTERM escalation, the abort at 255 s, rate-limit refusals that bind only when they should, the narrower decline clause, the Polish `bln` rule, `kind: run` as a fresh run, and a visible default tier (a `warning` event and `limits.tier_defaulted`). It also made the ETA history read only the most recent records and count partial runs, and started the wall's clock at `run`, before the record is opened.

## Also in this change

- The numeric trace no longer accepts an unsigned quote ("fell 40%") as proof of a negative datum (-40) unless the words near the number say it declined. A decline word only counts inside the number's own clause (a comma, semicolon, "while", "and", "but", "whereas", "ale", "natomiast" or "zaś" ends it), and a rise word in the clause vetoes it. A Polish `bln` is 10^12 when the answer's language is Polish, or, with no language known, when a Polish unit (zł, mld, mln, tys., PKB) sits beside the number; otherwise 10^9.
- The synthesis template picker is gone from the engine (`TEMPLATE_INSTRUCTIONS`, the `template` config field). Swift lost `EffortPreset`, `ResearchTemplate`, `Effort`, `Depth`, `GuardrailMapper`, `RunSettings`, `ModelChoice` and the AppModel plumbing for them. The Compose settings view lost the rows for them, the smallest edit that compiles; M9 owns that view.
- `QUORUM_WALL_SCALE=0.1` scales every Quick time budget, for tests. The e2e uses it with a fake CLI that hangs on one angle and the synthesis, and asserts a valid `partial` answer inside the scaled wall.

## Not built, and not verified

- **Utilization warnings.** Only a rejected window refuses. A run is not warned at 80% used.
- **Shared evidence across a thread.** A follow-up is seeded with the parent's notes, not its snapshots, so it re-fetches.
- **The rate-limit fixture is hand-built** from the CLI binary's event schema (`engine/fixtures/cli/rate-limited.ndjson`), not recorded from a live exhausted account.
- **Non-subscription profiles.** The app no longer sends model addresses, so Budget, Full BYOK and Codex runs use the tier's Claude models until M10 decides what they become. They are behind the experiments switch.
- **The GUI was not driven.** No screen sends `kind` or `parent_run_id`, and no screen shows `partial` or `eta_s`.

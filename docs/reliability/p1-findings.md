# Dogfood Phase 1: findings from the reliability pass

This pass worked through the bug list in `RUN-VALIDATION-2026-08-10.md`, which covers the run
"Zrób reaserch systemów personalizacji w food tech" (2026-08-10-162410, Subscription profile,
$3.59, 6m14s). Each fixed item is one commit on `dogfood/p1-reliability` (PR #6).

## §2 root cause: the v4 validator loop never ran

**The run never reached the engine.** The app took the in-process Swift fallback
(`runIterativeFanOut`). The run's own files show it:

| Artifact | Engine path would show | The run showed |
| --- | --- | --- |
| Angle entry ids | `a1`, `a2`, `a3` (engine `nextAngleId`) | Swift UUIDs (`70BE1764-…`) |
| Synthesis id | `synthesis` | `synthesis--2133486591675892452` (Swift `hashValue`) |
| `rateLimit` field on entries | absent (engine stream has none) | present (direct `claude` CLI stream) |
| `<runDir>/evidence/` | always created by `EngineRunFanOut` | missing |
| Synthesis transcript | engine-orchestrated synthesis → grounding → validators | a bare `claude` CLI session, `num_turns: 1` |
| report.json | `validation`, verdict nodes | no validation fields |

**Why the fallback was taken.** `QuorumEngine.resolvePath()` returned nil. It only looked in
two places:

1. `QUORUM_ENGINE_BIN`. This was not set: the app was launched without it.
2. `Bundle.main` Resources. Under `swift run`, `Bundle.main` is `.build/<arch>/debug/`, and
   nothing puts `quorum-engine` there. No script in the repo builds an `.app` with the engine
   inside it either. `scripts/bundle-engine.sh <app>` can copy it in, but nothing calls it.

When `resolvePath()` was nil, `AppModel` silently ran the in-process pipeline: no grounding, no
validators, no evidence capture. Commit 4f16287 later added a "legacy pipeline" badge, but
nothing recorded *why* a run fell back, and binary discovery was not changed.

**It would have failed even if a binary had been found.** The only built binary in the main
checkout, `engine/dist/quorum-engine` (built 2026-07-15), speaks **protocol v1**. It predates
the `run` command, so given `run` it falls into single-topic research mode and errors. The
version string is hardcoded `"0.1.0"`, so nothing could tell a stale build from a current one.

**Fix (commit 6d8b0de):**
- **Handshake.** `quorum-engine version` prints one JSON line (`engine`, `engine_version`,
  `protocol_version`, `build`) and spends nothing. `scripts/bundle-engine.sh` stamps `build`
  with the git sha, plus `-dirty` when there are uncommitted changes.
- **Deterministic resolution.** `EngineResolution` lives in QuorumCore and is pure and tested.
  The app probes a fixed order: `QUORUM_ENGINE_BIN`, then the bundle, then
  `engine/dist/quorum-engine` in the checkout above the `swift run` executable. It takes the
  first binary whose protocol equals `RunStreamParser.supportedProtocolVersion`, and records why
  each skipped binary was rejected. A binary older than the `version` command still prints its
  `system/init` line, which carries `protocol_version`, so a stale build is named rather than
  run. Results are cached per binary path and modification time.
- **report.json records the pipeline.** Engine runs record `pipeline.engineVersion`, `build` and
  `protocolVersion`. Fallback runs record `pipeline.fallbackReason`.
- **The fallback is visible everywhere:**
  - home-screen notice, with the reason
  - live canvas header badge, reason in the tooltip
  - digest lines `**Pipeline:** in-process · ⚠️ legacy pipeline — no validation` and
    `**Why no engine:** …`
  - the existing per-entry badge
  - an `NSLog` line when the run starts

## Per-item status

### §1 run titled after the clarifier: already fixed in 4f16287, verified
`RunTitle.from(reply:question:)` falls back to the question whenever the title model's reply
looks like a clarifier, a refusal or a question: more than one line, too long, or containing
`?`/`!`. `RunTitleTests` covers the report's acceptance case, including the real Polish
clarifier.

### §2 validator loop absent: fixed
See the root cause above.

### §3 dangling footnotes, missing evidence: footnotes fixed, evidence partially fixed (commit de9af51)

**Footnotes.** The synthesis used angle-scoped markers (`[^a1c2]` = angle 1's `c2`). Only the
synthesis's own findings were searched for definitions, so most markers either had no
definition or were defined as "no source was recorded". The exported note now traces each
`a<N>c<M>` marker through angle N's findings to the URL it cited, labelled by host, so every
marker has a definition.

**Evidence.** On the engine path, Subscription (claude-code) angles do capture snapshots
through the `mcp-serve` child (`QUORUM_EVIDENCE_DIR`). But they only do so when a search key
(Tavily or Brave) is configured: `groundingTier(env)` is `none` without one. The validated
run lacked evidence because of §2.

A keyless Subscription run still captures nothing. Those runs are now labelled in the digest
(`**Evidence:** ⚠️ not captured …`), alongside the notice the note and run header already
carried.

Not done: snapshotting the CLI's built-in WebFetch results engine-side.

### §4 `transcriptPath` aliasing the note: fixed (commit efaf8cf)
The in-process path stopped aliasing in 4f16287. The engine path, though, filed every angle
with an empty transcript, even though it had streamed that angle's whole tool activity.
`EngineRunPersistence` now keeps each angle's raw stream and writes it to that angle's own
`<angle>.transcript.md`. An angle that streamed nothing gets `transcriptPath == nil`.

### §5 four meanings of "sources consulted": already fixed in 4f16287, verified
Distinct cited URLs are counted in one place (`Reporter.distinctSources`). The digest,
frontmatter and report all read that number, and synthesis entries show
"N angles · M distinct sources". Sources are labelled by host. `SourceCountTests` covers this.

### §6 model narration and a duplicate H1: fixed (commit 79ead0d)
4f16287 already stripped "I have enough…" preambles and demoted H1s inside the writeup. This
pass adds:
- the narration variants it still let through: "Now I have…", "Excellent!", "Good —", and the
  Polish narration a Polish-language run produces
- interjection openers now count as narration only when punctuated as one, so answers like
  "Great Britain…" are no longer stripped
- an end-to-end fixture built from the validated run's angle 2: the angle file ends up with
  exactly one H1 and no preamble

### §8 (partial scope): language fixed, gaps-once fixed (commits eaaff55, 411bdc5)

**Language.** Angles only ever saw the planner's English angle prompt, so "write in the
language the question is written in" resolved to English. Changes:
- Angles on both pipelines now get a line naming the user's original question and telling them
  to answer in its language: `context` in Swift, the appended system prompt in the engine.
- The planner writes titles and prompts in the question's language.
- The line is pinned in `prompt-contract.json`, so the Swift and TS prompts cannot drift.

**Gaps once.** The model wrote its own "## Konflikty i luki" bullet list restating the
structured conflicts and gaps that the note already renders. A bullet-only section is now
dropped when every bullet in it overlaps a structured conflict or gap (overlap of significant
words ≥ 0.35, at least 3 shared). A section that adds anything new is kept.

Not done from §8 (out of scope for this phase): splitting the frontmatter into `title` and
`headline`, the intra-angle conflict wording (that one already landed in 4f16287), and the
source-tier prompt (also already in 4f16287).

### Out of scope
§7 (round 2 / conflict micro-task), Quick/Deep tiers, the scoping chat, UI redesign, and the
Codex/Budget/BYOK profile code.

## Live verification

I ran one real engine run with the compiled binary through the Claude subscription CLI:
`quorum-engine run`, `claude-code/claude-haiku-4-5` for every role, 1 angle, 1 round,
spawning off, Polish question.

- **Time and cost:** 48 s, $0.32 total. The validators cost $0.05 of that.
- **The validator loop ran.** All three critics (`critic_conflicts`, `critic_coverage`,
  `critic_sources`) streamed, and `run_result.validation` was emitted.
- **The run ended `inconclusive` with 2 blocking objections.** Both objections say no evidence
  was captured (keyless run, grounding `none`). **Implication for dogfooding: every keyless
  Subscription run will end this way.** Either configure a search key, or capture the CLI's
  built-in fetches engine-side.
- **Language:** the binary was built before the language commit. Its angle answered in English
  and its synthesis in Polish, which is exactly the behaviour the fix targets. The fix itself
  has **not** been verified live.

Also not verified: the new UI surfaces (header badge, home notice) and binary discovery
under `swift run` inside the running app. Both are covered by unit tests only.

## Test counts
- `swift test`: 578 passing (547 before)
- `cd engine && bun run test`: 355 passing (350 before)

## Follow-ups
- Rebuild `engine/dist` in the main checkout after merging (`scripts/bundle-engine.sh`). The
  Jul 15 v1 binary there is now rejected by name.
- Decide how keyless Subscription runs get evidence: require a search key, or snapshot the
  CLI's WebFetch tool results inside the engine.
- Ship an `.app` build script that runs `scripts/bundle-engine.sh <app>`, so packaged builds
  carry the engine.

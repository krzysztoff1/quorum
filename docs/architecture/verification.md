# Verification strategy: making "never run live" impossible to merge

Supporting research for [PRD 10](10-architecture-rethink.md) §6. It covers why features shipped without ever running
against a live model or being seen on screen, and the concrete gates that stop it.

## 1. How it happened (facts at `4f16287`)

| Gap | Evidence |
|---|---|
| CI runs only `swift test` | `.github/workflows/tests.yml`. The 350 engine tests never run in CI. |
| No test touches the real binary, the real `claude` CLI, the network or `index.ts`'s stdin reading | Engine test survey. Run tests inject `runTopic`; spawn is a fake EventEmitter; MCP runs over `InMemoryTransport`; the AI SDK is `MockLanguageModelV4`; `fetchImpl` is mocked. |
| Only one real subprocess is ever spawned in tests | `fake-claude.sh`, via `QUORUM_CLAUDE_BIN` (`claudeCodeBin.test.ts`) |
| Run fixtures are **overwritten**, not compared | `run.test.ts:349, 1575, 1739` rewrite the three `run-*.ndjson` files on every run. Only `engine-transcript.ndjson` is compared byte for byte (`fixture.test.ts:103`). |
| The Swift fixture copies are stale | `Tests/QuorumCoreTests/Fixtures/` holds hand copies that are still protocol v3, missing `grounding` and `capture` |
| A stale binary can't be detected | `engine/dist/quorum-engine` (2026-07-15) speaks v1, and the version string is hard-coded `0.1.0`. Fixed by P1's build stamp and handshake. |
| Features shipped unseen | Evidence grounding (PRD 03), the dynamic graph (PRD 04) and the graph polish were all merged "not visually confirmed, never run for real" |
| The one real run after v4 took the fallback | RUN-VALIDATION-2026-08-10 §2; root cause in `docs/reliability/p1-findings.md` |
| The first deliberate live engine run happened on 2026-10-09 | P1: Haiku, 1 angle, 48 s, $0.32. The crew ran; the run ended `inconclusive` because nothing was captured. |

**The pattern.** Each layer was well tested *in isolation*. Nothing exercised the seams:
- app ↔ binary (resolution, version)
- binary ↔ CLI (tools, evidence directory)
- CLI ↔ web (capture)
- record ↔ screen (rendering)

Every one of the 2026-08-10 failures sits on a seam.

## 2. The ladder

| Rung | What it proves | Runs where | Gate |
|---|---|---|---|
| **L0 unit** | Logic in isolation (the existing suites) | CI | Every PR |
| **L1 contract** | The engine and the app agree on the data | CI | Every PR |
| **L2 hermetic end-to-end** | The *compiled binary* runs the whole pipeline through a real subprocess boundary | CI | Every PR |
| **L3 replay** | Real recorded runs still produce the same record and export | CI | Every PR |
| **L4 live canary** | The subscription path works today, end to end, within the tier's time and cost | Owner's Mac | PRs touching engine run paths, prompts, protocol, schema or catalog. Optionally nightly. |
| **L5 in-product** | Each real run checks itself and says so | The app | Always |

### L1 contract

- **Zod is the source.** `bun run schema` writes `schema/run.schema.json`, `schema/question.schema.json` and
  `schema/qvs-resolved.schema.json` (`z.toJSONSchema`, zod 4). CI regenerates them and fails on any diff
  (`git diff --exit-code schema/`), so a schema change is always an explicit commit.
- **Swift types:**
  - Record envelope types are generated from the schemas.
  - Catalog element types are hand-written (`docs/viz/RECOMMENDATION.md` §5).
  - A **drift detector** test walks the schema's element union and fails if Swift lacks a case or a required prop.
- **One fixture directory**, `engine/fixtures/`, consumed by SwiftPM test resources through a copy script run in CI
  (or a resources path). No hand copies. Swift decodes every `*.run.json` and `*.resolved.json` fixture and
  asserts round-trip values.

### L2 hermetic end-to-end (new CI job)

1. `bun install --frozen-lockfile && bun run typecheck && bun test`
2. Build the real binary with `bun build --compile` and a build stamp.
3. Start a local fixture HTTP server serving the snapshots of a recorded run's sources. Point `web_fetch` at it
   with a test-only base-URL override.
4. Run `quorum-engine run --store $TMP` with `QUORUM_CLAUDE_BIN=fake-claude.sh`. The fake replays a recorded
   *real* CLI session per task, including tool calls into `mcp-serve`.
5. `quorum-engine check $TMP/questions/*/runs/*` must pass (§3).
6. `swift test` decodes that freshly produced `run.json`. A macOS step runs
   `Quorum --render run.json --out answer.png` and compares it with a golden PNG (with tolerance), uploading it
   as a CI artifact.

```yaml
# sketch: .github/workflows/tests.yml gains a job
engine:
  runs-on: macos-latest
  steps:
    - uses: actions/checkout@v4
    - uses: oven-sh/setup-bun@v2
    - run: cd engine && bun install --frozen-lockfile && bun run typecheck && bun test
    - run: cd engine && bun run schema && git diff --exit-code ../schema
    - run: scripts/build-engine.sh            # compiled binary, stamped
    - run: scripts/e2e-hermetic.sh            # fixture server + fake-claude + run + check
    - run: swift test
    - run: swift run Quorum --render "$E2E_RUN/run.json" --out answer.png && scripts/compare-png.sh answer.png
```

### L3 replay

- **Recordings.** Each canary run (L4) saves `events.ndjson`, `transcripts/` and the evidence snapshots as a
  fixture candidate under `engine/fixtures/runs/<name>/`.
- **Golden.** Replaying a recording through the record writer must produce a byte-identical golden `run.json`
  and a golden `answers/<slug>.md` export.
- **Freshness rule.** Every fixture carries `{protocol, record_schema, catalog, recorded_at}`. A test fails when
  any of those is older than the current versions. **Bumping a version therefore forces a fresh live
  recording**, which forces a canary run.
- **Compare, don't overwrite.** Fixtures regenerate only with `UPDATE_FIXTURES=1`.

### L4 live canary

`scripts/canary.sh` runs on the owner's Mac, on the subscription, through the **installed** app's engine binary
(not `swift run`). It covers the packaging and resolution seam too.

| Item | Spec |
|---|---|
| Questions | Two fixed, alternating, chosen to have stable, fetchable primary sources and a number worth charting: <ul><li>**PL:** "Jakie wymagania RODO dotyczą danych o zdrowiu i diecie w aplikacjach do zamawiania posiłków?"</li><li>**EN:** "What do the EU AI Act's obligations for general-purpose AI models require, and from when?"</li></ul> |
| Tier | Quick |
| Assertions | <ul><li>`check` passes</li><li>duration ≤ 4:30</li><li>notional cost ≤ $3</li><li>`grounding == "captured"` with ≥3 snapshots</li><li>`validation.status == "validated"`, with verdicts on every claim</li><li>answer language == question language</li><li>`pipeline.build` == the installed app's expected build</li></ul> |
| Output | The run record (kept as an L3 candidate); a one-line summary (`PASS 3m41s $1.12 build 0633442`); the `--render` PNG of the answer |
| When | <ul><li>Required before merging a PR that touches `engine/src` run paths, prompts, `PROTOCOL`, schema or catalog. The PR template has a field for the canary run id.</li><li>Optional nightly via a T3 scheduled task. It costs about 1% of a usage window per run if the benchmark ratio holds; that's owner decision 4.</li></ul> |
| Not in GitHub CI | Subscription OAuth stays inside the owner's Claude CLI and must not be exported to CI |

### L5 in-product

**`quorum-engine doctor` runs at launch and before every run.** The Run button is disabled, with the fix shown,
when a blocking check fails. The checks:
- the claude CLI is found, with its version, and logged in
- the engine build and protocol match the app
- the brain folder is writable
- records needing `migrate`
- fetch reachability (Jina, plus direct fetch)
- the last-known rate-limit window

**Every run evaluates `checks` at finish** (PRD 10 §2.4). A failing check shows as an integrity badge on the
answer and is never hidden.

`pipeline.build` appears in the answer footer, so a screenshot always says which code produced it.

## 3. `quorum-engine check` invariants

1. `pipeline.build` is present, and `pipeline.protocol` is the current protocol.
2. Every `[^id]` marker and every datum `cite` resolves to a citation. Every citation's `source_id` exists.
   Resolved `start`/`end` lie inside the snapshot.
3. Every claim has a verdict or an explicit `unjudged`. Every datum has `trust`.
4. The answer spec validates against the catalog: root is `Answer`; no dangling or orphan elements; per-group
   and per-tier visual caps; every visual has a caption, `fallback_md` and `display`.
5. Recomputing `stats` from the arrays gives the stored `stats`.
6. `question.title` came from `scope`, and isn't question-shaped or apologetic.
7. The answer's language is `brief.language` (heuristic).
8. `grounding == "captured"`, or `capture_failures` explain each gap.
9. Duration ≤ the tier wall and cost ≤ the tier cap. These are warnings.
10. `events.ndjson` is well-formed and ends in `run.finished`, or the status is `crashed` or `cancelled`.

## 4. Process rules

- **Definition of done for anything user-visible:** a canary run id plus a `--render` screenshot in the PR.
- **Definition of done for an engine-path change:** a canary run id. If the change bumps a version, refreshed
  fixtures as well.
- **PR template:**

  ```
  - [ ] Canary run id: ______ (PASS / FAIL; duration; cost)
  - [ ] --render screenshot attached (if user-visible)
  - [ ] Version bumps: protocol / record / catalog (fixtures re-recorded)
  ```
- **Dogfood log** (M11): every time the owner had to babysit a run, one line with the run id. That catches
  what invariants can't: a valid answer that's simply not useful.

## 5. What this does not cover

- **Answer quality.** Invariants prove the answer is grounded and well-formed, not that it's good. That needs the
  dogfood log first, then a benchmark rebuilt over records (the old one was killed in M2, tagged `benchmark-v1`).
- **Model drift between canary runs.** The canary samples, it doesn't prove. A nightly cadence narrows the window.

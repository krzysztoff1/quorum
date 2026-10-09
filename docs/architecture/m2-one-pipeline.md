# M2: one pipeline

PRD 10 §7.1, step M2. The engine is now the only pipeline. The app plans nothing, parses no model output
for a run it started itself, and refuses to run when no compatible engine is found.

**Branch:** `dogfood/m2-one-pipeline` · **Base:** `782d714` (P1, PR #6) · **Tag:** `benchmark-final` → `782d714`

## What changed

| Area | Before | After |
|---|---|---|
| Planning | Swift `planAngles` (a CLI or BYOK call from the app), reviewed on the canvas, sent to the engine as `angles` | The engine plans: one tool-less model call (`role: "plan"`, topic id `planning`) in `engine/src/planner.ts`. The app sends no `angles`. |
| Run path | Engine if a binary resolved, else the in-process `runIterativeFanOut` behind a banner | Engine only. No binary → Run is disabled and the home screen says why. |
| Plan review | "Plan N angles" → edit cards → "Research N angles" | Enter (or ⌘↩) starts the run |
| Dev / demo | `DryRunExecutor`, `RunReplayer`, "Mock TS core" toggle | `quorum-engine run --replay <fixture>`; the app uses it when `QUORUM_REPLAY_FIXTURE` is set on a dev launch |
| Engine candidates | override → bundle → `engine/dist` | override → **source** (`bun engine/src/index.ts`, dev launches only) → bundle → `engine/dist` |
| Failure wording | "fallback reason", legacy-pipeline badges | "refusal reason"; the badges are gone with the path they badged |
| Doctor | none | `DoctorView` sheet: every candidate checked, ✓/✗ and the reason, plus the Claude CLI check |
| Benchmark | `Benchmark.swift`, `CodexJudge.swift`, `BenchmarkMetrics.swift` | deleted; recoverable at `git show benchmark-final:Sources/Quorum/Benchmark.swift` |

## Deleted (lines at `782d714`)

| File | Lines |
|---|---|
| `Sources/QuorumCore/FanOut.swift` (the persistence helpers moved to `RunFiling.swift`, 74 lines) | 790 |
| `Sources/Quorum/Benchmark.swift` | 691 |
| `Sources/Quorum/DryRunExecutor.swift` (`AppEnv` kept as `AppEnv.swift`) | 465 |
| `Sources/Quorum/RunReplay.swift` | 216 |
| `Sources/QuorumCore/ResearchPrompts.swift` (`priorNotesExcerpt` kept as `PriorNotes.swift`) | 203 |
| `Sources/QuorumCore/Supervisor.swift` | 168 |
| `Sources/Quorum/ResearchStream.swift` | 126 |
| `Sources/Quorum/EngineExecutor.swift` (`QuorumEngine` kept as `QuorumEngine.swift`) | 99 |
| `Sources/QuorumCore/CLIInvocation.swift` | 93 |
| `Sources/Quorum/StreamingSubprocess.swift` (`StderrTail` kept) | 91 |
| `Sources/Quorum/ClaudeCodeExecutor.swift` (`LiveSnapshot` kept) | 82 |
| `Sources/Quorum/CodexJudge.swift` | 70 |
| `Sources/QuorumCore/EngineInvocation.swift` | 62 |
| `Sources/QuorumCore/BenchmarkMetrics.swift` | 37 |
| `Sources/Quorum/RoutingExecutor.swift` | 29 |
| Tests: `FanOutTests` 726 · `CitationGroundingTests` 229 · `PromptContractTests` 97 · `InvocationTests` 66 · `OwnSearchTests` 59 · `SupervisorTests` 53 · `BenchmarkMetricsTests` 52 · `prompt-contract.json` 52 | 1,334 |

Also removed from surviving files: plan review in `ResearchGraph` (`propose`, `approvePlan`, `revise`, `drop`,
`addProposedAngle`, `proposedAngles`, `planIsRunnable`, `isProposed`, `mark`), the plan-card editor and
"Research N angles" button in `ResearchGraphView`, `FanOutPhase.awaitingApproval`, `RunPipeline`'s
`fallbackReason`/`inProcess`/`badge`/`validates`, the `PreparedTopic`/`ResearchExecutor`/`AnglePlanner`/`RunContext`
types, `GuardrailMapper`'s `prepare`/`runConfig`/MCP helpers, `ResearchOutputParser.parseAngles`, `TestClock`,
`ClaudeCodeLauncher.forkAngle`, and the Replay buttons in History.

**Net, `782d714..HEAD`:** +1,651 / −6,597 (−4,946), of which Swift sources +574 / −4,438, Swift tests +393 / −2,460,
engine sources +170 / −41, engine tests +437 / −21. Moved fixtures (`mock-run.ndjson`, `mock-run.sources/`) are
renames and count as zero.

Tests: Swift 578 → 498, engine 355 → 382.

## Not touched, on purpose

The Codex/Budget/BYOK flag code (`RunProfile`, `Keychain`, `ExperimentalProfiles`, `EngineKeys`) stays until M10.
The run record schema (M4), approvals and spawning (`RunControl`, `PendingApprovals`, the canvas steering) stay
until M6. Chat and `RunTitler` stay until M7. `ResearchOutputParser`, `RunStreamParser` and
`EngineRunPersistence` stay until M4. The engine fetch and grounding files were not edited (M1 is changing them).

## Decisions made in the code that the PRD left open

- **A failed or stopped plan is not researched around.** If the planner errors or returns nothing usable, the run
  ends `inconclusive` with `Planning failed: <reason>.` in `run_result.note`, and no angle is researched. If Stop
  lands during planning, the run ends `halted` without starting any research. Planning cost counts against the run.
- **The planner's budget is $0.15** (as the Swift planner's was), one turn at low effort, and it never gets tools.
- **Planned angles carry the user's prior notes**, as the Swift-approved angles did.
- **Run folders are titled from the question** (`RunTitle.fromQuestion`) at launch instead of by a Haiku call during
  planning. The cheap titler still names untitled legacy folders and serves "Regenerate Title". M7 replaces both.
- **The source candidate is for `swift run` launches only** (`AppEnv.isDev`). A bundled `.app` built inside the repo
  keeps preferring its own bundled engine.
- **The run stream is held to the same exact protocol as the handshake.** A `run_start` that names any other
  protocol, or none, stops the run and says so. The old "older is tolerated" path is gone.
- **The planner's `depth: shallow|deep` hint is dropped.** The engine never used a per-angle preset.
- **Sleep prevention now covers engine runs.** The IOKit assertion used to be held only on the in-process path.
- **`engine/dist/quorum-engine` is still the last candidate**, behind the bundle.

## Opus review of the deletion surface

An Opus subagent reviewed `782d714..HEAD` read-only. Findings and what was done:

| # | Finding | Resolution |
|---|---|---|
| B1 | Round-1 angles lost the prior notes (they went through `foldPriorNotes` when Swift approved them) | Fixed, with a test: planned angles are folded the same way |
| B2 | A failed plan silently fell back to six generic facets, visible only as an `error` line nobody read | Fixed: the run ends `inconclusive` with the reason, no research. Facet fallback deleted |
| B3 | Stop during planning launched phantom facet angles and `claude` processes | Fixed, with a test: the run halts straight after planning |
| B4 | Planner budget went from $0.15 to the per-topic cap | Fixed: capped at $0.15, with a test (also pins `effort: low`, `maxTurns: 1`) |
| B8 | Replay was still blocked by the Claude CLI check | Fixed: `canRun` lets a replay skip it |
| B7 | Menu bar said "1 researching" while planning | Fixed: "Planning…" |
| B5 | On the Codex backend the planner is not tool-less (`codex exec -s read-only`) | Not changed: same as synthesis and validate today; M10 removes Codex |
| B6 | Run titles are no longer AI-generated | Accepted, listed above |
| A1 | `LiveRun.setPhase/setAngleStatus/startRound` and `ResearchGraph.mark` duplicated what `ResearchGraph.apply` does | Removed the graph edits and `mark`; the `FanOutState` updates stay (the header and menu bar read them) |
| A2 | Dead: `TestClock`, `normalizeSource` | Deleted |
| A2 | Dead but tied to out-of-scope code: `TopicUsage.addingCalls/from(steps:)`, `ResearchAngle.preset`, `PresetSpec.sourceBudget/depth`, `Depth`, `RunProfile.executor(for:)`/`TopicRole` | Left: presets die in M8, `RunProfile` in M10 |
| A3 | Stale comments and docs (`runFanOut`, `ResearchStream`, `awaiting_approval`, "pre-approved angles", test names) | Fixed |
| C1 | `CitationGroundingTests` ladder tests still guard `EvidenceIndex.tier` | Restored as `CitationTierTests` |
| C2 | `parseFinal` conflict and gap tests still guard `EngineRunPersistence`'s input | Restored in `ResearchOutputParserTests` |
| C2 | `persistFanOutRound` evidence-on-every-entry, note compounding, old-report decode | Restored as `PersistedRoundTests` |
| C3 | CI ran only `swift test`, so the moved planner/replay/prompt tests were unguarded | Added an `engine` job to `tests.yml` (unverified until CI runs) |
| C4 | No engine test for planner effort and turns | Added |
| D1 | `EngineRunFanOut` still accepted an older or missing `protocol_version` in `run_start` | Fixed: `RunStreamParser.accepts(protocolVersion:)` is exact, with a test |
| D4 | The source candidate applied to any app under a folder with `Package.swift` | Fixed, with a test |
| D3 | `refreshEngine()` runs handshakes and `claude --version` on the main thread on every start | Left (≈0.2 s with `bun`); M6's `doctor` command replaces it |
| D5 | Comments added in rewritten docs | Removed |

## Verification

- `swift build`; `swift test` (498 passing); `cd engine && bun install --frozen-lockfile && bun run test` (382 passing).
- `quorum-engine run --replay engine/fixtures/mock-run.ndjson` on both the compiled binary and `bun engine/src/index.ts`:
  217 lines out, identical to the recorded stream; the 6 recorded snapshots land in `<evidenceDir>/sources/`; exit 0 with
  the app's stdin still open.
- The Swift resolver handshakes with the engine from source (`SourceEngineHandshakeTests`: protocol 4, build `source`).

**Not verified:** the app GUI. Nobody launched `swift run Quorum` and typed a question, so `AppModel.startRun`,
`EngineRunFanOut`'s new `Launch`, `DoctorView`, Enter-to-run and `QUORUM_REPLAY_FIXTURE` are covered only by the pieces
above and the compiler. No live (paid) run: the planner has only been run against mocks and the argv test. The new
CI `engine` job has not run yet.

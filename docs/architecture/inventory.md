# Kill / keep / freeze inventory, with line counts

Supporting research for [PRD 10](10-architecture-rethink.md) §3, which summarizes this per-file table by
subsystem.

**Method:**
- Line counts are `wc -l` on `4f16287`.
- Every Swift and engine file was read and assigned to feature buckets. A file that spans buckets is split by
  estimate (`k191 g141` = ~191 lines in bucket k, ~141 in g).
- The step column refers to the migration in PRD 10 §7.

**Verdicts:**
- **Kill:** delete. It stays recoverable from git; tag first where noted.
- **Freeze:** keep the code, invest nothing, and keep it behind a flag or off the default path.
- **Replace:** the function survives somewhere else.
- **Keep:** unchanged.
- **Rewrite:** same job, new code.

**Buckets:**
- (a) engine client
- (b) in-process pipeline / fallback
- (c) storage and artifacts
- (d) evidence and citations UI
- (e) graph canvas
- (f) mid-run approvals and spawning
- (g) profiles, BYOK, Keychain, Codex
- (h) Chat
- (i) Benchmark
- (j) dry run, replay, mock
- (k) shell and navigation
- (l) other

## 1. Hidden dependencies that shape the order

These came out of the survey and decide what can be cut when:

1. **Planning runs in Swift even on the engine path** (`AppModel.swift:480-487` → `FanOut.swift:15`). Deleting
   `planAngles`, `ClaudeCodeExecutor.plan`, `CLIInvocation.planArguments`, `ResearchStream.plan` and
   `ResearchPrompts` therefore needs an engine planner first (M2).
2. **`ResearchOutputParser` is used by the engine path.** `RunStreamParser` calls `parseFinal`/`parseStreamLine`
   (`:100, :190`), and `EngineRunFanOut` uses its `StreamLine` (`:244`). Chat and `RunTitle` use it too. It can
   go only once the app reads records (M4).
3. **The engine path's storage lives in `FanOut.swift`.** `EngineRunPersistence` calls `persistFanOutRound`,
   `entry()`, `withRegistry` and `withValidation` (`FanOut.swift:131-180, 770-787`). Deleting the fallback in M2
   must keep those helpers until M4 replaces them.
4. **`EngineExecutor`/`EngineInvocation` are not the engine fan-out path.** They run single BYOK topics behind
   `RoutingExecutor`, which only the planner and the fallback use. They are frozen with BYOK, not with the
   engine client.
5. **Engine core imports from frozen modules.** `run.ts` imports `parseFencedJson` from `agent.ts` (BYOK) and
   `resolveEffort` from `providers.ts`. Extract both before freezing.
6. **`SpawnGate` also admits objections** (the validator loop). Simplify `spawn.ts`; don't delete it.
7. **The Benchmark calls `runIterativeFanOut`** (`Benchmark.swift:333`), so it must go, or be frozen out of the
   build, in the same step as the fallback.

## 2. Swift sources

### 2.1 `Sources/Quorum` (UI target, 26 files, 8,152 lines)

| File | Lines | Buckets | Purpose | Verdict | Step |
|---|---|---|---|---|---|
| `AppModel.swift` | 796 | k191 g141 e116 c94 j80 a78 f70 b26 | Root model: ModelChoice, LiveRun, plan/start run, steering, history, queue.json | **Rewrite.** Its BYOK, approvals, dry-run and fallback parts die earlier. | M2/M6/M9 |
| `Views.swift` | 1,125 | k611 l144 e112 d81 h83 c39 g30 f25 | ContentView, Compose, TopicDetail, SynthesisSummary, FanOutView | **Rewrite** to the UX IA | M9 |
| `ResearchGraphView.swift` | 1,224 | e940 d149 f83 l52 | Canvas, cards, approvals, reading rail | **Freeze** as read-only "Show the work"; trim ~700 (approval cards, steering, dig, rail) | M6 |
| `Benchmark.swift` | 691 | i | CLI benchmark runner and judges | **Kill** (`git tag benchmark-v1`) | M2 |
| `Chat.swift` | 596 | h396 l122 c78 | Post-run chat, `ClaudeCodeLauncher`, `RunTitler` | **Kill.** Keep `ClaudeCodeLauncher` (~60) as "Open in Claude Code". | M7 |
| `SourceInspector.swift` | 558 | d | PDF, snapshot and web quote inspector | **Keep.** It becomes the source rail. | M9 |
| `DryRunExecutor.swift` | 465 | j | AppEnv, MockEngineRun, fake executor | **Replace** → engine `run --replay` | M2 |
| `CitedReader.swift` | 315 | d | Citation chips in prose | **Keep**; adapt to `Claim` elements | M5 |
| `FinishedRunView.swift` | 278 | e156 l122 | Finished run as a graph, header strip, Validation tab | **Kill.** The answer page replaces it. | M9 |
| `EngineRunFanOut.swift` | 264 | a | `quorum-engine run` client | **Rewrite** as `EngineClient` (v5) | M6 |
| `QuorumApp.swift` | 256 | k177 g67 f12 | Scenes, menu bar, Settings, BYOK pane, Dock | **Rewrite** (shell); the BYOK pane dies | M9/M10 |
| `RunReplay.swift` | 216 | j | Dev demo replay | **Replace** → engine replay | M2 |
| `MarkdownView.swift` | 196 | l | Markdown view and note editor | **Keep** the renderer; **kill** the editor | M9 |
| `MacServices.swift` | 183 | l118 g50 f15 | Power, notifications, Claude/Codex CLI probes | **Keep.** Drop the Codex probe and the approval notification. | M6/M10 |
| `GraphSnapshot.swift` | 132 | j | `--snapshot` PNG via `ImageRenderer` | **Replace** → `--render <run.json>` for any view | M5 |
| `Keychain.swift` | 127 | g | BYOK keys, EngineKeys | **Freeze → kill** | M10 |
| `ResearchStream.swift` | 126 | b | Per-topic stream reduction | **Kill** | M2 |
| `QuickSwitch.swift` | 102 | k | ⌘K palette view | **Rewrite** (UX ⌘K) | M9 |
| `StreamingSubprocess.swift` | 91 | b54 a37 | Subprocess helper, StderrTail | **Keep** the engine-spawn half | M2 |
| `ClaudeCodeExecutor.swift` | 82 | b52 e30 | CLI executor, LiveSnapshot | **Kill** | M2 |
| `PanZoomCatcher.swift` | 81 | e | Scroll/pinch monitor | **Freeze** | — |
| `CodexJudge.swift` | 70 | i | Codex cross-family judge | **Kill** | M2 |
| `EngineExecutor.swift` | 70 | a | `resolvePath`, per-topic BYOK executor | Resolution is **replaced** by P1's `EngineResolution`. The executor is **frozen → killed**. | M2/M10 |
| `NodeStyleView.swift` | 65 | e | Canvas paint | **Freeze** | — |
| `RoutingExecutor.swift` | 29 | g | Routes each role to the CLI or the engine | **Freeze → kill** | M10 |
| `main.swift` | 14 | k | Entry: `--benchmark` / `--snapshot` | **Keep**; `--render` replaces both flags | M5 |

### 2.2 `Sources/QuorumCore` (logic, 35 files, 6,963 lines)

| File | Lines | Buckets | Purpose | Verdict | Step |
|---|---|---|---|---|---|
| `FanOut.swift` | 787 | b719 c68 | planAngles, runFanOut, runIterativeFanOut, reconcile, grounding, persistence helpers | **Kill** the pipeline; the helpers die in M4 | M2/M4 |
| `ResearchGraph.swift` | 747 | e692 f55 | Graph model, plan edit, steering, `from(report:)` | **Freeze.** Drop plan edit and steering (M2/M6), and `from(report:)` (M4: the graph comes from the record). | M2/M4/M6 |
| `Models.swift` | 720 | l459 c176 g85 | Domain types, RunReport, presets, templates | **Shrink** to generated envelope types; kill presets and templates | M4/M8 |
| `FindingsStore.swift` | 612 | c | RunFolder, disk store, notes, digest | **Replace** → RunRecord reader | M4 |
| `ResearchOutputParser.swift` | 358 | b | Stream-line and fenced-JSON parsing | **Kill** (after M4; see §1.2) | M4 |
| `RunStreamParser.swift` | 347 | a | Run NDJSON parser | **Rewrite** as a small v5 liveness parser | M6 |
| `Evidence.swift` | 345 | d | SourceDocument, Citation, EvidenceIndex | **Keep** → generated envelope types | M4 |
| `GraphLayout.swift` | 299 | e | Layout | **Freeze** | — |
| `QuoteLocator.swift` | 284 | d | Quote matching | **Simplify** to a PDFKit highlight fallback (~80). Engine offsets are the truth. | M4 |
| `Citations.swift` | 226 | d | Markers, blocks, footnotes | **Keep** (marker rendering) | — |
| `Reporter.swift` | 201 | c | Digest, distinctSources | **Replace**: `stats` lives in the record | M4 |
| `ResearchPrompts.swift` | 195 | b | Prompt contract | **Kill**: one prompt set, in the engine | M2 |
| `Supervisor.swift` | 168 | b | Spend and time walls | **Kill** | M2 |
| `NodeStyle.swift` | 167 | e | Style table | **Freeze** | — |
| `RunProfile.swift` | 162 | g | Profiles, routing, validators, Codex models | **Freeze → kill** | M10 |
| `EngineRunPersistence.swift` | 117 | c | Engine stream → notes and report | **Replace** (the engine writes the record) | M4 |
| `RunValidation.swift` | 96 | l | Verdicts saved in report.json | **Replace** (`validation` in the record) | M4 |
| `CLIInvocation.swift` | 93 | b | `claude` argv, plan args | **Kill** | M2 |
| `GuardrailMapper.swift` | 92 | g50 b42 | Preset spec, read-only tools, MCP config | **Kill** → engine `tiers.ts` | M2/M8 |
| `RunPhase.swift` | 75 | e55 a20 | Wire phase mapping | **Replace** with the 5 user stages from `run.progress` | M6 |
| `CanvasViewport.swift` | 75 | e | Zoom/pan math | **Freeze** | — |
| `RunEvidence.swift` | 74 | d | Live evidence fold | **Fold** into the record reader | M4 |
| `RunControl.swift` | 71 | f | approve/reject/prune/retry stdin lines | **Kill** | M6 |
| `EdgeGeometry.swift` | 71 | e | Wire beziers | **Freeze** | — |
| `RunHeader.swift` | 70 | c | Report → header numbers | **Replace** (`stats`) | M4 |
| `ReportEvidence.swift` | 67 | d | Per-node evidence | **Fold** into the record reader | M4 |
| `EngineInvocation.swift` | 62 | a | Per-topic engine argv (BYOK) | **Freeze → kill** | M10 |
| `RunTitle.swift` | 57 | c | Title sanity check and fallback | **Kill**: the title comes from `scope` | M7 |
| `Clocks.swift` | 56 | l | SystemClock | **Keep** | — |
| `PendingApprovals.swift` | 55 | f | Offer pill, notify-once | **Kill** | M6 |
| `Mention.swift` | 50 | h | @-mentions | **Kill** | M7 |
| `RunPipeline.swift` | 45 | a | Pipeline/protocol badge | **Kill**: the record's `pipeline` replaces it | M2 |
| `Preflight.swift` | 42 | l30 a12 | CLI check, engineNotice | **Replace** → `doctor` | M6 |
| `QuickSwitch.swift` | 40 | k | Ranking | **Keep** | — |
| `BenchmarkMetrics.swift` | 37 | i | URL domains | **Kill** | M2 |

### 2.3 Bucket totals

| Bucket | Src UI | Src Core | **Src total** | Tests | Verdict |
|---|---|---|---|---|---|
| a engine client | 449 | 486 | **935** | 721 | Rewrite (~400) |
| b in-process pipeline | 258 | 1,575 | **1,833** | 1,382 | Kill |
| c storage | 211 | 1,301 | **1,512** | 1,647 | Replace (~250 + generated types) |
| d evidence UI | 1,103 | 996 | **2,099** | 705 | Keep (QuoteLocator simplified) |
| e graph canvas | 1,500 | 1,359 | **2,859** | 1,983 | Freeze, trim ~700 |
| f approvals | 205 | 181 | **386** | 419 | Kill |
| g profiles/BYOK | 444 | 297 | **741** | 292 | Freeze → kill M10 |
| h chat | 479 | 50 | **529** | 35 | Kill (keep ~60) |
| i benchmark | 761 | 37 | **798** | 52 | Kill |
| j dry-run/replay | 893 | 0 | **893** | 301 | Replace |
| k shell/nav | 1,095 | 40 | **1,135** | 70 | Rewrite |
| l other | 754 | 641 | **1,395** | 450 | Mostly keep |
| **Total** | 8,152 | 6,963 | **15,115** | 8,057 | |

### 2.4 Swift tests by bucket (46 files, 8,057 lines at `4f16287`)

| Bucket | Files (lines) | Fate |
|---|---|---|
| a | EngineRunTranscript 103, EngineTranscript 56, RunStream 249, RunPipeline 72, UsageLedger 178, Invocation 66 (a33/b33), RunPhase 90 (e60/a30) | Rewritten against v5 events and record fixtures |
| b | FanOut 686, CitationGrounding 229, ResearchOutputParser 249, PromptContract 81, Supervisor 53, Mapper 111 (g60/b51) | Deleted with the pipeline. Grounding behaviour is already covered engine-side. |
| c | BrainStore 366, StoreReporter 379, EngineReconciliation 172, KeylessRunPersistence 93, LeftOpen 68, NotePolish 106, RunHeader 166, RunTitle 61, RunValidationPersistence 143, SourceCount 93 | Rewritten as record-decode and export golden tests (the export moves to the engine) |
| d | Evidence 259, QuoteLocator 202, ReportEvidence 101, RunEvidence 143 | Kept or adapted |
| e | CanvasViewport 102, EdgeGeometry 76, GraphLayout 494, NodeStyle 171, ResearchGraph 553, RunCanvasContinuity 177, ResearchGraphLive 398 (e350/f48) | Kept (frozen code), minus steering and plan edit |
| f | PendingApprovals 105, RunSteering 266 | Deleted |
| g | CodexRouting 72, OwnSearch 59, Routing 101 | Frozen, then deleted in M10 |
| h, i, j, k | Mention 35, BenchmarkMetrics 52, MockRunTranscript 301, QuickSwitch 70 | Deleted, except QuickSwitch |
| l | Preflight 42, TestSupport 408 | Kept and adapted |

PR #6 added `EngineResolutionTests` and grew several of these; the totals above are from before it.

## 3. Engine (`engine/src`, 23 files, 5,466 lines)

| Module | Lines | Bucket | Verdict | Notes |
|---|---|---|---|---|
| `run.ts` | 1,224 | core (~150 spawn glue, ~250 grounding) | **Keep**; remove the spawn glue and the stdin control loop | Gains the record writer and tiers |
| `evidence.ts` | 585 | evidence | **Keep** | Gains the number-in-quote helper |
| `validate.ts` | 502 | validation | **Keep** | Judges claims and datums (batched per component) |
| `agent.ts` | 416 | BYOK (core imports `parseFencedJson`) | **Freeze** after extraction | — |
| `codex.ts` | 393 | Codex | **Freeze** | — |
| `claudeCode.ts` | 357 | core | **Keep** | Hybrid tools: `WebSearch` + `mcp__quorum__web_fetch` (M1) |
| `spawn.ts` | 273 | spawning (gate admits objections) | **Simplify** (~120) | Dedup, caps and headroom for objections only |
| `backend.ts` | 246 | core (~110 BYOK, ~35 Codex) | **Simplify** | Freeze the BYOK and Codex dispatch |
| `search.ts` | 225 | search + fetch | **Keep** fetch; **freeze** Tavily/Brave | Fetch is keyless |
| `engine.ts` | 147 | single-topic `research` | **Freeze** | Only the BYOK `EngineExecutor` uses it |
| `emitter.ts` | 131 | core | **Keep** → v5 events | P1 added `versionLine` |
| `pricing.ts` | 127 | ledger | **Freeze** | The CLI reports notional cost |
| `record-fixture.ts` | 116 | tooling | **Replace** with a canary recorder | — |
| `mcp.ts` | 107 | mcp-serve | **Keep** `web_fetch` (+ offset parity); **kill** `spawn_inquiry` | — |
| `approvals.ts` | 98 | approvals | **Kill** | — |
| `systemPrompt.ts` | 98 | core | **Keep** | The one prompt set; language rule; "don't ask" rule |
| `reconcile.ts` | 87 | core | **Keep** | Emits the answer spec |
| `args.ts` | 80 | single-topic | **Freeze** (keep `version`/`run`/`mcp-serve` parsing) | — |
| `providers.ts` | 71 | BYOK (core uses `resolveEffort`) | **Freeze** after extraction | — |
| `index.ts` | 61 | core | **Keep**; drop the stdin control reader | New commands go here |
| `spawnLog.ts` | 49 | spawning | **Kill** | — |
| `config.ts` | 46 | core | **Keep** | `groundingTier` → fetch capability |
| `errors.ts` | 27 | core | **Keep** | — |

**Engine tests** (19 files, 5,348 lines):
- Core: run 1,778 (includes spawn, grounding, loop and reconcile sections), emitter 154, prompts 132, reconcile 89
- validate 567
- evidence 525
- BYOK: agent 528, providers 75
- Single-topic: engine 146, args 55
- Spawning: spawn 271, approvals 85
- codex 255
- search 187
- Claude: claudeCode 126, claudeCodeBin 72
- mcp 108
- fixture 107
- pricing 88

The spawn and approvals sections shrink with the code. BYOK and Codex tests stay green but frozen.

**New engine code** (estimate ~1,500 lines):
- `record/` (schema, writer, stats, checks)
- `answer/` (the QVS catalog, JSONL compiler, validate/resolve/repair; see `docs/viz/RECOMMENDATION.md`)
- `tiers.ts`
- `scope.ts`
- `planner.ts` (port of the Swift planner prompt)
- `export.ts`
- `doctor.ts`
- `check.ts`
- the replay backend

## 4. Net effect

| | Swift src | Swift tests | Engine src |
|---|---|---|---|
| Killed outright | ~4.5k | ~2.5k | ~0.3k (approvals, spawnLog, spawn glue, `spawn_inquiry`) |
| Replaced | ~1.5k → ~0.65k new | ~1.6k rewritten | — |
| Trimmed (canvas) | ~0.7k | ~0.3k | — |
| Frozen until M10 | ~0.9k | ~0.3k | ~1.3k (BYOK, Codex, single-topic, pricing) |
| Added | catalog views (~13) + `--render` | fixture decode + drift detector | ~1.5k |

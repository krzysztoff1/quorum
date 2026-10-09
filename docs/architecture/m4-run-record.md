# M4: the canonical run record

PRD 10 §7.1, step M4, built from §2 (the record, its invariants, projections, export, legacy, Wide/brain). The
engine is now the only writer of a run. It writes one directory per run in a brain folder, the app reads
`run.json` and nothing else, and every count a surface shows is a stat the engine computed once.

**Branches:** `dogfood/m4-run-record-engine` (engine, PR A) → `dogfood/m4-run-record` (app, PR B), stacked on `main`
at `d119aef` (M3).

## The brain folder

```
~/Quorum/                                   # default; the sidebar's folder button chooses another
  questions/<question_id>/                  # ULID; folder names never carry titles
    question.json                           # quorum.question/1: original + resolved text, language, title, run ids
    runs/<run_id>/
      run.json                              # quorum.run/1, rewritten atomically (temp + rename)
      events.ndjson                         # every line the engine emitted
      evidence/documents.jsonl, sources/    # unchanged from protocol v2/v3
      transcripts/<task>.ndjson             # each task's own stream lines, written by the engine
  answers/<slug>-<id tail>.md               # the markdown export, rewritten on every finish
```

- The engine allocates both ids when the app sends `brainDir`, and names them on `run_start`
  (`run_id`, `question_id`, `run_dir`). `runDir` still works for a caller that wants one bare directory.
- The app keeps the folder in `UserDefaults` (`brainFolder`); the default is `~/Quorum`, outside any code repo.
  The project picker and the per-project `Quorum/queue.json` are gone; run settings live in `UserDefaults`.
- The 22 old runs under the repo's `Quorum/` folder are not migrated or imported (owner decision, PRD 10 §2.8).
  They stay readable in Finder.
- The title is `titleFromQuestion` (`title_source: "question"`) until scoping lands (M7).

## The record (`quorum.run/1`)

Zod source: `engine/src/record/schema.ts`. `bun run schema` writes `schema/run.schema.json`,
`schema/question.schema.json` and `Sources/QuorumCore/RunRecord.generated.swift`; an engine test fails while any
of the three is stale.

| Field | What it holds |
|---|---|
| `id`, `question_id`, `kind`, `created_at`, `updated_at`, `finished_at` | identity and time |
| `status`, `status_note`, `refusal` | `running` until `run_result`, then the run's own status and wall |
| `brief` | `{question, language}`: the run's only input until M7 |
| `pipeline` | engine version, build, protocol, backend, the four models, grounding |
| `answer` | `{format: "markdown", task_id, headline, markdown}`: the answering task's prose, without the fenced summary, the stream-only appendices or leading narration. M5 replaces it with the QVS spec. |
| `claims` | the answer's marked sentences, each with the sweep's verdict (or `unjudged`), `strength` and `confidence` |
| `citations`, `sources`, `capture_failures` | every resolved quote (run-unique ids), every captured document with `source_type`, `read_by` and `cited` |
| `conflicts`, `gaps`, `validation`, `open_items` | what the answer left open; `open_items` holds ids only |
| `tasks` | plan, angles, objection angles, every round's synthesis (`synthesis`, `synthesis.r2`, …), verify, reconciliation, each with its writeup, findings, cost, timing and transcript path |
| `graph` | the orchestrator's own nodes and edges, final statuses merged in |
| `cost`, `limits`, `timeline` | total and by role; the cap and deadline it ran under; phase changes |
| `stripped_markers` | every dangling `[^id]` the engine removed, and from which task |
| `stats` | computed once from the arrays above |
| `checks` | the same report `run_result.checks` carries |

**How it is written.** The record is a fold of the event stream (`engine/src/record/build.ts`). The recorder tees
the engine's own sink, applies every event and rewrites `run.json` after every structural one, so a reader always
finds a whole, schema-valid record with `status: "running"` until the run reports. Same events, same record: the
golden records in `engine/fixtures/record/` are the recorded transcripts folded with a fixed clock.

**Decisions the PRD left open.**
- `claims` are the answer's sentences that carry a marker, because those are what the claim sweep judges. Each
  task keeps its structured `findings` separately. `strength` is `solid` when the sweep supported the claim and it
  rests on two independent sources or one primary source; `confidence` follows from the verdict and the strength.
- `trust_level` is `unchecked` when nothing was captured or nothing was judged, `shaky` when the answer does not
  hold or under 40% of its claims are solid, `solid` at 70% or more with every claim judged, else `moderate`.
- `sources_read` counts documents with captured text; `sources_cited` counts the distinct sources behind a located
  citation the answer uses. The UI says "12 cited · 45 read".
- Planning cost is what the total does not explain after research, synthesis, verify and validation.
- `tier` is not in v1: tiers are M8. `limits` carries the cap and deadline the run actually had.

## Counts agree by construction

`stats` is the only place a number is counted. The header strip, the audit card, the notification, the export's
frontmatter and the canary's summary all read it. `check` recomputes `stats` from the record's arrays (and each
source's `cited` flag) and fails on any difference.

## The dangling marker the canary found

M3's canary failed on `[^a1c17]`: a research angle cited a quote it never declared, and the synthesis carried the
marker through. Grounding now settles every marker (`engine/src/markers.ts`):
- a marker the run already verified elsewhere (an angle's `a2c3` reused by the synthesis) is resolved into the
  topic's citations;
- any other is stripped from the prose, its definition line and the findings, and listed in
  `run_result.stripped_markers` and the record's `stripped_markers`.

`check` warns (`markers`, `references`) instead of failing, because the shipped prose is now consistent; the
header strip says "1 dangling marker stripped". A marker that survives into the answer or a writeup without a
citation still fails `references`.

## `quorum-engine check` (M3's v0 plus the record)

M3's ten stream checks stay. New, over `run.json` and the `question.json` two levels up:

| Check | Invariant (PRD 10 §2.4) |
|---|---|
| `record` | there is a `run.json` |
| `schema` | `run.json` and `question.json` validate (#4, envelope only until M5) |
| `stats` | stored `stats` and every `cited` flag recompute from the arrays (#5) |
| `references` | every marker in the answer and the writeups, every claim and finding citation, every citation's source and every open item resolve (#2); warns on stripped markers |
| `answer` | a complete run holds an answer from a completed task |
| `title` | the title is not a clarifier, an apology or a question (#6); warns with no `question.json` |
| `language` | warns when the answer reads in another language than the question (#7, heuristic) |
| `limits` | warns over the cost cap or the deadline (#9) |

## `quorum-engine export --md <run-dir>`

A pure function of `run.json` and `question.json` (`engine/src/record/export.ts`), golden-tested
(`engine/fixtures/record/mock-run.md`): frontmatter from the question, brief and stats; the lead; the answer;
open items (conflicts with both sides, standing objections, gaps, tasks that did not finish); cited sources with
type and match badge; one footnote definition per marker kept. A marker with no citation is dropped. The engine
writes it to `answers/` on every finish.

## The app

- **Types.** `RunRecord` and `QuestionRecord` are generated; `RunRecordDriftTests` decodes every golden record,
  re-encodes it and compares every key path, and checks that every property the JSON Schema declares has a
  `CodingKey`. Unknown enum values decode to `.unknown`.
- **Reading.** `StoredRun` loads a run directory, `BrainFolder` lists `questions/*/runs/*` newest first. Adapters
  give the existing views what they read: the canvas is `run.graph` (the record's graph folded through the same
  `ResearchGraph.apply` the live run uses), `RunHeader` reads `stats`, `RunValidation` reads `validation` and the
  verdict nodes, and evidence comes from `sources` and `citations`.
- **Live.** The app learns the run directory from `run_start` and reloads `run.json` whenever a topic finishes,
  so the rail beside a running canvas reads the engine's writeups and quotes instead of parsing model output.
- **Handshake.** `version` now says `record_schema`; a candidate that does not write `quorum.run/1` is refused.
- **UI kept working** with small adapters: History lists records, a finished run opens on its canvas, "Answer &
  chat" opens the answer with its citations, the Answers section browses `answers/`. The new UI is M9.

## Deleted

Hand-written Swift, lines at `d119aef`:

| File | Lines | Why |
|---|---|---|
| `FindingsStore.swift` (notes, digest, run folders, note writer, footnote export) | 627 | the engine writes the run; `NotesFolder` keeps the 80-line tree browser |
| `ResearchOutputParser.swift` | 332 | the engine parses model output; the CLI stream-line half moved to `CLIStream` (77) |
| `QuoteLocator.swift` | 284 → 31 | the engine's offsets are the truth; the PDF search ladder stays |
| `Models.swift` (`RunReport`, `TopicFindings`, `FindingsStore`, `WriteResult`, `NoteAction`) | −272 | replaced by the record |
| `Reporter.swift` | 202 | `stats`; two formatters moved to `Format` |
| `ResearchGraph.from(report:)` | −155 | the graph is the record's |
| `EngineRunPersistence.swift` | 125 | the engine writes the record and the transcripts |
| `RunFiling.swift` | 74 | gone with the writers (`FanOutPhase` moved to `RunPhase`) |
| `ReportEvidence.swift` | 67 | `StoredRun.evidence(forNode:)` |
| `Citations.swift` footnote definitions | −65 | P1's footnote export stop-gap; the engine export replaces it |
| `RestatedOpenQuestions.swift` | 64 | note writer helper |
| `RunTitle.swift`, `RunTitler` in `Chat.swift` | 57 + 88 | folders are ULIDs, so nothing renames them; titles come from `question.json` |
| `PriorNotes.swift` | 14 | it only read what the deleted note writer wrote |
| `GraphSnapshot`'s hand-built report | −116 | `--snapshot out.png [run.json]` renders a record |

Swift sources: +2,060 / −3,224, of which 1,299 lines are the generated types, so hand-written Swift is about
−2,460 lines. Swift tests: +407 / −3,645 (511 → 324 tests): the deleted tests guarded the writers, the digest and
answer parsing; `RunRecordDriftTests`, `StoredRunTests`, `CLIStreamTests` and rewritten graph, evidence, stream
and quote tests replace them. Engine: +2,062 source and about +1,100 test lines (499 → 594 unit tests, e2e 11 → 14).

P1's stop-gaps from PRD 10 §7.3 are gone: the Swift footnote export, the Swift transcript persistence and the
parser's narration stripping (ported to the engine's writeup normalizer with the validated run's angle-2 fixture
and every preamble the Swift tests pinned).

## Verification

- `cd engine && bun run typecheck && bun run test` (594) and `bun run test:e2e` (14: the compiled binary writes the
  brain layout, `check` passes on it, `export --md` defines every marker and matches `answers/`).
- `swift build`, `swift test` (324).
- **Live canary**, once, through the installed app's engine (build `da18491`, the same engine source as the engine
  PR's head):

  ```
  PASS 2m55s $0.233733 build da18491 · en · status inconclusive · trust shaky · 3 cited · 3 snapshots · 15 claims checked · 0 markers stripped · ~/.quorum-canary/20261010-003628/questions/01M4HCZ2A0D9BARS1JGK80MVW6/runs/01M4HCZ2A0NTS0N170WTS5Q5SZ
  ```

  `quorum-engine check` on that directory: 17 passed, 0 failed, 0 warnings (the ten stream checks and the seven record
  checks). The run wrote `question.json`, `run.json`, `events.ndjson`, `evidence/`, `transcripts/` (planning, the angle,
  the synthesis, two sweep batches, three critics) and `answers/what-do-the-eu-ai-act-s-obligations-for-general-0mvw6.md`.
  M3's two canary failures did not recur: no dangling marker reached the answer, and it ran in 174 s against the 270 s
  limit (M3's took 298 s; Haiku's run time varies, so this is not a fix for the Quick wall, which is M8).
  It ended `inconclusive` with 15 blocking objections (11 claims judged unsupported, 3 misquoted), as Haiku runs do;
  the canary tests the pipeline, not the answer.
- **Installed app** (`scripts/install.sh`, app build `da18491`), pointed at the canary's brain folder and opened on
  that run: [`screens/m4-finished-run.png`](screens/m4-finished-run.png). The header strip reads `stats` (trust shaky,
  1 solid · 14 shaky, 6 gaps, 15 objections standing, 3 cited · 3 read, 1 angle, 2m 54s, $0.23 / $1.50), the canvas is
  the record's graph, and the rail reads `answer.markdown` with the sweep's ⚠ on the quotes it rejected. The brain
  folder setting was reset to the default afterwards.
- **Review.** An Opus subagent reviewed the diff read-only and found seven problems, all fixed with tests before the
  canary: a title check that failed every question starting "Can you…", markers left unsettled when a summary could
  not be read, `references` failing on unresolved quotes, a crashed run's record saying `running` forever, verify
  spend booked as planning, the sidebar losing a live run's selection, and the writeup normalizer cutting a model's
  own "## Validation approach" heading.

## Not verified / known gaps

- **No question was typed into the installed app.** The app → engine `brainDir` hand-off, `run_start` naming the
  record, the live rail reloading `run.json` and the sidebar following a live run to its record id are covered by unit
  tests, the compiled-binary e2e and the canary (which drives the engine directly), not by a GUI run.
- **Chat and "Open in Claude Code"** still point at the brain folder but were not exercised.
- **Planning cost** is inferred (the planner reports no topic); every other role now reports its own cost.
- The canary's watchdog leaves a `sleep` child alive, so `scripts/canary.sh | tail` waits about five minutes after the
  run (pre-existing from M3, not changed here).
- `RunStreamParser` still parses `run_result.validation`, which nothing in the app reads any more; M6 rewrites it.

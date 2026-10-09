# Quorum

![Status](https://img.shields.io/badge/status-alpha-orange)
[![Tests](https://github.com/krzysztoff1/quorum/actions/workflows/tests.yml/badge.svg)](https://github.com/krzysztoff1/quorum/actions/workflows/tests.yml)
![Tests](https://img.shields.io/badge/tests-585-brightgreen)

**Ask one question. Quorum runs blind, parallel, read-only research agents and reconciles the
results into one cited note that grows into a second brain.** It's a native macOS app: an
**orchestrator, supervisor, and UI** over the Claude Code CLI. The agents are read-only, so a failed
run wastes spend but can't touch your files.

---

## Demo

https://github.com/user-attachments/assets/e6719578-dd30-410e-9ce0-922daa270050

---

## Why Quorum

- **Explore every angle.** One question becomes N blind, parallel angles. A final summariser
  reconciles them, weights sources by cross-angle support, and flags conflicts.

- **Read-only and cost-capped.** Agents can only use `WebSearch`, `WebFetch`, and optional
  `Read`/`Grep`/`Glob`. A supervisor stops the run on spend or time limits, so failures stay bounded.

- **Your research compounds.** Findings land in a durable note per topic, and later runs extend that
  note instead of duplicating it.

- **Cited, with confidence levels.** Every claim carries a confidence level and sources. A
  deterministic citation check flags unsupported citations, and weak answers are marked `inconclusive`.

- **Plain files you own.** Notes are markdown with YAML frontmatter and `[[wikilinks]]` in your
  project folder. They work with `git`, `grep`, Obsidian, and Logseq. No database and no cloud.

- **Browse and edit in-app.** A **Notes** sidebar mirrors your markdown tree, lets you edit notes in
  place, and keeps YAML frontmatter hidden. Rendering is powered by
  [SwiftMarkdownEngine](https://github.com/nodes-app/swift-markdown-engine).

- **One cost dial.** Four presets trade cost for depth, and you set per-topic and per-run spend caps.
  You can also pick the model for each role and see its list price.

- **No second login (default).** Out of the box Quorum reuses your existing Claude Code CLI sign-in —
  no API key, `$0` marginal. Bringing your own cheap models is entirely opt-in (see *Budget mode*).

- **Built on the Claude Code CLI, so you can take over.** Every angle and synthesis runs as a real
  Claude Code CLI session, so you can resume any thread with `claude --resume`.

## Budget mode — bring your own cheap models (opt-in)

The default uses your Claude Code subscription and no API key. When research starts competing with
coding for your weekly limit, a **run profile** lets one run mix engines per role:

- **Subscription** (default) — all Claude Code CLI, `$0` marginal, unchanged.
- **Codex** — the same deal on your *other* subscription: the OpenAI `codex` CLI runs every role, so a
  run costs `$0` marginal and leaves the Claude weekly limit completely untouched. No API key — it uses
  the `codex` login you already have. Pick **Luna**, **Terra** (default), or **Sol** under
  **Settings → Engine & Keys**; the run's effort preset maps straight onto that model's reasoning level
  (`low`→`max`), clamped to what the model actually offers.
- **Budget** — cheap BYOK models (DeepSeek/GLM class) research the angles; your subscription Opus
  synthesizes at `$0` marginal. Angles are ~80–90% of a run's tokens, so this is the efficient split.
- **Full BYOK** — every step on BYOK models, so the weekly limit stays entirely untouched.

Codex, Budget and Full BYOK are experimental and hidden by default; show them with
`defaults write Quorum experimentalRunProfiles -bool YES` and a relaunch.

Codex stays disabled until the `codex` CLI is on your PATH and signed in. Budget and Full BYOK stay
disabled until you add keys under **Settings → Engine & Keys** (stored in the
macOS Keychain — never in files, argv, logs, or run transcripts). Angles run on a bundled
`quorum-engine` binary that speaks the same stream protocol as the CLI, talks to the
[Vercel AI SDK](https://sdk.vercel.ai) (`provider/model-id`, e.g. `deepseek/deepseek-chat`), and does
its own web search (Tavily or Brave). A topic then researches for roughly **$0.10–$1** on cheap models
versus ~$10 of metered Claude. Its bundled, user-overridable price table lives in `engine/README.md`.

**Own search on the subscription path too.** Add just a search key (Tavily/Brave) and even Subscription
runs route web search through it (~$3–8/1k) instead of Anthropic's ~$10/1k server WebSearch. No search
key → built-in WebSearch, exactly as before — the zero-setup promise never depends on it.

**Quality caveat.** Cheap models' citation discipline is unproven, so Budget runs lean on the same
verify pass and confidence tags, and every report stamps the profile plus a per-role model + token +
dollar ledger so a $1 run and a $10 run are never confusable. Project-context topics always use the CLI
(the engine is web-only); published benchmark arms stay pinned to pure Claude.

## Benchmark

Two runs on 2026-07-04 put Quorum (Sonnet 5) against two baselines on the same four questions spanning
chemistry and tech — PFAS destruction, RAG vs. long-context, PQC migration, and AI training chips. A
third Claude call judged the writeups **blind** (order randomized, told not to reward length) on
groundedness, comprehensiveness, honesty, and clarity. Full method, prompts, and raw writeups live in
[`Sources/Quorum/Benchmark.swift`](Sources/Quorum/Benchmark.swift) and `.scratch/benchmark/<stamp>/`.

- **vs. plain Claude Code** — same model, effort, and read-only tools on both arms, so the **only**
  variable is the fan-out. This run isolates architecture — but the plain arm is a *vanilla* call, not
  Claude Code's `/deep-research` skill (see limitations).
- **vs. ChatGPT Deep Research** (GPT-5.5, highest thinking) — product vs. product, so a win here
  **isn't** attributable to architecture. Quorum ran on Sonnet 5, smaller than DR's GPT-5.5.

Quorum is the shared opponent in both blind matchups: each baseline was judged head-to-head against the
**identical** Quorum writeups (never against each other), and the judge re-scored Quorum in each
session — so its two columns can differ.

| Metric                         | Plain Claude Code | ChatGPT Deep Research | Quorum        |
| ------------------------------ | ----------------- | --------------------- | ------------- |
| Blind judge wins               | 0 / 4             | 0 / 4                 | **4 / 4**     |
| Groundedness                   | 6.5               | 6.0                   | **8.3 / 8.0** |
| Comprehensiveness              | 6.8               | **8.5**               | **9.5** / 8.0 |
| Honesty                        | 6.8               | 6.3                   | **9.0 / 9.0** |
| Clarity                        | **9.0**           | 5.5                   | 6.3 / **8.0** |
| Distinct sources cited (avg/Q) | ~10               | ~36                   | ~38           |

_Axis rows are blind-judge averages (0–10) over the four questions; **bold** marks the winner of that
matchup. Quorum's two numbers are its score **vs. plain Claude / vs. Deep Research**. "Sources" counts
distinct source URLs in each final judged writeup._

**Read it as:** Quorum wins groundedness and honesty in both matchups, cites ~4× more distinct sources
than a single plain-Claude call, and matches Deep Research on source breadth. Its one consistent
weakness is **clarity** — reconciling N writeups runs longer and messier, and plain Claude beat it on
clarity all four times. Comprehensiveness splits: Quorum crushes plain Claude but loses to Deep
Research's broader coverage and bigger tables. That DR keeps losing honesty and groundedness anyway
suggests the edge comes from the **architecture** — conflict flags, confidence levels, citation
checks — not raw model power.

### Honest limitations

- **n = 4** — a spot check, not a statistically powered study.
- **The plain-Claude arm didn't use `/deep-research`.** Claude Code ships a `/deep-research` skill that
  itself fans out searches, adversarially verifies claims, and writes a cited report — much closer to
  what Quorum does. The baseline was a plain call without it, so this shows Quorum beating *vanilla*
  Claude Code, not its strongest research mode. That fairer bar is untested.
- **LLM judge** — Claude judging, with known length/confidence bias, and Quorum's synthesis is
  structurally longer. Next step validate with multiple models
  ([#3](https://github.com/krzysztoff1/quorum/issues/3)).
- **Not all wins are equally strong** — Q1-PFAS, Q2-RAG, and Q3-PQC reward conflict tracking and
  confidence discipline and are clearer wins than Q4-chips, where ecosystem breadth favors the baselines.
- **Only the plain-Claude run isolates architecture**; the Deep Research comparison is the whole
  product, Claude scoring Claude-family output against OpenAI's.

## How it works

```
   your question  +  prior notes from your brain (context)
          │
          ▼
   planner decomposes into N angles   ◀─ you review & edit the plan before any spend
          │
          ▼
   ┌── angle 1 ─ agent (read-only, blind) ─┐
   ├── angle 2 ─ agent (read-only, blind) ─┤   run in parallel,
   ├── angle 3 ─ agent (read-only, blind) ─┤   each blind to the others
   └── angle N ─ agent (read-only, blind) ─┘
          │                         ▲
          ▼                         │  round 2+ re-fans
   summariser ─ reconcile + ground cites + flag conflicts/gaps
          │                         │  on the unresolved bits
          ├── unresolved? ──────────┘
          ▼  (clean)
   one cited note (new or *extended*) ─▶ filed back into your brain
```

1. **Pick a project folder to be your brain.** Notes and run artifacts live here, and your prior notes
   are read back in as context on every new question, so each run builds on what you already know.
2. **Ask, then review the plan.** A cheap planner splits your question into N complementary angles.
   Edit, add, or drop any of them before you spend anything.
3. **Fan out.** Each angle gets its own parallel agent, blind to the others, under a live supervisor
   with spend and time limits.
4. **Synthesise, then deepen.** One summariser reconciles every angle into a single cited note, checks
   its citations, and flags conflicts and gaps. If any remain, the next round fans out again on just
   those, so the research deepens over several rounds.
5. **Wake up to it.** The note is filed into your brain, with the digest, transcripts, and each angle's
   writeup on disk, and every thread stays resumable in Claude Code so you can pick up where it stopped.

Runs are shown **live** in a radial fan-out view (planner → angle nodes → synthesis, each streaming its
trace), several can run at once, and a menu-bar item shows progress with a **Stop all**. Cancelling
hands back the partial findings gathered so far.

## Build / run / test

```sh
swift test          # the whole engine's behavior, deterministic, no network, no spend
swift build         # builds QuorumCore + the app
swift run Quorum    # launch the app
```

**Requires:** macOS 14+, Swift 6 toolchain (Xcode), and the **Claude Code CLI** installed and signed in
(`claude` on your `PATH`). Quorum reuses that login — no second credential.

*Budget / Full BYOK only:* build the sidecar and point the app at it in dev —
`scripts/bundle-engine.sh` (→ `engine/dist/quorum-engine`), then run with
`QUORUM_ENGINE_BIN=$PWD/engine/dist/quorum-engine swift run Quorum`. Pass a `.app` path to the same
script to stage the binary into a bundle's `Contents/Resources` — a shipped `.app` carries it, so users
never do this. The app looks in a fixed order — `QUORUM_ENGINE_BIN`, the bundle, then
`engine/dist/quorum-engine` in the checkout `swift run` was launched from — and handshakes with each
(`quorum-engine version`); a binary speaking another protocol is skipped and named. With no usable engine
the run falls back to the in-process pipeline, and the home screen, the live header, the digest and
report.json all say so and why. **Rebuild the engine after pulling** — a stale `engine/dist` is rejected.

> **Dry run (dev only):** a **Mock TS core** toggle appears in settings under `swift run Quorum`. It drives
> the next run from a checked-in engine transcript — the real new-core pipeline (parse → live canvas →
> per-round persist → digest → History) with no binary, no keys and no spend. `QUORUM_DRY_RUN=1 swift run
> Quorum` additionally swaps the in-process executor for a canned one (also what `--benchmark --dry-run`
> uses). Both are absent from a shipped `.app`.
>
> The transcript is a full three-round dive on one real question, deliberately messy so the hard states are
> reachable offline: four parallel angles of which one errors and one halts on its cap, a mid-run spawn the
> reader approves plus one the gate refuses and one that expires unanswered, seven sources across every
> capture tier (a paginated PDF, a degraded tag-soup extraction, a failed write, a search-result-only URL),
> every rung of the quote-match ladder, three validator rounds whose objections buy the later rounds — one
> of which overturns a round-1 claim — a quote the sweep badges ⚠, critics skipped once the validation
> reserve runs out, and a reconciled answer that ends `inconclusive` with an objection still standing.
> Regenerate it with `python3 scripts/generate-mock-run.py`, which derives the source ids, UTF-16 quote
> offsets and page tables from the snapshots rather than trusting hand-typed numbers.
>
> Dev launch runs the raw executable (no bundle id → local notifications are skipped, generic app name).

## Shape

The three roles — orchestrator, supervisor, UI — are split across one seam, so the research engine is
pure and unit-tested.

- **`Sources/QuorumCore`** — pure logic, no AppKit, fully tested behind the `ResearchExecutor` seam:
  - `FanOut` — `planAngles` + `runFanOut`: decompose one question into N angles, run them as _blind_
    parallel agents (`withTaskGroup`), synthesise, and ground the citations. This is the core loop;
    the app runs it iteratively — round 2+ re-fans onto the prior synthesis's unresolved conflicts and gaps.
  - `GuardrailMapper` — preset + guardrails → a **read-only** run config with the least privilege each
    role needs.
  - `Supervisor` — enforces the spend wall (streamed cost ≥ cap) and time wall (clock race), and
    preserves the last **partial** findings on a kill. `RunLedger` makes the aggregate cap a hard wall.
  - `DiskFindingsStore` — the second-brain core: `notes/<slug>.md` (extended over time) + per-run
    artifacts in `runs/<stamp>/`. Every disk write happens here; the research run never writes.
  - `RunProfile` + `CLIInvocation` / `EngineInvocation` — the profile→executor routing and the exact,
    snapshot-tested argv each backend spawns; `ResearchPrompts` is the one research contract both share.
  - `Reporter`, `Preflight`, `Clocks` (`SystemClock`/`TestClock`), `ResearchOutputParser` (+ the per-topic
    token/cost **usage ledger** every run records, on both executors), `Mention`.
- **`Sources/Quorum`** — the SwiftUI app + the _only_ impure code:
  - `ClaudeCodeExecutor` — the real `claude` subprocess (the substitutable seam; tests fake it). Also
    conforms to `AnglePlanner` and handles the synthesis/verify roles.
  - `EngineExecutor` — the BYOK sidecar seam (Budget / Full BYOK); `RoutingExecutor` picks CLI vs engine
    per role. Both share `StreamingSubprocess` + `ResearchStream` (launch, stream, cancel-kill, cost).
  - `Keychain` — provider + search keys, injected into the engine's environment only (never argv/logs).
  - `DryRunExecutor` — the free, canned stand-in for dev.
  - `MacServices` — IOKit sleep-prevention, `UserNotifications`, the CLI probe.
  - `AppModel` + `Views` — project pick → ask → review angles → live radial fan-out → digest + history,
    plus per-run chat, a **Notes** browser/editor over the project's markdown (folder tree +
    [MarkdownEngine](https://github.com/nodes-app/swift-markdown-engine) live editor), a menu-bar status
    item, and a Dock badge.
- **`engine/`** — the optional TypeScript/Bun `quorum-engine` sidecar for Budget / Full BYOK: cheap
  models via the [Vercel AI SDK](https://sdk.vercel.ai) + own web search (Tavily/Brave/Jina), emitting
  the same NDJSON stream the app already parses. Built and tested on its own (`cd engine && bun test`),
  shipped as a compiled binary in the app bundle. A checked-in fixture keeps the Swift and TS sides in sync.

## The brain on disk

Everything lands in `<your-project>/Quorum/`:

```
Quorum/
├── notes/                         # the durable second brain — one note per topic, extended over time
│   └── <slug>.md                  #   YAML frontmatter + dated sections + [[wikilinks]]
└── runs/
    └── <title> <yyyy-MM-dd-HHmmss>/
        ├── digest.md              # the skimmable morning brief
        ├── report.json            # the structured run report
        ├── <angle>.md             # each angle's full writeup
        └── <angle>.transcript.md  # raw sources & logs, kept out of the note
```

Plain markdown — commit it, grep it, or open the folder as an Obsidian vault.

## Getting started

```sh
git clone https://github.com/krzysztoff1/quorum.git && cd quorum
swift run Quorum
```

On first launch, pick a project folder to be your brain and ask a question. There's no API key or extra
setup — Quorum uses your existing Claude Code CLI login. (Needs macOS 14+, the Swift 6 toolchain, and
`claude` signed in on your `PATH`.)

# Quorum

[![Tests](https://github.com/krzysztoff1/quorum/actions/workflows/tests.yml/badge.svg)](https://github.com/krzysztoff1/quorum/actions/workflows/tests.yml)
![Tests](https://img.shields.io/badge/tests-112-brightgreen)

**Ask one question. Quorum runs blind, parallel, read-only research agents and reconciles the
results into one cited note that grows into a second brain.** It's a native macOS app: an
**orchestrator, supervisor, and UI** over the Claude Code CLI. The agents are read-only, so a failed
run wastes spend but can't touch your files.

---

## Demo

<!-- Drop the video here: drag an .mp4/.mov onto this line in GitHub's editor to get a
     user-attachments URL, or replace this block with a thumbnail linking to the clip. -->

_Demo video coming soon._

---

## Why Quorum

- **Explore every angle.** One question becomes N blind, parallel angles. A final summariser
  reconciles them, weights sources by cross-angle support, and flags conflicts.

- **Read-only and cost-capped.** Agents can only use `WebSearch`, `WebFetch`, and optional
  `Read`/`Grep`/`Glob`. A supervisor stops the run on spend or time limits, so failures stay bounded.

- **Your research compounds.** Findings land in a durable note per topic, and later runs extend that
  note instead of duplicating it.

- **Lint your brain.** A single **Lint** pass reads every note and reports contradictions, gaps,
  missing `[[wikilinks]]`, and follow-up questions.

- **Ask your brain.** A quick question is answered from your **own notes first**; web search fills
  only the gaps.

- **Cited, with confidence levels.** Every claim carries a confidence level and sources. A
  deterministic citation check flags unsupported citations, and weak answers are marked `inconclusive`.

- **Plain files you own.** Notes are markdown with YAML frontmatter and `[[wikilinks]]` in your
  project folder. They work with `git`, `grep`, Obsidian, and Logseq. No database and no cloud.

- **Browse and edit in-app.** A **Notes** sidebar mirrors your markdown tree, lets you edit notes in
  place, and keeps YAML frontmatter hidden. Rendering is powered by
  [SwiftMarkdownEngine](https://github.com/nodes-app/swift-markdown-engine).

- **One cost dial.** Four presets trade cost for depth, and you set per-topic and per-run spend caps.
  You can also pick the model for each role and see its list price.

- **No second login.** Quorum reuses your existing Claude Code CLI sign-in, so there’s no extra API
  key.

- **Built on the Claude Code CLI, so you can take over.** Every angle and synthesis runs as a real
  Claude Code CLI session, so you can resume any thread with `claude --resume`.

## Benchmark

Two runs on 2026-07-04 used Sonnet 5 on four questions spanning chemistry and tech: PFAS destruction,
RAG vs. long-context, PQC migration, and AI training chips. A third Claude call judged the writeups
**blind** on groundedness, comprehensiveness, honesty, and clarity. Full method, prompts, and raw
writeups live in
[`Sources/Quorum/Benchmark.swift`](Sources/Quorum/Benchmark.swift) and `.scratch/benchmark/<stamp>/`.

### vs. plain Claude Code — architecture isolated

Same model, effort, and read-only tools on both arms, so the **only** variable is the fan-out.
**Quorum won all four.**

| Question | Winner | Traditional $ / time | Quorum $ / time |
|---|---|---|---|
| PFAS destruction | Quorum | $0.41 / 1.2m | $11.93 / 15.6m |
| RAG vs. long-context | Quorum | $0.21 / 0.7m | $9.51 / 14.0m |
| Post-quantum crypto | Quorum | $0.21 / 0.8m | $9.26 / 10.3m |
| AI training chips | Quorum | $0.37 / 1.0m | $11.06 / 13.8m |

Average judge score (0–10):

| Axis | Plain Claude | Quorum |
|---|---|---|
| Groundedness | 6.5 | **8.3** |
| Comprehensiveness | 6.8 | **9.5** |
| Honesty | 6.8 | **9.0** |
| Clarity | **9.0** | 6.3 |

**Objective:** Quorum costs ~35× more ($41.77 vs. $1.19 total) and takes ~10–16 min/question vs. under
two minutes. **Subjective:** it is more rigorous, but also messier and slower.

**Stricter read:** Q1-PFAS, Q2-RAG vs. long-context, and Q3-PQC are clear Quorum wins because the
questions reward conflict tracking, attribution, and confidence discipline. Q4-chips is the weakest
win: Deep Research is broader and more polished on ecosystem coverage. Quorum is more trustworthy on
research-heavy questions, not universally better prose.

### vs. ChatGPT Deep Research (GPT-5.5, highest thinking)

Product vs. product — different model, tools, and agent — so a win here **isn't** attributable to
architecture. Quorum ran on **Sonnet 5**, smaller and cheaper than Deep Research's **GPT-5.5 on highest
thinking**. Same 4 questions, Quorum arm reused from the run above. **Quorum won all four, but read it
skeptically.**

Average judge score (0–10):

| Axis | Deep Research | Quorum |
|---|---|---|
| Groundedness | 6.0 | **8.0** |
| Comprehensiveness | **8.5** | 8.0 |
| Honesty | 6.3 | **9.0** |
| Clarity | 5.5 | **8.0** |

The pattern flips from the internal run: **Deep Research wins comprehensiveness** on broader coverage
and bigger tables, while **Quorum wins honesty and groundedness everywhere**. That suggests the edge
comes from the architecture — conflict flags, confidence levels, citation checks — not raw model power.
Still, the judge is Claude scoring Claude-family output against OpenAI's, so treat this as a promising
signal, not a final headline.

### Honest limitations

- **n = 4** — a spot check, not a statistically powered study.
- **LLM judge** — Claude judging, with known length/confidence bias, and Quorum's synthesis is
  structurally longer. Read the raw `qN-*.md` writeups yourself.
- **Clarity is a genuine weakness** — against plain Claude, Quorum lost it all four times.
- **Not all wins are equally strong** — Q1-Q3 are stronger than Q4 in the Deep Research comparison.
- **Only the internal run isolates architecture**; the Deep Research comparison is the whole product,
  Claude-judged, and caveated above.

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

Once you've saved a number of notes, run **Lint** to check them against each other; it lists the
contradictions, gaps, and missing links to fix.

## Build / run / test

```sh
swift test          # the whole engine's behavior, deterministic, no network, no spend
swift build         # builds QuorumCore + the app
swift run Quorum    # launch the app
```

**Requires:** macOS 14+, Swift 6 toolchain (Xcode), and the **Claude Code CLI** installed and signed in
(`claude` on your `PATH`). Quorum reuses that login — no second credential.

> **Dry run (dev only):** a "Dry run — no API calls, no spend" toggle appears under `swift run Quorum`.
> It swaps in a canned engine that spawns no `claude` subprocess and reports $0, so you can exercise the
> full plan → fan-out → synthesis → storage → UI flow for free. Pre-enable with
> `QUORUM_DRY_RUN=1 swift run Quorum`. The toggle and engine are absent from a shipped `.app`.
>
> Dev launch runs the raw executable (no bundle id → local notifications are skipped, generic app name).

## Shape

The three roles — orchestrator, supervisor, UI — are split across one seam, so the research engine is
pure and unit-tested.

- **`Sources/QuorumCore`** — pure logic, no AppKit, fully tested behind the `ResearchExecutor` seam:
  - `FanOut` — `planAngles` + `runFanOut`: decompose one question into N angles, run them as *blind*
    parallel agents (`withTaskGroup`), synthesise, and ground the citations. This is the core loop;
    the app runs it iteratively — round 2+ re-fans onto the prior synthesis's unresolved conflicts and gaps.
  - `GuardrailMapper` — preset + guardrails → a **read-only** run config with the least privilege each
    role needs.
  - `Supervisor` — enforces the spend wall (streamed cost ≥ cap) and time wall (clock race), and
    preserves the last **partial** findings on a kill. `RunLedger` makes the aggregate cap a hard wall.
  - `DiskFindingsStore` — the second-brain core: `notes/<slug>.md` (extended over time) + per-run
    artifacts in `runs/<stamp>/`. Every disk write happens here; the research run never writes.
  - `Reporter`, `Preflight`, `Clocks` (`SystemClock`/`TestClock`), `ResearchOutputParser`, `Mention`.
- **`Sources/Quorum`** — the SwiftUI app + the *only* impure code:
  - `ClaudeCodeExecutor` — the real `claude` subprocess (the substitutable seam; tests fake it). Also
    conforms to `AnglePlanner` and handles the synthesis/verify roles.
  - `DryRunExecutor` — the free, canned stand-in for dev.
  - `MacServices` — IOKit sleep-prevention, `UserNotifications`, the CLI probe.
  - `AppModel` + `Views` — project pick → ask → review angles → live radial fan-out → digest + history,
    plus per-run chat, a **Notes** browser/editor over the project's markdown (folder tree +
    [MarkdownEngine](https://github.com/nodes-app/swift-markdown-engine) live editor), a menu-bar status
    item, and a Dock badge.

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

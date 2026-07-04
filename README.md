# Quorum

**Ask one question. Quorum runs several blind, parallel, read-only research agents and reconciles
their findings into one cited note that builds up over time into a second brain.** It's a native
macOS app: an **orchestrator, supervisor, and UI** over the Claude Code CLI. The research agents are
read-only, so a failed run wastes a little spend but can't touch your files.

---

## Demo

<!-- Drop the video here: drag an .mp4/.mov onto this line in GitHub's editor to get a
     user-attachments URL, or replace this block with a thumbnail linking to the clip. -->

_Demo video coming soon._

---

## Why Quorum

- **Explore every angle.** One question is split into N distinct angles. Each is researched by its
  **own parallel agent, blind to the others**, so the angles cross-check each other rather than
  sharing one agent's assumptions. A final summariser reconciles them, weights each source by how many
  angles cited it independently, and reports disagreements between angles as conflicts.

- **Read-only and cost-capped.** Research agents get read-only tools only (`WebSearch`, `WebFetch`,
  and `Read`/`Grep`/`Glob` if you opt in). They can't write, edit, or run commands. A live supervisor
  kills the subprocess as soon as a **spend** or **time** limit is hit, and the per-agent budgets are
  sized so their total can't exceed the run's cost cap. A run that goes wrong returns an empty result;
  it can't damage a repo or run up an unexpected bill.

- **Your research compounds.** Findings are filed into a durable note per topic, and later runs on the
  same topic **extend that note rather than duplicating it**. Ask a related question next week and the
  prior notes are fed back in as context, so each run builds on the last.

- **Lint your brain.** A single **Lint** pass reads every note you've saved and reports across all of
  them: claims that contradict each other, gaps a web search can fill, related notes that aren't
  linked with `[[wikilinks]]` yet, and questions worth researching next. Each finding is a proposal
  you accept or ignore; accepted changes go through the store, and the Lint agent itself only reads.

- **Ask your brain.** A quick question is answered from your **own notes first**: a matcher pre-selects
  the most related notes, and the agent reads those before it searches the web, which it uses only to
  fill what the notes don't cover.

- **Cited, with confidence levels.** Every claim carries a confidence level and its sources. A
  deterministic citation check flags any source the synthesis cites that none of the underlying angles
  cited. A topic with no solid answer is reported as `inconclusive`.

- **Plain files you own.** Notes are markdown (YAML frontmatter + `[[wikilinks]]`) written into your
  project folder. They work with `git` and `grep` and open directly in Obsidian or Logseq. No database
  and no cloud.

- **Browse and edit in-app.** A **Notes** sidebar mirrors your project's markdown files as a folder
  tree; open any to read it live-styled — with syntax-highlighted code blocks — and edit it in place,
  saved straight back to disk. The editor shows the note body only — YAML frontmatter is hidden and
  preserved on disk. Rendering and editing are powered by
  [SwiftMarkdownEngine](https://github.com/nodes-app/swift-markdown-engine).

- **One cost dial.** A 4-tier preset (Draft → Standard → Deep → Max) trades cost for depth, and you set
  the per-topic and per-run spend caps. You pick the model for each role (research vs. chat) and see its
  list price in the picker.

- **No second login.** Quorum reuses your existing Claude Code CLI sign-in, so there's no extra API key
  or credential. It checks the CLI at setup and tells you up front if anything's missing.

- **Built on the Claude Code CLI, so you can take over.** There's no reimplemented agent loop: every
  angle and the synthesis run as real Claude Code CLI sessions, so each one is resumable. Open any
  thread in your terminal with `claude --resume` (or the in-app chat) and keep going with the full
  Claude Code toolset, subagents, and your own follow-ups. Quorum does the overnight fan-out; you drive
  whatever comes next.

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
swift test          # 87 tests — the whole engine's behavior, deterministic, no network, no spend
swift build         # builds QuorumCore + the app
swift run Quorum    # launch the app
./make-app.sh       # assemble a real Quorum.app bundle (ad-hoc signed for this Mac)
```

**Requires:** macOS 14+, Swift 6 toolchain (Xcode), and the **Claude Code CLI** installed and signed in
(`claude` on your `PATH`). Quorum reuses that login — no second credential.

> **Dry run (dev only):** a "Dry run — no API calls, no spend" toggle appears under `swift run Quorum`.
> It swaps in a canned engine that spawns no `claude` subprocess and reports $0, so you can exercise the
> full plan → fan-out → synthesis → storage → UI flow for free. Pre-enable with
> `QUORUM_DRY_RUN=1 swift run Quorum`. The toggle and engine are absent from a shipped `.app`.
>
> Dev launch runs the raw executable (no bundle id → local notifications are skipped, generic app name).
> `./make-app.sh` produces the real bundle; Developer-ID signing + notarization for distribution needs
> your signing identity and is out of scope here.

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
`claude` signed in on your `PATH`.) For a real double-click `.app`, run `./make-app.sh` instead.

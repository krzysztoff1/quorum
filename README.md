# Quorum

**Ask one question. Get back a fan-out of blind, parallel, read-only research agents — reconciled
into a single cited note that compounds into a second brain.** A native macOS app — an
**orchestrator + supervisor + UI** over the Claude Code CLI. Read-only *by construction*: the worst
case is "nothing," never "damage."

---

## Why Quorum

- **Explore every angle, not just the first.** One question is decomposed into N distinct angles, each
  researched by its **own parallel agent that never sees a sibling's findings** — so you get genuine
  breadth and cross-checking instead of one agent's tunnel vision. A final summariser reconciles them,
  weights sources by how many angles independently cited them, and **surfaces conflicts as data**
  rather than dissolving them into confident prose.

- **Read-only by construction — walls, not warnings.** Research agents only ever receive read-only
  tools (`WebSearch`, `WebFetch`, and `Read`/`Grep`/`Glob` when you opt in). They *cannot* write, edit,
  or run commands. A live supervisor kills the subprocess the instant a **spend** or **time** wall is
  crossed, and the run's aggregate cost cap is a hard ceiling *by construction* (per-agent budgets can't
  sum past it). The worst outcome is an empty result — never a damaged repo or a surprise bill.

- **Your research compounds.** Findings are filed into a durable, per-topic note that is **extended
  over time, not duplicated**. Ask a related question next week and the prior notes are fed back in as
  context. Your knowledge deepens with every run instead of scattering across throwaway chats.

- **Ask your brain, not just the web.** A quick question is answered from your *own* notes first — the
  matcher pre-selects the most related notes and the agent reads those before it touches the web, using
  it only for the gap. Your accumulated research is the first source, not an afterthought.

- **Cited and honest, or it says so.** Every claim carries a confidence level and its sources. A
  deterministic citation-grounding tripwire flags any source the synthesis used that no underlying
  angle actually cited. A topic with nothing solid is reported `inconclusive` — never dressed up.

- **Portable, greppable, yours.** Notes are plain markdown (YAML frontmatter + `[[wikilinks]]`) written
  straight into your project folder. `git`-able, `grep`-able, and they drop cleanly into Obsidian or
  Logseq. No database, no lock-in, no cloud.

- **One cost dial, set once.** A 4-tier preset (Draft → Standard → Deep → Max) trades cost for depth;
  per-topic and per-run spend caps are yours to set. You pick the model per role (research vs. chat)
  and see its list price right in the picker.

- **No second login.** Quorum reuses your existing Claude Code CLI sign-in — no extra API key, no
  separate credential. It preflights the CLI at setup and tells you if anything's missing (never
  silently at 2am).

## How it works

```
                    ┌── angle 1 ─ agent (read-only, blind) ─┐
   your question ──▶│── angle 2 ─ agent (read-only, blind) ─┤──▶ summariser ──▶ one cited note
   (you review &    │── angle 3 ─ agent (read-only, blind) ─┤    (reconcile,     (created or
    edit the plan)  └── angle N ─ agent (read-only, blind) ─┘     ground cites)   *extended*)
```

1. **Pick a project folder** — this is the "brain" where notes and run artifacts live.
2. **Ask a question.** A cheap planner decomposes it into N angles, reading your existing notes so the
   angles *complement* what you already know.
3. **Review the plan.** Edit, add, or remove angles before a cent is spent (the flow is review-first).
4. **Run.** The angles research in parallel — each blind to the others — under active supervision.
5. **Synthesise.** One summariser reconciles all angles into a single note, grounds its citations, and
   flags any conflicts and gaps.
6. **Deepen (iterative).** If the synthesis leaves unresolved conflicts or gaps, the dive fans out
   again — round 2+ chases exactly those, so your research grows round over round instead of stopping
   at the first pass.
7. **Wake up to it.** The note is filed into your brain; a skimmable digest, the full transcripts, and
   each angle's writeup are all on disk. **Pick up any thread in a Claude Code session** — the whole
   reconciled findings *or* a single angle — since every angle and the synthesis keep their own
   resumable session. Continue right in the in-app chat, or open it in your terminal
   (`claude --resume`, fork optional).

Runs are watched **live** in a radial fan-out visualization (planner → angle nodes → synthesis, each
streaming its trace), several can run **concurrently**, and a menu-bar item shows progress with a
**Stop all**. Cancelling always hands back the partial findings gathered so far.

## Build / run / test

```sh
swift test          # 78 tests — the whole engine's behavior, deterministic, no network, no spend
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

Those three roles — orchestrator, supervisor, UI — are split across one seam so the entire research
engine is pure and unit-tested.

- **`Sources/QuorumCore`** — pure logic, no AppKit, fully tested behind the `ResearchExecutor` seam:
  - `FanOut` — `planAngles` + `runFanOut`: decompose one question into N angles, run them as *blind*
    parallel agents (`withTaskGroup`), synthesise, and ground the citations. This is the core loop;
    the app runs it iteratively — round 2+ re-fans onto the prior synthesis's unresolved conflicts and gaps.
  - `GuardrailMapper` — preset + guardrails → a **read-only** run config. Least-power *by construction*.
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
    plus per-run chat, a menu-bar status item, and a Dock badge.

## Guardrails ("walls, not warnings")

Quorum borrows its guardrail model from the factory **andon** cord — the supervisor *pulls the cord*
(kills the subprocess) the moment something crosses a line. Three layers, defense in depth:

1. **Least power up front.** The run only ever gets read-only tools. It is *incapable* of writing or
   running commands before it starts — enforced in `GuardrailMapper`, not by asking nicely.
2. **Active supervision.** The supervisor kills the subprocess on a spend/time breach and keeps the
   partial. A per-agent `--max-budget-usd` also makes the CLI hard-cap its own spend, and the run cap is
   sliced across agents so live per-agent caps can never sum past it.
3. **Verification is required and surfaced.** Findings carry confidence + citations; a citation with no
   supporting angle is flagged; a topic with nothing solid is reported `inconclusive`, never dressed up.

### The cost/quality dial

| Preset       | Effort  | ~Sources | For…                                    |
|--------------|---------|----------|-----------------------------------------|
| **Draft**    | `low`   | ~5       | cheap dry-runs, quick sanity checks     |
| **Standard** | `high`  | ~15      | the sensible default                    |
| **Deep**     | `xhigh` | ~30      | the agentic-research sweet spot         |
| **Max**      | `max`   | ~50+     | topics that really matter               |

Optionally shape the synthesis into a structured **deliverable** — *general* (default),
*comparison matrix*, *decision brief*, or *literature review* — without changing the research engine.

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

Plain, portable markdown — commit it, grep it, or open the folder as an Obsidian vault.

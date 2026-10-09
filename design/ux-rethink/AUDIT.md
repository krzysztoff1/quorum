# Quorum UX audit — 2026-10-09

What a person meets today, from launch to "I found that answer from last Tuesday". It's based on the
code on `main` (`4f16287`), PRDs 00–09, the real `andon` project folder (22 runs, 22 notes) and
screenshots of the running app in `screens/`.

The short version: Quorum shows the user its pipeline, not their question. Every engine concept
(angle, round, synthesis, verdict, profile, preset, template, topic, note) has its own control or
surface, and the one thing the owner wants (a short answer they can trust) is three clicks deep
behind a graph.

---

## 1. Screens that exist today

| # | Surface | Where in code | What it is |
|---|---|---|---|
| S1 | **Project picker** | `ContentView.sidebar` menu, `AppModel.chooseProject` | Folder = "brain". Sidebar top, ⌘K, empty state |
| S2 | **Compose home** ("Explore every angle") | `ComposeView.home` | Question box, angle count 2–8, cost ceiling, `Plan N angles`, warning banners |
| S3 | **Run settings** disclosure | `ComposeView.settingsSection` | 12 controls: engine profile, effort preset, spend caps, deliverable template, time wall, read-project toggle, round cap, 3 model pickers, dev mock toggle |
| S4 | **Plan review canvas** | `FanOutView` (draft) + `ResearchGraphView` | Planner streams on a question node; editable angle cards, add/remove, fork to Claude Code, `Research N angles` CTA, Discard |
| S5 | **Live run canvas** | `FanOutView` (active) | Graph of angles → synthesis → verdicts → objection rounds; header phase label, pending-approval pill, Stop; rail reads a node |
| S6 | **Spawn approval cards + bulk bar** | `GraphNodeCard`, `BulkApprovals` | Dashed "the run wants to research X, ~$" cards, Approve/Reject, Approve all |
| S7 | **Dig-down sheet** | `DigDownSheet` | "Research further from here" modal from a node |
| S8 | **Finished run** | `FinishedRunView` | Header strip (status, reconciled, question, headline, ~10 facts) over the same graph; rail auto-opens on the synthesis |
| S9 | **Reading rail** with tabs Answer / Audit / Validation | `ReadingRail` | Cited reader, `SynthesisSummary` audit, `ValidationTab` |
| S10 | **Topic detail** ("Note & chat") | `TopicDetailView` (NavigationStack push) | Tabs Note / Edit / Chat; toolbar Continue in Claude Code, Fork, Reveal, Summary inspector |
| S11 | **Citation inspector** | `CitedSourceInspector` | Snapshot/PDF/live page with the quote highlighted |
| S12 | **Source inspector** | `SourceInspector` | Plain web view for a URL |
| S13 | **Notes browser + editor** | `NoteTreeRows`, `NoteEditorView` | Every `.md` under the project folder, tree, rename/duplicate/trash |
| S14 | **Chat** | `ChatView` | Per-topic Claude session (resume or seeded), @-mentions, attachments |
| S15 | **⌘K quick switcher** | `QuickSwitchView` | Flat list: commands, recent projects, every run ("Chat"), live nodes, every note |
| S16 | **Settings (⌘,)** | `SettingsView` | General (terminal app), Engine & Keys (5 model pickers, 6 key fields), How to Use |
| S17 | **Menu bar extra + Dock badge** | `QuorumApp`, `DockStatus` | "n researching", "n waiting on you", Stop all |

That's **17 surfaces** for one job: ask a question, get an answer.

## 2. The journey today, step by step

1. **Launch.** The last project folder reopens. On the owner's machine that is the Quorum repo itself,
   so the sidebar's Notes section lists `engine/PROTOCOL.md`, `prds/…`, every markdown file in the repo
   ([screens/01](screens/01-current-home.png)). The app follows the system appearance, so it's light
   most of the time. It isn't the calm dark tool it wants to be.
2. **Possible warning.** "quorum-engine not found — this run falls back to the in-process pipeline
   (legacy pipeline — no validation, no evidence captured). Set QUORUM_ENGINE_BIN…": an
   environment variable on the home screen of a product.
3. **Ask.** Type into "What do you want to explore?". Before you can submit, the screen asks
   *How many angles? 2 3 4 5 6 7 8* and shows "up to $40.00 total". The user has to decide how to
   decompose a question they haven't scoped yet.
4. **Optional: Run settings.** One disclosure holds the engine profile (4 options, 3 of them
   irrelevant to the owner), effort preset (Draft "ULTRA low" / Standard / Deep / Max), spend caps,
   deliverable template (General / Comparison / Decision brief / Lit review), per-agent time wall,
   "read this project", round cap 1–8, three model pickers with $/Mtok prices, and a dev toggle. The
   summary line reads `Standard · Sonnet 5 agents · reads project · up to 4 rounds`.
5. **Plan.** `Plan 5 angles` (⌘↩). "Nothing runs until you review." The compose screen turns into a
   canvas: a question node streams the planner, then N editable angle cards appear.
6. **Review.** Edit titles and prompts in place, remove, add, fork an angle into Claude Code, then
   `Research 5 angles`. **This is a mandatory mid-flow approval**: the run can't start without the
   user acting on the plan.
7. **Vague question?** Nothing scopes it. The model's urge to clarify leaks out as the **run title**:
   the titler answered the question instead of titling it. Real run folders on disk:
   *"Zanim zacznę deep research, chciałbym sprecyzować zakres — p…"*, *"I'm not sure what you're
   looking for…"*, *"That looks like a typo!…"*, *"Przepraszam, ale pytanie 'jak zrobic idealne
   menu' jest dla…"*. Seven of 22 runs are titled like this.
8. **Watch.** The run appears in the sidebar under **"Chats"** with a spinner and a phase badge
   (planning / researching / synthesizing / checking / *waiting on you*). The detail becomes the live
   graph. Spawn proposals show up as cards with prices, a pending pill in the header, the menu bar
   and a notification. They no longer block the wave, but they still ask for the user's attention
   mid-run.
9. **Finish.** The Dock shows ✓ and bounces. The finished run opens as the graph
   ([screens/02](screens/02-current-finished-run.png)). The window title is a date ("28 Jul 2026 at
   21:50"), the sidebar says "What Makes A Perfect Res…", and the header says "Reasearch perfect
   restaurant menu": **three names for one run on one screen**. The header strip packs status,
   headline and 8 facts (`4 high · 1 medium · 1 unverified`, `1 conflict`, `4 gaps`, `3 sources`,
   `3 angles`, `3m 34s`, `$1.24 / $40.00`).
10. **Read.** The rail's **Answer** tab shows… the question title and nothing else on this run
    (screens/02). **Audit** ([screens/03](screens/03-current-audit-tab.png)) holds the real content:
    "What was done", "How solid it is", "Open conflicts", "Open questions", "Citation check",
    "Sources". It says `Sources consulted 3` above a list of 20+ source URLs.
11. **Read more.** `Note & chat` pushes a new screen ([screens/04](screens/04-current-note-and-chat.png))
    with the full markdown note: a date-prefixed H1 headline, an italic meta line, the conflicts
    block (the third time you've seen the same conflict), then ~1,500 words. Citations show as
    raw `[^c1]` text here, not chips. The answer the owner wanted is a paragraph somewhere in it.
12. **Follow up.** The Chat tab lives inside the same pushed screen, in a *different* conversation
    model (Claude CLI session, read-only project context), not a Quorum run. Asking "dig deeper on
    menu size" there doesn't research anything; it chats. The research version (dig-down) is a
    hover `+` on a graph node, only while live (post-run dig-down is deferred).
13. **Find it later.** The sidebar "Chats" is a flat date-ordered list of auto-titles, junk test runs
    included (`fsafas`, `bfxcgfdh`). ⌘K ([screens/05](screens/05-current-quick-switch.png)) leads
    with "New run", "Choose Project…", a recent project, then the same flat list labelled "Chat",
    then live graph nodes, then every note. It searches titles only, not answers. Same-topic runs
    sit apart: the menu question exists as 4 runs and 4 notes
    (`jak-zrobic-idealne-menu.md`, `how-to-compose-ideal-restaurant-menu.md`,
    `reaserch-perfect-restaurant-menu.md`, `sprwad-jak-najlepiej-komponowa-menu.md`).

## 3. Friction, ranked

Severity: **P0** stops the owner reaching for Quorum over ChatGPT; **P1** costs a session's goodwill;
**P2** is polish.

### Starting a run

| | Friction | Why it hurts |
|---|---|---|
| P0 | Mandatory plan review (angles must be approved) | Violates "nothing should require the user mid-run". ChatGPT starts on Enter. The angles are the engine's business |
| P0 | No scoping step for vague questions | Vague prompts become clarifier-titled runs that researched a guess. The model *wants* to ask, and there is nowhere to ask |
| P0 | "How many angles? 2–8" asked before anything else | It's an implementation knob, and the owner can't know the right number before scoping |
| P1 | 12 settings in Run settings, 9 more in ⌘, | Profile, preset, template, time wall, rounds and 3 model pickers all answer "how hard should it try?". The owner's real choice is Quick vs Deep |
| P1 | Dollar ceilings shown as the primary cost signal ("up to $40.00") | Runs are on the Claude subscription; the real currency is time and limit usage, not dollars |
| P1 | Engine/env warning on the home screen | Developer diagnostics in the product's front door |
| P2 | "Explore every angle" heading + explainer every time | Marketing copy on a tool used 3×/week |

### Watching a run

| | Friction | Why it hurts |
|---|---|---|
| P0 | The live graph *is* the run screen: no calm progress summary | You must parse a node graph to know "is it nearly done?" |
| P1 | Spawn approvals / pending pill / notification for proposals | Non-blocking now, but they still demand a decision mid-run. Decided direction: nobody needs the user mid-run |
| P1 | Phase vocabulary (planning, synthesizing, grounding, validating, reconciling, awaiting approval) | Pipeline stages, not progress. The user wants "~2 min left" |
| P2 | Progress spread over sidebar badge, Dock badge, menu bar, header | Four partial truths, none says "done at ~14:32" |

### Reading results

| | Friction | Why it hurts |
|---|---|---|
| P0 | The answer is not the first thing on screen | It's a rail tab beside a graph, often empty (screens/02), with the real content in Audit or a pushed note |
| P0 | Too long | The note is a ~1,500-word report. The benchmark judge already said it: "rigor you then have to skim". The owner wants **one short answer** |
| P0 | Six overlapping reading surfaces | header strip, rail Answer, rail Audit, rail Validation, Note tab, digest.md on disk. Conflicts are shown 3× in 3 styles |
| P1 | Confidence is a run-level string (`4 high · 1 medium · 1 unverified`), not attached to claims | You can't tell *which* sentence is the unverified one |
| P1 | Citations: chips in the rail, raw `[^c1]` in the note tab | Same answer, two citation renderings. Trust is the product |
| P1 | Numbers disagree: `3 sources` vs a 20+ URL list | One wrong number makes everything else suspect (RUN-VALIDATION §5) |
| P1 | Three names per run (date, auto-title, question) | Destroys recognition when scanning |
| P2 | Validation is ledger-shaped ("filed / settled by research / still standing") | It reads like an internal audit, not "here is what we're unsure about" |

### Navigation and finding past runs

| | Friction | Why it hurts |
|---|---|---|
| P0 | Runs are called **"Chats"**, notes are a separate tree, chats are a tab inside a run | Three nouns for overlapping things; none is "my questions" |
| P0 | Notes tree = every markdown file in the project folder | The brain folder is the repo; PRDs and READMEs show up as if they were research |
| P1 | Project picker as the first sidebar control | The owner uses one brain. Switching folders is a once-a-year action |
| P1 | No status, recency grouping, or content search in history | "That answer about DPD deliveries last week" can't be found by what it said |
| P1 | Same-topic runs scatter (4 menu runs, 4 notes) | The brain thesis needs questions to *accumulate*; today they fragment |
| P1 | ⌘K is a launcher list, not a command surface | No "ask", no "follow up", no "re-run Deep", no filters, no recent-first |
| P2 | NavigationStack push for Note & chat, then Back | Modal depth inside a split view; you lose the graph and the sidebar context |

## 4. Concepts the user is forced to understand

Every term a user meets in the UI today, grouped by whether they should have to:

**Should never see (engine internals):** angle · angle count · plan · plan review · synthesis ·
reconciled · round · round cap · validator · verdict · objection (as a ledger) · claim sweep · critic ·
spawn · spawn approval · dig-down (as a separate mechanism) · prune · retry · grounding / unvalidated ·
engine profile (Subscription / Codex / Budget / Full BYOK) · effort preset (Draft / Standard / Deep /
Max) · deliverable template · per-agent time wall · spend cap per agent · model choice ×3 (+5 in ⌘,) ·
engine binary / QUORUM_ENGINE_BIN · Mock TS core · Replay.

**Seen today, should merge into one idea:** run + chat + topic + note + digest + report → *a question
and its answer*. Audit + validation + header facts + conflicts block → *how sure we are*.
Citation chip + source inspector + live web view → *the source*.

**Legitimately needed:** a question · its answer · confidence per claim · a conflict · a source quote ·
Quick vs Deep · follow-up.

Roughly **35 concepts today → 7 that matter.** The proposal brings the user-facing list down to
three nouns (**Question, Answer, Source**) and two verbs (**Ask, Follow up**).

## 5. What works and should survive

- **The cited reader + citation inspector.** Click a chip and the source opens with the quote
  highlighted. This is the trust mechanism and the most differentiated thing in the app.
- **Honest badging** (✓ located & supported, ≈ fuzzy, ? unresolved, ⚠ doesn't support): it
  needs to attach to *claims* rather than chips only, but the ladder itself is right.
- **Conflicts surfaced explicitly**: "McKinsey says 1–2 %, vendors say 20 %" is the kind of thing
  ChatGPT smooths over. Keep it, show it once.
- **Concurrent background runs + Dock/menu bar status**: the right instinct for "walk away".
- **The live graph** as an optional "show the work" view; it is the demo, just not the destination.
- **Files the user owns** (`Quorum/notes/*.md`): the brain story, as an export.
- **⌘K exists**, and the user already expects it.

# Quorum UX/IA proposal: an inbox of questions, each a short thread

Status: proposal for the owner to choose a shape and react. Design only, no app code changed.
Companion files: [AUDIT.md](AUDIT.md) (today, with screenshots of the running app in `screens/`).
The mockups live in [`design/ux-rethink/`](../../design/ux-rethink/): HTML at 1440×900 in the dark theme, built on the shared
[`quorum.css`](../../design/ux-rethink/quorum.css) and [`shell.js`](../../design/ux-rethink/shell.js), with PNG exports in [`png/`](../../design/ux-rethink/png/).

| Mockup | Shows | PNG |
|---|---|---|
| [index.html](../../design/ux-rethink/index.html) | Shape comparison A / B / C + journey gallery | — |
| [01-first-run.html](../../design/ux-rethink/01-first-run.html) | Empty state, the one composer, Quick/Deep | [png](../../design/ux-rethink/png/01-first-run.png) |
| [02-scoping.html](../../design/ux-rethink/02-scoping.html) | Scoping chat → resolved question → depth | [png](../../design/ux-rethink/png/02-scoping.png) |
| [03-running.html](../../design/ux-rethink/03-running.html) | Progress card, ETA, early findings | [png](../../design/ux-rethink/png/03-running.png) |
| [03b-show-the-work.html](../../design/ux-rethink/03b-show-the-work.html) | Optional live graph (G) | [png](../../design/ux-rethink/png/03b-show-the-work.png) |
| [08-walk-away.html](../../design/ux-rethink/08-walk-away.html) | Menu bar, notification, Dock badge | [png](../../design/ux-rethink/png/08-walk-away.png) |
| [04-answer.html](../../design/ux-rethink/04-answer.html) | Answer page in the thread, cited chart, source rail | [png](../../design/ux-rethink/png/04-answer.png) |
| [05-switcher.html](../../design/ux-rethink/05-switcher.html) | ⌘K palette over answers and quotes | [png](../../design/ux-rethink/png/05-switcher.png) |
| [06-settings.html](../../design/ux-rethink/06-settings.html) | Settings reduced to six rows | [png](../../design/ux-rethink/png/06-settings.png) |
| [07-alt-conversation.html](../../design/ux-rethink/07-alt-conversation.html) | Shape A sketch, for comparison | [png](../../design/ux-rethink/png/07-alt-conversation.png) |

Open any mockup with `?clean` to hide the yellow annotation notes.

---

## 0. Positioning the design serves

Parallel fan-out is a commodity: Manus Wide Research and ChatGPT/Gemini deep research all ship it.
Quorum wins on **trust**: every claim can be clicked through to the exact quote that supports it, and
the answer is short, beautiful and readable. So the design spends its weight in two places:

1. **The answer page is the product.** It is the center of every flow. There's one reading surface,
   not a digest, a note, an audit tab and a graph.
2. **Verification is one keystroke.** Claim → chip → quote highlighted in the source, with the same
   chip ladder everywhere (✓ verified, ≈ close, ⚠ found but doesn't say this, ? unresolved). That
   includes **every datapoint in a chart or table**.

Everything the engine does to earn that trust (angles, critics, rounds) is invisible by default and
available on demand ("Show the work").

Success metric it is designed for: the owner reaches for Quorum 3+ times a week instead of ChatGPT or
Claude deep research. That means a sub-5-second start, zero mid-run obligations, and a past answer
that's findable by what it said.

---

## 1. Shapes considered

| | A · Conversation | B · Inbox + detail | **C · Inbox of threads (recommended)** |
|---|---|---|---|
| Frame | One scroll per chat, ChatGPT-like; chats in a drawer | Linear list of runs left, selected answer right, composer in ⌘K | B's list; each row is a *question* whose detail is a short thread: scope → answer → follow-ups |
| Start | Always-visible composer | ⌘K | N, ⌘K, or ⌥Space from any app |
| Scoping | Natural (next message) | Awkward (modal pre-step) | Natural (first turn of the thread) |
| Concurrency, walk-away | Hidden in separate chats | Clear (Running group) | Clear (Running group, rings + ETA) |
| Find past answers | Weak (transcripts) | Strong | Strong, and search covers answer text + quotes |
| Follow-ups | Natural | Fragmented (unrelated rows) | Natural, kept in the question |
| Answer reads as a brief | Diluted by bubbles | Yes | Yes, the answer page is the thread's main block |
| Room for topics / Wide / charts | Little | Good | Good: topic = group of questions, Wide = 3rd depth, charts = answer blocks |

**Recommendation: C.** A wins the first ten seconds because it feels familiar. It loses the hour after,
when two runs are going and last Tuesday's answer has to be found. B wins the hour after but makes
scoping and follow-ups feel bolted on. C is B's list with A's thread inside each row, and most threads
are just one answer. Mockups `01–06` + `08` are C; [`07-alt-conversation.html`](../../design/ux-rethink/07-alt-conversation.html) sketches A for
comparison. B is C minus threads, so it needs no separate mock: picking B means deleting the
follow-up composer and turning every follow-up into a new row.

---

## 2. Concepts: from ~35 to 3 nouns and 2 verbs

**User-facing vocabulary:** a **Question**, its **Answer**, a **Source** (quote). You **Ask** and you
**Follow up**. Two modifiers: **depth** (Quick / Deep, Wide later) and **confidence** (solid / shaky
per claim, plus open conflicts). "Show the work" is a *view*, not a concept.

| Today | Fate | Where it goes |
|---|---|---|
| Project / project picker | **Demoted** | "Brain folder", chosen once at first launch, lives in Settings. Recent-projects menu removed |
| Run | **Merged** → Question | A Question owns 1..n runs (initial, follow-ups, re-runs). Users never see "run" |
| "Chats" (sidebar name for runs) | **Renamed** | The list is "Questions" |
| Chat tab (Claude CLI session) | **Merged** → Follow-up | A follow-up is a new research run in the same thread, with the answer as context. "Continue in Claude Code" stays as a ⌘K command for power use |
| Topic (TopicTarget) | **Internal** | Never shown |
| Note / Notes tree / note editor | **Demoted** → export | Every answer auto-saves as markdown in the brain folder. ⌘K: "Reveal in Finder", "Open in Obsidian". No in-app tree or editor |
| digest.md / Digest view | **Killed** | |
| Header strip, Audit tab, Validation tab | **Merged** → trust strip + "Open items" | One strip (confidence · conflicts · cited/read · critics); open conflicts, standing objections and gaps as one section at the end of the answer |
| Angle count (2–8) | **Killed** | Set by depth |
| Plan review (approve angles) | **Killed** | Engine plans and starts. Planned angles are visible in Show the work |
| Spawn approvals, pending pill, Approve all | **Killed** (default build) | Spawns run inside depth's gates, auto-admitted. No "waiting on you" state exists |
| Dig-down | **Merged** → Follow-up | "Research this conflict" (R) on a conflict block = a pre-filled follow-up |
| Prune / Retry | **Hidden** | Engine retries failed angles itself; developer mode only |
| Effort preset, round cap, time wall, spend caps, deliverable template, profile, 3+5 model pickers, API keys | **Collapsed** → depth | Quick/Deep are presets over all of them. Keys and profiles are behind ⌥ (developer) |
| Graph as the finished-run surface | **Demoted** → "Show the work" (G) | Same component live and after the fact; a mode of the question |
| Reconciled / rounds / grounding vocab | **Hidden** | Surfaces only as plain language ("2 objections resolved") |
| Citation chip ladder ✓ ≈ ⚠ ? | **Kept** | Everywhere, including chart datums |
| Conflicts | **Kept, once** | One block, two sides, "Research this conflict" |
| ⌘K | **Kept, upgraded** | Find + ask + act; searches answer text and quotes |
| Menu bar extra, Dock badge, notifications | **Kept, rewritten** | Ring + ETA; badge = unread answers; notification carries the verdict |

Room left on purpose (don't design now, don't design out):
- **Brain / topics.** A Topic is later a *group of Questions* (auto-clustered, user-mergeable). It shows
  up as a list filter / group header and as "related past answers" during scoping. Nothing in C needs
  to change; the list just gains a grouping mode.
- **Wide tier.** Depth is a segmented control with room for a third segment. A Wide answer is a
  different **answer type** (a cited comparison table, one row per item) rendered by the same answer
  page, because answers are ordered blocks (§6).
- **Charts and tables.** A first-class answer block (the "figure slot" in [`04-answer.html`](../../design/ux-rethink/04-answer.html)). The
  component catalog comes from the viz track (`dogfood/viz-spike`, `design/viz/CATALOG.md`, not
  published yet at the time of writing). This IA needs only one thing from it: every datum carries a
  citation id and a chip state.

---

## 3. Information architecture

```
Quorum window
├── Sidebar = the inbox of Questions
│   ├── Ask a question            (N)
│   ├── Running                   ring + ETA per question
│   ├── Today / Yesterday / This week / <Month>     unread dot, depth glyph, confidence word
│   └── footer: brain folder name · settings
├── Question (detail) = a short thread
│   ├── your words → scoping turn (only if vague; folds away once answered)
│   ├── progress card            (while running)  ⟷  Show the work (G): live/after-the-fact graph
│   ├── Answer page              title · resolved question · depth/time/sources · trust strip
│   │   ├── lead (1–2 sentences)
│   │   ├── sections of claims   solid/shaky gutter, citation chips
│   │   ├── figures / tables     every datum cited (viz catalog)
│   │   └── open items           conflicts (2 sides) · standing objections · gaps
│   ├── follow-ups               (each: your question → progress → compact answer)
│   └── docked composer          "Ask a follow-up" (⌘L), Quick/Deep
├── Source rail (right)          opens on chip ↩; quote highlighted in snapshot/PDF; [ ] next source
├── ⌘K palette                   questions · inside answers · sources · ask · commands, with preview
└── Settings                     6 rows
Outside the window: menu bar item (running + ready), notification with verdict, Dock badge = unread,
⌥Space global composer.
```

---

## 4. Flows, step by step

### F1 · First launch (once)
1. Window opens on `01-first-run`: "What do you want to know?", one composer, three example
   questions from the owner's domain.
2. If there's no brain folder yet, a one-line inline prompt appears above the composer: "Save answers
   to ~/Quorum? Change…". One click, never asked again.
3. Footer shows "Claude subscription connected" (preflight). If the CLI is missing, that line is the
   only error UI: what's wrong + one fix button. No env-var talk.

### F2 · Ask a specific question (no scoping)
1. N (or ⌘K → type → ⌘↩, or ⌥Space from anywhere). Type. ⇥ flips Quick/Deep. ↩.
2. A fast scoping check (<2 s, cheap model) decides the question is specific. The run starts at once;
   the row appears under Running; the detail shows the progress card.
3. Total interaction: one keystroke to open, one to send.

### F3 · Ask a vague question (scoping)
1. Same start. The scoping check returns ≤2 questions with clickable options (`02-scoping`).
2. Pick with 1–4 / Q-W-E or type freely. The **resolved question** updates live under "Quorum will
   research", along with a suggested depth.
3. ⌘↩ starts. Esc / "Research my original wording" skips scoping.
4. The resolved question becomes the thread title source. A clarifier can never become a title again.
5. This is the **last moment Quorum needs the user**.

### F4 · While it runs (optional to watch)
1. Progress card (`03-running`): 5 plain steps (Scope · Research · Draft · Check · Answer), time in, ETA,
   "Early findings, not checked yet" streaming, Stop (⌘.), Notify me toggle.
2. G toggles **Show the work** (`03b`): the live graph, read-only, with a rail streaming the selected
   step and the hosts it is reading. G again returns.
3. The user can ask another question (N). Both run, both sit under Running.
4. Walk away (`08-walk-away`): the menu bar shows a ring + "6 min". On finish, a notification with the
   verdict ("Moderate confidence. 1 open conflict on …"), and the Dock badge counts unread answers.

### F5 · Read and verify the answer
1. Click the notification / row → `04-answer`. The first screen holds title, resolved question, trust
   strip, a 1–2 sentence lead, then claims.
2. J/K move between claims (focus shows the confidence tag in the gutter). ↩ opens the first source of
   the focused claim in the rail: quote highlighted, verdict (Verified / Close / Doesn't say this /
   Unresolved), host, snapshot info, "Open original". [ ] cycles sources. Esc closes.
3. Charts: hovering a bar previews its quote. Clicking it opens the rail exactly like a chip, and the
   bar's chip carries the same state (striped bar = ⚠).
4. Open items at the end: a conflict shows two sides plus **Research this conflict (R)**, which pre-fills
   a follow-up.

### F6 · Follow up
1. ⌘L focuses the docked composer: "Ask a follow-up — it researches with this answer as context".
   Quick by default.
2. The follow-up appears in the same thread: your words → progress card → compact answer. The previous
   answer collapses to its lead + trust strip.
3. The list row shows "· 2 follow-ups", and the row title stays the original question's.

### F7 · Find a past answer
1. Glance: the sidebar groups by recency, with unread dots, depth glyph and a confidence word.
2. ⌘K → type (`05-switcher`): results grouped as Questions, Inside answers (snippet with the match),
   Sources (quote matches), then Ask (⌘↩ new question, ⌥↩ follow-up), then Commands. A right pane
   previews the lead + trust, so you often don't need to open it.
3. Filters (⇥): Running · Deep · This week.

### F8 · Go deeper on an old answer
⌘K → "Run this question again as Deep". It becomes a new run in the same thread, and the new answer
supersedes the old one, which is kept and collapsed with "earlier answer, Quick, 3 Oct".

### F9 · When things go wrong (no blocking, no jargon)
- **Angle failed:** the engine retries once, silently. If it still fails, the answer's open items
  get "One angle couldn't finish: <topic>" and the trust strip counts it.
- **Run failed:** the row shows "Couldn't finish", and the detail says what happened in one sentence +
  [Try again] [Try as Quick].
- **No evidence captured** (built-in search, legacy): the trust strip says "Quotes not checked" in amber
  and chips render as ? (unresolved). The answer never pretends.
- **Stopped by you:** the partial answer is shown with "Stopped after Research — not checked".

### F10 · Settings (`06-settings`)
Brain folder · Default depth · Answer language (same as question) · Notify me · Ask from anywhere
(⌥Space) · Account (Claude subscription via Claude Code, questions this week). Holding ⌥ reveals
developer settings (profiles, models, keys, replay, mock core).

---

## 5. Keyboard map

| Scope | Key | Action |
|---|---|---|
| Global (any app) | ⌥Space | Ask Quorum (floating composer) |
| App | N / ⌘N | New question |
| App | ⌘K | Palette: find, ask, act |
| App | ⌘1…⌘9 | Jump to the nth question in the list |
| App | ⌥↑ / ⌥↓ | Previous / next question in the list |
| App | ⌘, | Settings |
| Composer | ⇥ | Toggle Quick / Deep |
| Composer | ↩ / ⌘↩ | Ask (⌘↩ when the field is multi-line) |
| Scoping | 1–4, Q/W/E | Pick options |
| Scoping | E | Edit the resolved question |
| Scoping | ⌘↩ / esc | Start / research the original wording |
| Question | J / K | Next / previous claim |
| Question | ↩ | Open the focused claim's source |
| Question | [ / ] | Previous / next source within the claim |
| Question | esc | Close source rail |
| Question | R | Research this conflict (on a focused conflict) |
| Question | ⌘L | Follow up |
| Question | G | Show / hide the work |
| Question | ⌘⇧C | Copy answer as markdown (with footnotes) |
| Question | ⌘. | Stop the running question |
| Question | ⌥↑ (in thread) | Expand the folded scope / earlier answers |
| Palette | ↑/↓, ↩, ⌘↩, ⌥↩, ⇥ | Move, open, ask as new, follow up, cycle filter |
| Show the work | arrows, 0, −/+ | Move between steps, fit, zoom |

Single-letter keys only act when no text field has focus (Linear's convention).

---

## 6. What this implies for the data model and engine (hand-off to the architecture rethink)

### 6.1 Entities

```
Question            the user-facing unit; one list row
  id                stable ULID (not a folder-name stamp)
  createdAt
  originalText      what the user typed
  scope             { asked: [ScopeQuestion], picked: [optionId], freeText? } | null
  resolvedText      what ran; the source of title
  title             ≤ 6 words, generated from resolvedText; NEVER from model output that is a question/refusal
  language          detected from originalText; answers render in it
  runs              [RunRef] ordered: initial, follow-ups, re-runs
  readAt            → unread = latest answer finishedAt > readAt
  topicId?          reserved for the brain (later)

Run                 one engine execution
  id, questionId
  kind              initial | followup | rerun
  parentRunId?      for follow-ups (context) and re-runs (supersedes)
  depth             quick | deep | (wide later)
  status            scoping | running | done | failed | stopped
  progress          { stage: scope|research|draft|check|answer, anglesDone, anglesTotal, sourcesRead, etaSeconds }
  earlyFindings     [{ text, sourceHost, url, angleId }]   provisional, never cited in the answer
  answerId?
  startedAt, finishedAt, usage (kept for the ledger, not shown)

Answer              structured, rendered natively; markdown is an export of it
  runId, type       brief | (table — Wide, later)
  lead              1–2 sentences, cited
  blocks            ordered: section{heading} | claim | figure | table | conflict
  claim             { id, text-with-markers, confidence: solid|shaky, citationIds[] }
  figure/table      { component (viz catalog), data: [{…, citationId, chipState}] }
  openItems         { conflicts[{topic, where, sides[{value,label,citationIds}]}], objections[], gaps[] }
  trust             { level: solid|moderate|shaky|unchecked, solidClaims, totalClaims,
                      citedSources, readSources, critics: {count, resolved, open} }

Source / Citation   as today (PRD 03/07 evidence registry), plus figure datums as citation holders
```

### 6.2 Storage

- `Quorum/questions/<ulid>/question.json` + `runs/<runId>/{report.json, evidence/…}`. Folder names stop
  carrying titles, so renaming never moves a live run's directory (that fixes the class of bugs behind
  `ensureTitles`).
- Export: `Quorum/answers/<slug>.md` is regenerated from `Answer` on every finish (frontmatter: title,
  question, depth, confidence, date; footnote definitions always present, which fixes RUN-VALIDATION §3).
  The existing `Quorum/notes/` is left untouched and no longer written.
- Migration: each legacy run dir → one Question with one Run. Title = note slug/headline if the folder
  title matches clarifier/refusal shapes. Legacy answers render with trust = `unchecked` when they have
  no evidence.

### 6.3 Engine protocol changes (proposed v5)

| Need in the UI | Engine change |
|---|---|
| Scoping before the run (F3) | New command `scope` → `{needsScoping, questions:[{id,text,multi,options:[{id,label,key}]}], proposedResolved, suggestedDepth, title, language}` on a fast model, target <2 s p50. Then `resolve(answers)` → `{resolvedText, title}`. Stateless, no run dir |
| No mid-run obligations | `run` starts directly from `resolvedText` + `depth`; the planner's `plan` event is informational. Spawn approval mode defaults to **auto within gates**; `awaiting_approval` is never emitted in the default build (the stdin approve channel stays for developer mode) |
| Progress card with ETA (F4) | New `progress` event `{stage, stageIndex, stageCount:5, anglesDone, anglesTotal, sourcesRead, etaSeconds}`, emitted on every phase/angle change and at least every 10 s. The engine maps its internal phases (planning…reconciling) onto the 5 user stages. ETA comes from depth's historical medians |
| Early findings | New `finding` event `{angleId, text (≤140 chars, answer language), url, host}`, at most 1 per angle per 30 s, taken from an angle's first structured findings. Marked provisional; never cited in the answer |
| Structured answer (F5, charts) | `run_result.answer` = the `Answer` object above (blocks, per-claim confidence, citation ids on every claim and datum, openItems, trust). Markdown is produced from it by the app (or engine) as an export. Figures are constrained to the viz catalog (json-render style: catalog-validated JSON; viz track decides React-in-WKWebView vs native SwiftUI) |
| Per-claim confidence | The claim sweep (PRD 06 R1) already judges each claim; expose `confidence: solid|shaky` per claim (solid = located + supported + ≥2 sources or a primary source; shaky otherwise), plus `trust` roll-up |
| Follow-ups (F6) | `run` accepts `context: {parentRunId, parentAnswer, parentQuestion}` and may reuse the parent's evidence registry, so citations in a follow-up can point at sources captured earlier |
| Re-run deeper (F8) | `run` with `kind:"rerun"`, same `resolvedText`, new depth; answer supersedes |
| Depth presets | Quick = 2–3 angles, 1 round, deterministic quote check + claim sweep, no critics, ~3 min. Deep = 3–5 angles, up to 3 rounds, full crew, ~15–25 min. Wide (later) = item list → one agent per item → `type:"table"`. Presets own budgets, models, timeouts. The UI sends only `depth` |
| Language | `language` passed to every prompt. All user-facing text (title, lead, claims, findings, scoping) in the question's language (RUN-VALIDATION §8) |
| Title | Generated by `scope`/`resolve` from the resolved question, with a guard against question/refusal shapes (RUN-VALIDATION §1) |
| Failure honesty (F9) | `run_result.status` + `openItems` carry failed angles and "quotes not checked" (grounding none); the app never infers them |

### 6.4 App-side state

- `AppModel` collapses `draftRun` / `activeRuns` / `runs` / `noteTree` / `focus*` one-shots into a
  `QuestionStore` (list, grouped, unread) + per-question `RunStream`s. Selection is a question id.
- `ContentView.Panel` becomes `.question(id)` (+ `.newQuestion`). `.note` disappears.
- Surfaces deleted: `ComposeView` settings disclosure, `FanOutView` plan-review path, `RunHeaderStrip`,
  `ReadingRail` tabs (Audit/Validation), `TopicDetailView` (Note/Edit/Chat), notes tree + editor,
  `SynthesisSummary`, How-to-Use tab. Kept: `CitedReader` and `CitedSourceInspector` (they become the
  answer page and the source rail), `ResearchGraphView` (as Show the work), `QuickSwitch` ranking (fed
  answer text + quotes).

---

## 7. Visual system

Tokens are shared with the answer-page track (D1, `dogfood/d1-answer-mockup`,
`design/mockups/answer-page/`): blue-tinted ink `#0F1015 → #2A2F39`, hairlines at 7.5–13 % of
`#CED6FF`, text `#E8EAF0 / #A4A9B6 / #6D7280 / #4B4F5A`, iris `#A9B3FF` for focus/live, jade
`#7FD4AF` verified, amber `#EBB866` shaky/needs-care. UI is set in Instrument Sans at 13 px, and the
answer in Source Serif 4 (16–20 px): chrome reads like a tool, the answer like a document. Motion is
reserved for state the user caused or must notice (rail slide 220 ms, live edges, the arriving finding).
The shell ([`quorum.css`](../../design/ux-rethink/quorum.css)) adds only the sidebar, progress card, palette and settings on top of D1's tokens.

---

## 8. Suggested build order (for whoever implements)

1. **Answer page + source rail** (D1) on the existing report data, behind a flag. That's the biggest
   trust win and needs no IA change.
2. **Question list + thread shell** (C) over migrated legacy runs. Kill notes tree, Chat tab, header
   strip and rail tabs.
3. **Composer: depth only + scoping** (`scope`/`resolve` engine commands). Kill angle count, plan
   review, run settings.
4. **Progress card + walk-away** (`progress` / `finding` events, notification with verdict, unread
   badge). Graph moves behind G.
5. **⌘K over answers and quotes**, follow-ups with parent context, re-run deeper.
6. Later: structured figures from the viz catalog, topics, Wide.

## 9. Questions for the owner

1. **Shape:** C (recommended), B, or A?
2. **Follow-up default:** should ⌘L follow-ups default to Quick (proposed) or inherit the parent's depth?
3. **Scoping threshold:** ask only when vague (proposed), or always show the resolved question for a
   one-key confirm?
4. **Early findings** while running: useful, or noise you'd rather not see before they're checked?
5. **Notes:** OK to stop showing markdown inside the app entirely (export + Reveal/Obsidian only)?
6. **Quick without critics** but with quote checks: is that trusted enough for a 3-minute answer?

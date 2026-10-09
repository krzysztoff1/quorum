# Run validation — "Zrób reaserch systemów personalizacji w food tech" (2026-08-10-162410)

Validated run: `Quorum/runs/Zanim zacznę deep research, chciałbym sprecyzować zakres — p 2026-08-10-162410`
$3.59 / $40 cap · 6m14s · 3 angles + synthesis · Subscription profile · round 1 only.

## Verdict

The research content is genuinely good — honest confidence labeling, real cross-angle
synthesis, zero hallucinated URLs (spot-checked). The pipeline around it leaked in several
places: the run is mistitled after the clarifier message, no validator/grounding artifacts
exist despite the v4 crew being on `main`, evidence snapshots were never captured, citations
in exported notes are dangling references, and source counts disagree across digest,
frontmatter, and report.json.

## What worked

- **Epistemics.** Angle 2 caught that the most-repeated numbers in the space (Starbucks
  $2.1B, Domino's 63%, Yum 5x ROAS) trace only to SEO/marketing sites and marked them
  `unverified`; the McKinsey-vs-vendor conflict (1–2% grocery lift vs. headline case
  studies) surfaced as an explicit open conflict.
- **No fabricated sources.** Six most-suspicious URLs spot-checked — all resolve. The one
  403 (careersatdoordash.com) was honestly caveated instead of silently trusted.
- **Angle 1 sourcing** is primary-source quality: DoorDash/Uber/Instacart/HelloFresh
  engineering blogs, arXiv, peer-reviewed Frontiers.
- **Real synthesis, not concatenation.** It generated cross-angle gaps neither angle stated
  (embeddings vs. algorithmic disgorgement; GDPR status of DoorDash's Consumer Memory
  Platform).

## Findings and fixes

### 1. Run titled after the clarifier message, not the topic — systemic

The folder name is the assistant's clarifying question ("Zanim zacznę deep research,
chciałbym sprecyzować zakres — p…"). The runs directory shows this repeatedly: "I'm not
sure what you're looking for…", "That looks like a typo!…" are all run titles. The note
slug (`zr-b-reaserch-system-w-personalizacji-w-food-tech`) got the topic right, so the
correct string exists at the time of titling.

**Fix:** derive the run folder title from the *resolved research question* (post-
clarification), never from the first assistant message. `RunFolder` naming feeds from
whatever `FindingsStore.swift` is handed (`Sources/QuorumCore/FindingsStore.swift:23`);
pass the confirmed question/slug source instead. Add a guard: if the candidate title ends
with `?` or matches clarifier/refusal shapes, fall back to the question text. Test: seed a
run whose first turn is a clarifier, assert the folder title equals the resolved topic.

### 2. Validator loop and grounding absent from the run artifacts

`engine/src/run.ts` has the full crew (synthesis → `groundSynthesis` → `validateRound`,
objection-gated rounds), but this run's synthesis transcript is a single-shot CLI call
(`num_turns: 1`, zero web searches/fetches) and report.json entries carry no validation,
objection, or verdict fields. Most likely the app took the Swift in-process fallback
(`runIterativeFanOut`) or spawned a stale engine binary — either way, the flagship v4
pipeline silently didn't run, and nothing in the digest says so.

**Fix (two parts):**
- Make the executed pipeline visible and asserted: record `engine: <version/protocol>` in
  report.json; when the fallback path runs, badge the digest and each entry ("legacy
  pipeline — no validation"), same spirit as the existing `UNVALIDATED_BADGE` in
  `engine/src/run.ts:996`.
- Verify EngineRunFanOut actually resolves the current engine binary in the packaged app
  (binary discovery, version handshake); fail loudly to the fallback rather than silently.

### 3. Evidence snapshots never captured; citations dangle in exported notes

The run dir has no `sources/` snapshots, and the note
(`Quorum/notes/zr-b-reaserch-system-w-personalizacji-w-food-tech.md`) uses `[^a1c1]`-style
references with **no footnote definitions anywhere** — broken markdown outside the app and
nothing for citation chips to open (defeats PRD 03). Evidence capture is gated on
`evidenceDir` in `engine/src/run.ts:199` and skipped for the CLI backend path used by the
Subscription profile.

**Fix:** when the note is exported, append a footnote-definition block (`[^a1c1]: <url>
"<title>"`) resolved from the report's citation map so notes stand alone. Separately, wire
`QUORUM_EVIDENCE_DIR` for subscription-profile runs (built-in WebFetch results can still be
snapshotted engine-side), or explicitly badge those runs "evidence not captured" per §2.

### 4. Angle `transcriptPath` points at the note itself; angle transcripts unsaved

All three angle entries have `transcriptPath == notePath == <angle>.md`. Only the synthesis
transcript exists. Reopen/replay and debugging lose the angle-level tool activity.

**Fix:** in `EngineRunPersistence`/`EngineRunFanOut`, persist per-angle transcripts and set
`transcriptPath` accordingly; if a transcript wasn't captured, leave the field nil rather
than aliasing the note. Test: after a mock engine run, every entry's `transcriptPath` is
either nil or a distinct `.transcript.md` file.

### 5. "Sources consulted" means four different things

Digest and note frontmatter say `sources: 3` for the main entry (it counted the three angle
notes; the run consulted ~45 web sources). Angle 1 header claims 20, report.json lists 17.
Angle 3 claims 12, cites up to `[^c16]`, lists 10 links. One angle-2 source is labeled
"Statista" but links to secondmeasure.com.

**Fix:** define it once — *distinct cited URLs* — computed in one place (Reporter) and
reused by digest, frontmatter, and angle headers. For synthesis entries show both:
"3 angles · 45 distinct sources". Label sources by the fetched URL's host, never by the
name mentioned in prose. Test: counts in digest.md, note frontmatter, and report.json agree
on a fixture run.

### 6. Model preamble and duplicate H1 leak into notes

Angles 1 and 3 open with "I have enough depth now… Let me write the final report." under
the H1; angle 2 has a second H1 ("# Personalization ROI & Monetization…") below the
generated title.

**Fix:** in `ResearchOutputParser`, drop leading narration before the first heading of the
report body, and demote/strip a second H1. Fixture test with a transcript containing both
artifacts.

### 7. Round 2 never fired despite an open conflict + 3 gaps

The run ended at round 1 with one open conflict (McKinsey vs. vendor numbers) that a single
fetch of Starbucks investor materials could have settled. Either the Standard preset caps
at 1 round without saying so, or the trigger didn't evaluate.

**Fix:** if Standard is intentionally 1 round, say so in the digest ("1 open conflict —
rerun at Deep to resolve"). Better: add a cheap *conflict-resolution micro-task* — one
targeted verification agent per open conflict (budget ~$0.25) — instead of a full round.
The engine's `validateRound`/objection loop is the natural place to route it.

### 8. Polish (smaller)

- **Language mixing:** Polish question → English angle notes, bilingual digest. Pass the
  question's language into angle prompts (`ResearchPrompts.swift` / `systemPrompt.ts`) so
  all user-facing artifacts match the question language.
- **Frontmatter `title` is the entire ~250-char headline.** Store the short topic as
  `title` and the headline as a separate `headline:` key.
- **Duplicated gaps:** "Konflikty i luki" bullets repeat "Gaps & open questions" verbatim
  in the note. Emit gaps once; conflicts section should hold only conflicts.
- **Conflict attribution reads wrong:** digest frames it as "the angles disagreed" but both
  positions are Angle 2 vs. itself. Support intra-angle conflicts in the digest copy
  ("sources within Angle 2 disagree").
- **Source-tier rule for financial claims:** angle 2 caveated SEO sources well but never
  *attempted* the primary lookup. Add to the business-angle prompt: revenue/ROI claims
  require a primary disclosure (10-K, earnings call, company blog) or an explicit
  failed-lookup note.

## Suggested order of attack

1. §1 run titling (cheapest, worst daily-use annoyance)
2. §2 pipeline visibility + engine-binary resolution (explains most of what's missing here)
3. §3 footnote definitions in exported notes (+ evidence capture or badge)
4. §4 transcriptPath, §6 parser preamble (small, test-driven)
5. §5 unified source counting
6. §7 conflict-resolution micro-task
7. §8 polish batch

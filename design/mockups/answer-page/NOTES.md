# Answer page — design track D1

Two directions for the finished-run answer page, built on the real food-tech personalization run
(`runs/Zanim zacznę deep research… 2026-08-10-162410`, note `zr-b-reaserch-system-w-personalizacji-w-food-tech.md`),
condensed to the short-answer form: one lead sentence plus six claims, in Polish like the question.

| File | What |
| --- | --- |
| `a-editorial.html` | A: one serif reading column, source rail slides in from the right |
| `b-split.html` | B: run list, answer as claim rows, evidence inspector that follows focus |
| `shots/*.png` | 2× captures of each state (1440×900 window) |

Both files are interactive: `J`/`K` move between claims, `↵` opens the claim's first source, `[` `]` cycle
sources within the claim, `esc` closes, click a chip to open, hover a chip or a chart datapoint to preview.
States can be forced with a URL hash: `#hover:6`, `#open:10`, `#open:8`, `#fig:roi:4` (chart datapoint
hover), `#fig:ads:2` (table row hover, B only), and `+tall` (e.g. `#default+tall`) renders the whole page
without the 900 px clip.

## The two directions

**A, editorial-precise.** The answer is a document. A 688 px serif column, the lead sentence set larger,
claims grouped under three quiet sentence-case subheads. Confidence lives in the left gutter: a solid hairline
for solid claims, a dotted amber one for shaky. Focusing a claim (J/K) reveals the reason in the margin
("Shaky, benchmarks disagree"). Hovering a chip shows a peek; opening it slides in a 460 px rail with the cited
sentence lit inside its claim and the quote highlighted inside the surrounding passage. Calm, reading-first,
closest to "one short, trusted answer".

**B, dense split.** The answer is a list of addressable claims. Run list on the left (Linear sidebar),
claims as rows with a confidence glyph (● solid, ◐ shaky) and an index, a persistent 472 px inspector on the
right that always shows the focused claim's evidence as cards. Hover lights the matching card (no popover);
open expands the card in place. Faster to audit, more app-like, but the answer reads more like a ticket list
than a conclusion.

**Recommendation: A as the base, borrowing two things from B.** (1) B's persistent run list, as a
toggleable sidebar (`⌘\`), because dogfooding means jumping between runs weekly. (2) B's linked hover
(chip ↔ source), used inside A's rail when it's open. The tokens below are written for that.

## Evidence figures inside the answer

Trust plus beauty is the positioning, so a short answer may carry one figure where numbers do the
arguing. A figure belongs to a claim: it sits inside the claim's block, shares its focus, and its chips
feed the same rail or inspector.

- **Range chart** (`roi`, both directions): how much personalization lifts sales. Each row is one source's
  figure, drawn as a range (or a point when it's a single number) on one shared linear % axis. Independent
  benchmarks are solid green, vendor claims missing from filings are hatched amber. The texture is the
  secondary encoding, so the split survives colour blindness and greyscale. Every value label carries its
  citation chip. Hovering a row shows that datapoint's own quote, the value, the tier, and why the figure is
  or isn't confirmed. A **Chart / Table** toggle gives the same data as a table (accessibility, copying).
  The footer ties the figure to the open conflict it illustrates.
- **Comparison table** (`ads`, B only): ad revenue by platform, with an inline bar per row on one scale,
  period, and a chip per row. A row whose quote doesn't support its figure (DoorDash, ⚠) gets the hatched
  bar and an amber value, the same language as the chip.

Rules the component follows: one axis, ticks every 10, hairline grid, 10 px marks with 4 px rounded ends,
point marks with a 2 px surface ring, legend always present plus direct value labels, text in text
tokens and never the series colour, rows as hit targets bigger than the marks. The two series colours
passed the dataviz validator against `ink-0` in dark mode (lightness band, chroma, CVD ΔE 9.8, normal-vision
ΔE 17.2, contrast).

Mixing metrics (sales, revenue, basket) on one axis is deliberate and labelled: the claim is about
scale, and the subtitle says so. A real engine-made figure would need that caveat to be generated, not
assumed.

The per-datapoint quotes for Starbucks and Domino's are rebuilt from the angle notes, like the other passages.
Source 13 (Domino's, youngurbanproject.com) was in the angle notes but not in the synthesis's cited set; it
was added so every datapoint has a chip.

## What the data supports, and what it doesn't yet

Mapped from `CitationTier`, `RunValidation`, `FindingsStore` findings and the run report:

- Chip tiers: `supported` (filled jade), `close` (jade outline, ≈), `unsupported` (amber, ⚠), `unresolved`
  (dashed grey, ?). Same marks as `CitationTier.mark`.
- Claim confidence: finding `confidence` high → solid; medium/low → shaky.
- Trust strip: sources cited = distinct sources in the answer; "of N read" = sum of angle `sourcesConsulted`;
  critics/resolved/open = `RunValidation.objectionsAdmitted / objectionsResolved / objectionsOutstanding`.
- "Would settle it" under a conflict = the objection's `followup`.

Faked for the mockup (this run predates protocol v4 and stored snapshots):

- The validator verdict (3 critics, 2 resolved, 1 open) and the tier of each chip. The tiers are grounded
  in the run's real caveats: DoorDash's blog returned 403 (→ `?`), Starbucks figures only on SEO sites (→ ≈,
  cited as "unconfirmed"), and the DoorDash $1B ad figure not in the cited passage (→ ⚠).
- Source titles and the before/after context around each quote are reconstructed from the angle notes, not
  read from snapshots.

New fields the engine would need to produce this page for real:

1. **Short run title** (≈3–5 words) separate from the headline.
2. **Resolved question** from the scoping chat, separate from the user's first message.
3. **Per-claim confidence reason** ("3 sources, 2 primary", "benchmarks disagree") — one short phrase.
4. **Claim groups** (2–3 sentence-case headings) for the short answer.
5. **Conflict positions with a headline figure** ("1–2%" vs "$2.1B, +63%") so the two sides can be compared
   at a glance rather than read.
6. **Quote context** (sentence before/after) stored with the snapshot so the rail can show the quote in place.
7. **Figure specs**: when a claim compares numbers, a small typed payload (kind, rows with value, range,
   unit, evidence class, citation id, per-row quote) so the app draws the figure instead of the model
   writing a markdown table. The chip tier must be per datapoint, not per source: source 8 backs Uber's
   figure and fails DoorDash's.

## Design tokens (proposed system, direction A)

### Color

Dark only. Cool ink surfaces, three semantic hues, one accent used only for focus and selection.

| Token | Value | Use |
| --- | --- | --- |
| `ink-0` | `#0F1015` | Window chrome, rail, sidebar, key bar |
| `ink-1` | `#14161C` | Canvas (reading surface) |
| `ink-2` | `#1A1D24` | Raised: popovers, focused row, explanation boxes |
| `ink-3` | `#22262E` | Hover fills, keycaps, meter off-state |
| `line` | `rgba(206,214,255,.075)` | Hairline dividers and borders |
| `line-strong` | `rgba(206,214,255,.13)` | Buttons, popover borders, quoted-claim rule |
| `text-1` | `#E8EAF0` | Primary text, headings, highlighted quote |
| `text-2` | `#A4A9B6` | Secondary text, question, body in dense UI |
| `text-3` | `#6D7280` | Metadata, labels, passage context |
| `text-4` | `#4B4F5A` | Disabled, solid-claim gutter rule, dimmed context |
| `iris` | `#A9B3FF` | Focus, selection, active chip, links. Never decorative |
| `iris-wash` | `rgba(169,179,255,.07)` | Tier pill fill |
| `jade` | `#7FD4AF` | Verified / close-match quotes, "resolved" |
| `jade-wash` | `rgba(127,212,175,.13)` | Verified chip fill, verified highlight |
| `amber` | `#EBB866` | Shaky claims, ⚠ quotes, open conflicts and objections |
| `amber-wash` | `rgba(235,184,102,.13)` | Unsupported chip fill and highlight |

Chart series (validated pair on `ink-0`, dark band): `viz-confirmed` `#42AB80` and `viz-unconfirmed`
`#C2862A` with a 135° hatch. They're deeper steps of `jade` and `amber`, so a chart reads in the same
language as the chips, but they're tuned for fills, not text. The viz-spike catalog should extend this
pair rather than introduce new hues for evidence class.

Red is reserved for failures (run errored, budget hit); nothing on this page uses it.

### Type

Two families with distinct jobs: a crisp grotesk for the interface, a text serif for what the run says.
Both cover Polish diacritics. In the app, bundle both (OFL); SF Pro / New York are the fallbacks.

- UI: **Instrument Sans** 400/500/600
- Reading: **Source Serif 4** 400 (optical size axis on)

| Token | Family | Size / line-height | Weight | Tracking | Use |
| --- | --- | --- | --- | --- | --- |
| `title` | UI | 27 / 1.2 | 600 | −0.018em | Run title |
| `lead` | Read | 21 / 1.48 | 400 | −0.003em | Answer's lead sentence |
| `body-read` | Read | 16.5 / 1.62 | 400 | 0 | Claims |
| `passage` | Read | 15.5 / 1.7 | 400 | 0 | Source passage in rail |
| `heading-ui` | UI | 16 / 1.35 | 600 | −0.008em | Source title in rail |
| `body-ui` | UI | 13.5 / 1.5 | 400 | 0 | Question, conflicts, open questions |
| `meta` | UI | 12.5 / 1.4 | 400–500 | 0 | Metadata, trust strip, group labels |
| `small` | UI | 11.5 / 1.3 | 500–600 | 0 | Pills, keycaps, confidence tag |
| `chip` | UI | 10.5 / 1 | 600 | 0 | Citation chip numbers |

All numbers tabular (`tnum`). Sentence case everywhere; no all-caps labels. Reading measure ≤ 72 characters.

### Spacing

4 px base: `2 4 6 8 10 12 14 16 18 22 28 34 44`. Rhythm on the answer page:

- Column width 688 px, top padding 34 px; rail 460 px; key bar 34 px; title bar 40 px.
- Header → trust strip 22 px; trust strip → lead 28 px; lead → first group 22 px; group label → claim 6 px.
- Claim padding 7 × 18 px, bleeding 18 px into the gutter so the focus wash doesn't shift text.
- Confidence tag sits 132 px left of the text column (only shown on the focused claim).

### Radii

Radius follows hierarchy rather than one value everywhere:

| Token | Value | Use |
| --- | --- | --- |
| `r-chip` | 4 | Citation chips, keycaps |
| `r-control` | 6 | Buttons, inputs, sidebar rows |
| `r-row` | 8 | Focused claim wash, explanation box |
| `r-panel` | 10 | Popovers, conflict card |
| `r-window` | 11 | Window (macOS) |
| `r-pill` | 10 (full) | Tier pill |

### Elevation

Flat by default: separation comes from `ink` steps and hairlines. Only floating things cast a shadow:
popover `0 12px 32px -8px rgba(0,0,0,.6), 0 2px 6px rgba(0,0,0,.35)` plus a 1 px inner top highlight.

### Motion

Motion only answers an action. Nothing animates on load.

| Token | Duration | Easing | Use |
| --- | --- | --- | --- |
| `dur-hover` | 90 ms | `ease-out` | Hover fills, chip border |
| `dur-reveal` | 160 ms | `ease-out` | Focus wash, gutter rule, confidence tag (+4 px slide), peek (+3 px rise) |
| `dur-panel` | 220 ms | `ease-move` | Rail slide-in, column reflow |

- `ease-out` = `cubic-bezier(.2, .8, .2, 1)`
- `ease-move` = `cubic-bezier(.65, 0, .35, 1)`
- Reduced motion: all durations 0; the rail appears in place.

### Keyboard

`J`/`K` claims · `↵` open first source · `[` `]` cycle sources in claim · `esc` close · `⌘↵` open in browser ·
`G` show the work (graph) · `R` research the focused conflict · `⌘K` jump / ask · `N` new question.
Hints live in a persistent bottom key bar, not tooltips.

### B deltas, if B is chosen instead

Everything above holds except: answer set in UI sans (`body-ui` at 14 / 1.56, lead at 15.5 / 1.55 weight 500),
`r-panel` 8, confidence shown as a 12 px glyph (● / ◐) instead of a gutter rule, and the inspector is a
persistent 472 px column rather than a sliding rail.

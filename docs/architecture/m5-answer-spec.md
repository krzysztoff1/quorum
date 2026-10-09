# M5: the answer spec (QVS v1)

PRD 10 §7.1, step M5, built from §2.3 (the answer as one catalog-constrained spec) and the Viz track's
[`CATALOG.md`](../viz/CATALOG.md) and [`RECOMMENDATION.md`](../viz/RECOMMENDATION.md). The answer is no longer the
synthesis's markdown. The writer emits a spec, the engine validates, repairs and settles it, the record holds one
compiled answer, and the app paints it natively.

**Branches (stacked PRs on `main`):**
1. `dogfood/m5-a-engine`: catalog, compiler, validation, repair, numeric trace, record `quorum.run/2`, the Swift
   Codable mirror and its drift tests (merged `main` after M6).
2. `dogfood/m5-b-renderer`: the presentation model, SwiftUI + Swift Charts views, `--render`, the app wiring.
3. `dogfood/m5-c-reading`: the TextKit 2 reading column, chip previews, the source rail, linked hover.

## The pipeline

```
writer reply ──```qvs JSONL──▶ SpecStream (append-only, one element per line, per-element Zod)
                                   │
                                   ▼
             auto-fix ─▶ one repair call ─▶ turn into a table ─▶ drop to its cited caption   (prose always survives)
                                   │
                                   ▼
   markdown projection ─▶ grounding, claim sweep (claims + every located datum), critics
                                   │
                                   ▼
          settle: trust per datum, Claim confidence, display, fallback_md, check ─▶ topic_result.answer ─▶ run.json
```

- **Generation.** The synthesis and the reconciler write the answer as a fenced `qvs` block of JSONL `add` patches
  (json-render's SpecStream, narrowed: `add` only, whitelisted paths). The catalog section of the prompt is generated
  from the Zod catalog (`engine/src/answer/prompt.ts`), so the prompt and the validator cannot drift. A half line is
  never applied; a truncated reply keeps every complete element. The app never sees a patch.
- **No spec, still an answer.** A writer that returns prose (or a spec whose root cannot render) gets a spec built from
  its prose: the first paragraph is the lead, each heading a group, each paragraph or list item a Claim
  (`origin: "prose"`).
- **Repair** (`engine/src/answer/repair.ts`), in order:
  1. deterministic auto-fix: unknown keys, numeric strings, missing children, cycles, orphans, the root; a one-datum
     chart becomes a `Stat`, a two-datum chart an `EvidenceTable`; the budget (≤1 visual per group, ≤3 per answer,
     `SourceMix` excluded) moves an extra visual to a group with room, else turns it into its cited caption; an
     inconclusive answer draws no visual;
  2. one tool-less repair call (`answer_repair`, ≤$0.05, booked as validation) that sees only the offending elements,
     their catalog excerpt and the valid citation ids. Its reply may replace an element or give up on a visual; it can
     never delete prose;
  3. a visual still invalid is turned into an `EvidenceTable` of the cited data it carried, else dropped to its cited
     caption, and a minor `structure` objection is filed. An invented citation id is never kept: its row goes, and a
     marker in prose is stripped and listed in `stripped_markers`.
- **Numeric trace** (`numbers.ts`, `resolve.ts`). Every datum is matched against its located quotes after unit
  normalisation (`1–2%` ≈ `1-2%` ≈ `1 to 2 percent`, `$2.1B` ≈ `2,100 million`, comma decimals, `22/100`, `4x`).
  A `reported` number its quote does not hold is kept, shown unverified, and files a blocking `claim_sweep` objection
  ("the figure DoorDash = >$1B is not in its cited quote (a2c18)").
- **The sweep.** Each located datum is a sweep claim, `label: value (scope, as of)`, with its chart's measure and caption
  as context. A datum the sweep rejects is `tier: unsupported`.
- **Trust, decided by the engine.** `trust = {tier, trace, confidence}`. Tier: the worst citation match (exact or
  normalized → supported, fuzzy → close, else unresolved), or unsupported by the sweep. Trace: `quoted`, `derived` or
  `untraced`. Confidence (Viz's rule): unverified when the tier is not verified or a reported number is untraced; else
  estimate → low; derived or a close match → medium; else high. A chart whose data are mostly unverified gets
  `display: "table"`.
- **Findings.** The writer no longer restates its claims as findings or re-quotes reused ids (the first live canary's
  summary was twice the size of the answer); the engine lists one finding per Claim.

## The catalog in this step

`Answer`, `Group`, `Claim`, `Stat`, `RangeCompare`, `BarCompare`, `ConflictSplit`, `SourceMix` and `EvidenceTable` (the
downgrade target). `TrendLine`, `SmallMultiples`, `Timeline`, `DecisionMatrix`, `Quadrant` and `ArgumentMap` are not in
the catalog yet: a writer that emits one gets `unknown_component`, the repair call, then the table or caption path.

Deviations from CATALOG.md, decided here:
- Field names are snake_case like the rest of the record (`as_of`, `mixed_basis`, `tier_mix`, `source_type`), and PRD 10's
  `trace` replaces the spike's `numberInQuote`.
- `SourceKind` is M1's five source types (`primary`, `vendor`, `seo`, `academic`, `news`); `SourceMix.by` is `type` or
  `tier`, and its scope is `answer` or `group`. The engine also stores `total`.
- Units gain `eur`, `gbp`, `years` and `other` with a `suffix` (`3.15 MJ`); `RangeCompare.axis.log` is gone.
- Visual budget: ≤1 per group and ≤3 per answer are hard limits (owner), enforced by moving or demoting, never by
  dropping text.

## The record (`quorum.run/2`)

`answer` is now `{catalog: "qvs/1", task_id, headline, origin, spec, display, fallback_md, check, repairs, markdown}`.
`spec` is the resolved spec; `markdown` is the engine's projection (lead, sections, claims, and each visual's
`fallback_md`: its caption and a table of cited values with ⚠ on unverified ones), which the claim sweep, the critics,
`export --md` and the old readers use. Claims carry the `element_id` they came from. `stats` gains `visuals`, `datums`
and `datums_unverified`. `quorum-engine version` advertises `"catalog":"qvs/1"`.

Types: `bun run schema` regenerates `schema/run.schema.json` and `RunRecord.generated.swift`; the generator maps
`QVSSpec` to the hand-written `AnswerSpec` (`Sources/QuorumCore/AnswerSpec.swift`), because codegen flattens the element
union. `AnswerSpecTests` hold the mirror to the schema in both directions (component types, each component's props,
`Datum`, `Trust`, `TierMix`), decode the golden answers, and pin that an unknown component or enum value decodes as
`.unknown` and round-trips. A run/1 record is not read (the app now asks for run/2); M4-era runs disappear from History.

### `check`

New `spec` check: the spec validates against the catalog (settled rules), every visual has a cited caption, a
`display` and a `fallback_md`, every datum has trust, every datum's `trace` recomputes from the record's quotes, no
tier is better than its quotes allow, confidence follows from tier, trace and basis, and the engine's own `check.ok`
held. `references` also resolves every cite id in the spec. The canary fails a synthesis that wrote no spec and prints
`answer spec · N visuals · N numbers unverified`.

## The app

- `AnswerPage` (QuorumCore, tested) turns the record into what the page paints: sections of claims and figures, chips
  numbered in reading order across prose, captions and data, each datum's mark (verified; close → a lighter fill;
  estimate → a neutral hatch; unverified → the amber hatch with ⚠ and "not in its quote"), not-like-for-like notes,
  the source mix sentence ("4 of 9 sources are vendor or SEO") and the open items.
- Views (`AnswerView`, `AnswerFigures`, `AnswerTheme`): the D1 tokens (ink steps, jade/amber/iris, serif reading
  column 688 pt), Quorum's own glyphs (gutter rules and ticks, conflict bars, objection bubble), Swift Charts for
  `RangeCompare` (one chart per group on a shared domain, rule marks for ranges, point marks for points, an off-scale
  triangle with `63% →`) and `BarCompare`, plain SwiftUI for `Stat`, `ConflictSplit`, `SourceMix` and tables. Chart and
  table toggle on every chart.
- The reading column (`ReadingText`): each lead and claim paragraph is an `NSTextView(usingTextLayoutManager: true)`
  (TextKit 2) with chips as drawn attachments. Hovering a chip shows its source and quote; clicking opens the source
  rail. Linked hover: a hovered chip lights the same source's chips, the chart rows and table cells it backs and its
  row in the rail; a hovered chart row lights its chips and shows that datum's quote, mark and why in the card.
- The source rail (`AnswerSourceRail`): verdict, host and title, "In this claim", the sentence it is cited for, the
  passage around the quote from the stored snapshot (`QuotePassage`, engine offsets), why, facts.
- Wiring: "Answer & chat" on a finished run opens the new page in its Answer tab. The canvas, its node rail and the
  Chat tab are unchanged (the full new UI is M9).
- `Quorum --render <run.json | run dir> --out <png> [--peek <cite>] [--hover <cite>] [--row <figure.row>] [--open <cite>]
  [--table <figure,…>] [--width 1440]` renders a record headlessly (an offscreen window, so the TextKit views and
  charts render too).

### What Swift Charts could not do well

- Outlined marks: Charts marks are fill-only, so the mockup's "close = outline" is a 42% fill (owner decision), and the
  hatch is an `ImagePaint` pattern.
- Group headers on a categorical axis: one `Chart` per group with a shared x domain and fixed row heights.
- Labels with chips beside marks: row labels are laid out in SwiftUI beside the plot (fixed 32 pt rows), values and
  chips are `.annotation`s; an off-scale value is drawn at the domain edge with its annotation leading.
- Hover on a mark: `chartOverlay` plus `proxy.value(atY:)` maps the pointer to a row; the datum preview lives in the card
  footer rather than a floating popover anchored to the mark.
- Inline hover on a run of text: SwiftUI `Text` cannot, which is why the reading column is TextKit 2. Captions and
  conflict summaries are still SwiftUI `Text` (click opens, no hover preview).

## Verification

- Engine: `bun run typecheck`, `bun run test` (738, from 594 at M4), `bun run test:e2e` (26: the compiled binary with a
  scripted CLI writes a QVS spec, the record holds `origin: "spec"`, every claim has an `element_id`, `check` passes
  `spec`). Golden records: `engine/fixtures/record/personalization.run.json` (3 charts, a conflict, a source mix, the
  DoorDash figure untraced) and `allergy.run.json` (a `Stat` and a two-bar chart turned into a table), built from
  `engine/fixtures/answer/*.qvs.jsonl` and the personalization run's citation registry.
- App: `swift build`, `swift test` (352 at the top of the stack, 345 on the renderer layer, 332 on the engine layer).
- **Live runs** (installed app's engine, Claude subscription):
  - Before merging M6, canary 1 wrote a valid 4-group spec but its synthesis took 116 s and the watchdog halted the
    run; the slimmer summary cut the synthesis to 90 s. Canary 2:
    `FAIL 4m57s $0.439614 build source · en · status inconclusive · trust shaky · 2 cited · 5 snapshots · 8 claims checked · 0 markers stripped · answer spec · 0 visuals · 0 numbers unverified` (only `took 297s, limit 270s`; M3's run took 298 s). Its repair call deleted three
    uncited claims, which is how "a repair can never delete prose" was found and fixed.
  - After merging M6, three canaries failed with `no claim was checked against a quote`, e.g.
    `FAIL 4m04s $0.373530 build b8bd720 · en · status inconclusive · trust unchecked · 0 cited · 6 snapshots · 0 claims checked · 19 markers stripped · answer spec · 0 visuals · 0 numbers unverified`.
    In each, the Haiku research angle returned no usable citations (no `citations` array, paraphrased quotes, or no
    fenced summary at all), so every marker was dangling. The same canary on pure `main` (`2b7a29a`, no M5 code) fails
    the same way today:
    `FAIL 4m19s $0.350983 build source · pl · status inconclusive · trust unchecked · 0 cited · 0 snapshots · 0 claims checked · 17 markers stripped`.
    M5 does not touch the research prompt or path; the answer spec held in every one (`answer spec`, check `spec`
    passed).
  - The final canary on the stack as opened (installed build `56683c9`) failed the same upstream way: its research
    angles cited pages that were never captured (0 snapshots), so no claim could be checked:
    `FAIL 2m53s $0.727811 build 56683c9 · en · status inconclusive · trust unchecked · 0 cited · 0 snapshots · 0 claims checked · 8 markers stripped · answer spec · 0 visuals · 0 numbers unverified`.
  - Two real questions with numbers (Haiku or Sonnet research, Sonnet synthesis, 2 angles, 1 round):
    "How large are the advertising businesses of Instacart, Uber and DoorDash…" ($1.04, 405 s): 2 visuals, 4 datums,
    3 unverified; its bar chart is displayed as a table because most of its numbers are not in their quotes.
    "How did Netflix paid memberships and annual revenue change from 2021 to 2024?" ($1.86, 310 s, `check` 18/18):
    2 bar charts and a source mix, 7 datums, all 7 unverified, rightly: the writer drew revenue bars citing a 10-K
    sentence that holds no revenue figure, and yearly net additions citing quotes that hold other numbers. Every one
    is shown hatched with ⚠ and filed as an open item, none was dropped.
- **Screenshots** (`docs/architecture/screens/`):
  - [`m5-app-real-chart-peek.png`](screens/m5-app-real-chart-peek.png): the installed app (build `56683c9`) on the
    Netflix run, a chip previewed, the revenue chart toggled to Chart (`--open-run … --open-answer --peek a1c1 --chart
    mem,rev --shoot`).
  - [`m5-app-real-table-peek.png`](screens/m5-app-real-table-peek.png): the installed app (build `56683c9`) on the ad
    run, a chip previewed, the chart the engine displays as a table.
  - [`m5-render-golden.png`](screens/m5-render-golden.png), [`m5-render-golden-rail-peek.png`](screens/m5-render-golden-rail-peek.png)
    (the source rail open on a2c4, a chip previewed) and [`m5-render-golden-stat-table.png`](screens/m5-render-golden-stat-table.png):
    `--render` of the golden records.
  - [`m5-render-real-datum-peek.png`](screens/m5-render-real-datum-peek.png): `--render` of the Netflix run with the
    2024 bar hovered: its quote, its mark and why, and the claim citing it lit.

## Not verified / known gaps

- **No passing canary.** See above: the current `main` engine fails it the same way before any M5 code runs. The
  answer spec itself was written, compiled and checked in every live run.
- **Hover by hand.** Chip previews, the rail and linked hover were exercised through `--render`, `--peek`, `--row`,
  `--open` and the installed app's `--shoot` hook, not by moving a mouse over the installed app (taking a screen
  capture of the desktop asks for screen-recording rights, which I did not grant).
- Live runs drew `BarCompare` for time series, which belongs to `TrendLine` (not in this step's catalog), so the engine
  flags them "not like-for-like" by period.
- Titles are still `titleFromQuestion` (cut at 60 characters) until M7.
- The reconciler's answer reuses the last round's sweep verdicts for its claims; its datums are matched only when a
  datum reads exactly as before, so a reconciled answer's datums are often unjudged (tier and trace still apply).
- Old `quorum.run/1` records do not open; there is no `migrate` for them.
- Captions and conflict summaries are SwiftUI `Text` (chips click, no hover preview). J/K claim navigation is M9.
- An untraced number files a blocking objection in every run; M8's Quick tier should file it as minor.

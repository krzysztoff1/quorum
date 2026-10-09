# Answer visualization catalog (QVS v1)

The answer page renders one short, trusted answer. Most of it is prose claims. Some claims are about
numbers, disagreement, sequence, or a choice between options, and those read better as a picture. This
catalog lists the pictures the model may use. Each one is a Zod-defined component in the engine, a Codable
mirror in the app, and a SwiftUI / Swift Charts view (see `RECOMMENDATION.md`).

It follows the json-render idea (catalog → constrained JSON → native render). The decided integration is
option (b): the engine owns the catalog and validates the spec, and the app renders it natively.

Built from the real food-tech runs: personalization ROI (`runs/Zanim zacznę deep research… 2026-08-10-162410`),
menu composition (`notes/jak-zrobic-idealne-menu.md`, `notes/reaserch-perfect-restaurant-menu.md`),
order prediction (`notes/jak-zbudowa-generatywny-system-predykcji-zam-wie.md`, a fixture-backed run) and
competitor onboarding (`notes/how-are-competitors-…`, a dry run that produced no data).

---

## 1. Inventory: what in the real answers wants a picture

| Content in the run | Example (source) | Today | Better as | Component |
| --- | --- | --- | --- | --- |
| Point estimates that differ by scope | McKinsey 5–15% lift in retail vs **1–2% in grocery**; CAC −50%; marketing ROI +10–30% (personalization, a2) | One sentence with five numbers | Ranges on one axis, scope as row | `RangeCompare` |
| Headline vendor figure vs benchmark | McKinsey 1–2% vs Starbucks "$2.1B", Domino's "63% growth" (personalization conflict) | ⚠ block, two bullet strings | Two sides, each with its headline figure, its source quality, and what would settle it | `ConflictSplit` |
| Same measure across peers | Ads revenue: Uber >$2B run rate, Instacart >$1B, DoorDash >$1B (a2c3, a2c4) | Inline list | Ranked bars, **with as-of and basis per bar** (they are three different measures) | `BarCompare` |
| A curve | DashPass retention 69% → 36% → 28% at 1/6/12 months (a2 c10) | Sentence | Line with points | `TrendLine` |
| One number that carries a claim | 80% of delivery listings have no allergy intake; 72% GDPR non-compliance; Instacart privacy 22/100 (a3) | Inline | Stat with a share meter | `Stat` |
| Dated events | WW/Kurbo 2022 → GoodRx 2023 → Cal AI breach 2026; MyFitnessPal 2018 (a3) | Paragraph | Timeline with kinds (enforcement / breach / law) | `Timeline` |
| Evolution of an approach | DoorDash: knowledge-based → Store2Vec → two-tower → GNN → bandit → LLM memory (a1) | Long sentence | Timeline (ordinal, undated allowed) | `Timeline` |
| Options × criteria | CF vs two-tower vs LLM profiles vs hard filters, against cold start, latency, data need (a1) | Prose | Matrix of rated, cited cells | `DecisionMatrix` |
| Ranges by segment | Menu size: dine-in 20–47, delivery 15–20, ghost kitchen 15–25, Thai/Chinese 50–80 (menu note) | Prose | Ranges by row | `RangeCompare` |
| Disputed parameter | Optimal menu size: "35 items" vs "limited" vs "size is secondary" (menu note) | ⚠ block | Positions side by side | `ConflictSplit` |
| Two-axis framework | Menu engineering: popularity × margin → Stars / Plowhorses / Puzzles / Dogs (menu note) | Prose | Quadrant, **only with real item data**. The run had none, so it stays prose | `Quadrant` |
| Thresholds and rules | ≥ $85/week casual, ≥ $140 fine dining; < 8 orders/week per 100 seats (menu note) | Prose | Stat pair, or a reference line on a chart | `Stat` / rule mark |
| Where the evidence comes from | 13 sources in a2: 1 primary research, 3 company-reported, 7 vendor/SEO, 2 data panels | Not shown | Tier distribution strip | `SourceMix` (engine-derived) |
| Which claim rests on which | "Monetization moved to retail media" ← 3 ad figures, ← Kroger 84.51° claim; contradicted by nothing | Not shown | Small argument map | `ArgumentMap` |
| Same chart per entity | Retention per subscription (DashPass / Instacart+ / Walmart+), cost per region (order prediction fixture) | n/a | Small multiples, shared scale | `SmallMultiples` |

What does **not** want a picture: the legal findings (GDPR Art. 9 nuance, HIPAA gap). They are qualitative
and conditional, and a chart would make them look more settled than they are. Same for the gaps and open
questions, which stay a list. Onboarding (dry run) and menu composition (four halted angles) produced no
data at all. The picture is of nothing, so the renderer shows the inconclusive state, never an empty chart.

---

## 2. Spec format

json-render's shape, narrowed. A spec is a flat map of elements. A parent lists its children by key. The
model streams it as JSONL `add` patches, one complete element per line (see `RECOMMENDATION.md §3`).

```jsonc
{
  "v": 1,
  "root": "answer",
  "elements": {
    "answer": { "type": "Answer", "props": { "lead": "…[^a2c1]" }, "children": ["g1", "roi"] },
    "g1":     { "type": "Group",  "props": { "title": "ROI is real but small" }, "children": ["c1", "roi"] },
    "roi":    { "type": "RangeCompare", "props": { … } }
  }
}
```

### The datum: every number carries its own provenance

Every number in every component is a `Datum`. There is no bare-number prop anywhere in the catalog, so a
chart cannot show a value that has no citation.

```ts
Datum = {
  v?:     number,           // point value, or
  lo?:    number,           // range low  } either v, or both lo and hi
  hi?:    number,           // range high }
  unit:   "pct" | "pp" | "usd" | "count" | "ratio" | "score" | "days" | "months" | "items",
  scale?: "k" | "M" | "B",  // for usd/count: 2.1 + "B" → $2.1B
  cmp?:   "gt" | "lt" | "approx",   // ">$1B", "<5%", "~20%" — the quote's own hedging, kept
  basis:  "reported" | "derived" | "estimate",
  cite:   CiteId[],         // ≥ 1, ids from this run's resolved citations, e.g. "a2c4"
  asOf?:  string,           // "2024", "2026-Q1", "2025-10" — required in BarCompare/TrendLine
  scope?: string,           // "grocery", "US online grocery shoppers"
  label?: string            // short display label, ≤ 32 chars
}
```

- **`cite` is required and non-empty.** The engine rejects ids that are not in the run's citations.
- **`basis`**: `reported` means the number is in the quote. `derived` means it was computed from other data
  (and the computation must cite every input). `estimate` means the run's own judgement, rendered hatched
  and never as a solid bar.
- **The model never writes trust.** After validation the engine adds `trust` to each datum:

```ts
trust = {
  tier: "supported" | "close" | "unsupported" | "unresolved",  // worst tier across cite[], from CitationTier
  numberInQuote: boolean,   // the value (or lo/hi) appears in a cited quote, after unit normalisation
  confidence: "high" | "medium" | "low" | "unverified"           // floored to unverified if tier ∉ {supported, close}
}
```

(PRD 10 §2.3 names the same check `trace: "quoted" | "derived" | "untraced"`, which is richer than a boolean
because it can express "recomputed from quoted inputs". `RECOMMENDATION.md` uses `trace`, and the spike
uses `numberInQuote`. Settle on `trace` when it lands in the engine.)

`numberInQuote` is the new check here and the core of the trust story for charts. A citation can be
verified (the quote exists in the snapshot) while the number drawn on the chart is not in that quote. That
happens with the D1 run's DoorDash $1B ad figure. A `reported` datum that fails it is rendered as
unverified (`?` mark, dashed outline, value excluded from axis auto-scaling). Normalisation covers `1–2%` ≈
`1-2%` ≈ `1 to 2 percent`, `$2.1B` ≈ `$2.1 billion` ≈ `2,100 million`, and comma/period decimals.

### Text with citations

`Rich` is a string using the notes' existing marker syntax: `"Grocery lift is 1–2%[^a2c1]."`. The same
chip renderer handles prose and charts.

### Confidence on claims

`Claim.confidence` is model-proposed (`high | medium | low`) with a short `reason` ("3 sources, 2 primary",
"benchmarks disagree"). The engine floors it to `unverified` when no cited quote resolves, the same rule as
`findings[].confidence` in PROTOCOL v2.

### Rules every component shares

1. **A chart needs ≥ 3 data, or it's a `Stat`.** Two numbers are a sentence or a stat pair. One is a stat.
2. **One unit per axis.** A `BarCompare` whose bars have different `unit` fails validation. Different
   `asOf` or `scope` is allowed but rendered as a visible "mixed basis" warning, never hidden.
3. **No more than 8 rows/series.** More fold into "other" or become a table.
4. **Majority-unverified downgrade.** If more than half the data in a chart end up `unverified`, the
   renderer shows the data as a table with marks instead of a chart. A chart's shape implies precision.
5. **Every component has a `caption: Rich`.** It says the one thing the picture shows, cited. It is also
   the accessibility label and the text fallback when exporting to markdown.
6. **The answer language** is the question's language. Component labels are written by the model in that
   language. Units and numbers are formatted by the app's locale.

---

## 3. Components

`Rich` = text with `[^id]` markers. `Datum` as above. `?` = optional. Props are what the **model** writes.
Engine-added fields are marked ⚙.

### Layout

#### `Answer` (root, exactly one)
| Prop | Type | |
| --- | --- | --- |
| `lead` | Rich | The one-sentence answer. ≤ 40 words. |
| `verdict?` | `"settled" \| "leaning" \| "contested" \| "inconclusive"` | Drives the header mark. |
| children | `Group[]` | 1–4 groups. |

#### `Group`
| Prop | Type | |
| --- | --- | --- |
| `title` | string | Sentence case, ≤ 8 words, says the conclusion ("Monetization is retail media, not data sales"). |
| children | `(Claim \| any visual)[]` | ≤ 6. A group has ≤ 2 visuals. |

#### `Claim`
| Prop | Type | |
| --- | --- | --- |
| `text` | Rich | One sentence, ≥ 1 marker. |
| `confidence` | `high \| medium \| low` | ⚙ floored to `unverified`. |
| `reason?` | string | ≤ 6 words. Shown on focus. |

### Numbers

#### `Stat`: one number that carries a claim
| Prop | Type | |
| --- | --- | --- |
| `value` | Datum | |
| `label` | string | What it counts, ≤ 8 words. |
| `of?` | Datum | For a share: "80% **of 50 listings**". Turns on the share meter. |
| `context?` | Datum | A comparison number ("vs 25% Walmart+"). |
| `caption` | Rich | |

**Use** when a single number is the claim's evidence and is notable (a share, a threshold, a record).
**Don't** use for a number that only makes sense next to others (then `BarCompare`), or for ≥ 3 stats in a
row. That's a dashboard, not an answer.

#### `RangeCompare`: estimates with uncertainty, on one axis
| Prop | Type | |
| --- | --- | --- |
| `measure` | string | "Revenue lift from personalization" |
| `rows` | `{ label: string, value: Datum, group?: string }[]` | 2–8 rows. A row may be a point or a range. |
| `reference?` | `{ label: string, value: Datum }` | A vertical rule (e.g. the benchmark). |
| `axis?` | `{ min?: number, max?: number, log?: boolean }` | Values beyond `max` render as an off-scale arrow with the value printed. |
| `caption` | Rich | |

**Use** when the question is "how big?" and the sources give different numbers or different scopes,
including point estimates mixed with ranges. This is the main ROI picture.
**Don't** use when the rows measure different things (lift vs absolute dollars), or when there's one
estimate (use `Stat`). Rows whose `basis` is `estimate` render hatched.

#### `BarCompare`: one measure across peers
| Prop | Type | |
| --- | --- | --- |
| `measure` | string | |
| `bars` | `{ label: string, value: Datum }[]` | 3–8, same `unit` required. `asOf` required on each. |
| `sort?` | `"desc" \| "asc" \| "given"` | default `desc` |
| `caption` | Rich | |

⚙ `mixedBasis: { asOf: bool, scope: bool }`: set by the engine when bars differ in `asOf`/`scope`. Rendered
as an amber "not like-for-like" note under the chart, listing each bar's basis.
**Use** to rank or size peers on a single measure. **Don't** use for time (use `TrendLine`), or when the
"same measure" is actually three different metrics (run rate vs annual vs ads+other). The validator can
only catch this through `asOf`/`scope`, so the prompt asks the model to fill them honestly.

#### `TrendLine`: change over an ordered axis
| Prop | Type | |
| --- | --- | --- |
| `measure` | string | |
| `x` | `{ kind: "time" \| "ordinal", label: string }` | |
| `series` | `{ label: string, points: { x: string \| number, y: Datum }[] }[]` | 1–4 series, ≥ 3 points each. |
| `reference?` | `{ label: string, value: Datum }` | Horizontal rule. |
| `caption` | Rich | |

**Use** for a curve the sources actually report point by point (retention, cost over years). **Don't**
interpolate. Only cited points are drawn, and a line is never drawn across a gap in `x`. Don't put series
with different units together. One axis, always.

#### `SmallMultiples`: the same small chart per entity
| Prop | Type | |
| --- | --- | --- |
| `of` | `"TrendLine" \| "BarCompare" \| "RangeCompare"` | |
| `panels` | `{ title: string, props: <props of 'of'> }[]` | 2–6 panels, shared scale enforced by the renderer. |
| `caption` | Rich | |

**Use** when one comparison repeats across entities and a single chart would need > 4 series. **Rare.**
Most short answers don't have this much comparable data.

### Disagreement and trust

#### `ConflictSplit`: two (or three) positions, side by side
| Prop | Type | |
| --- | --- | --- |
| `question` | string | The disputed point, as a question ("How big is the revenue lift?") |
| `sides` | `{ label: string, headline: Datum \| string, summary: Rich, sourceKind: SourceKind }[]` | 2–3 |
| `leaning?` | `{ side: number, why: Rich }` | Only if the run actually leans. Otherwise omitted, and the card says "open". |
| `settle?` | string | What evidence would resolve it (from the objection's `followup`). |
| `caption` | Rich | |

`SourceKind = "primary-research" | "filing" | "company-reported" | "press" | "vendor" | "seo" | "academic" | "regulator"`.
⚙ Each side also gets `tierMix` (counts of supported/close/unsupported/unresolved over its citations).
**Use** for every open conflict the run reports. A conflict with numbers on both sides puts them in
`headline`. **Don't** use to stage false balance: if the validator resolved the objection, it's a `Claim`
with a reason, not a split.

#### `SourceMix`: where the evidence comes from (⚙ engine-derived)
| Prop | Type | |
| --- | --- | --- |
| `scope` | `"answer" \| "group" \| CiteId[]` | What to count. |
| `by` | `"kind" \| "tier"` | Source kind, or verification tier. |
| `caption?` | Rich | |

The model only places it. The engine fills the counts from the citation registry and `documents`. The model
cannot write a count here, so there's nothing to cite. **Use** once per answer at most, usually in the trust
strip, or inside a group whose claim rests on weak sources ("7 of 13 sources are vendor case studies").

#### `EvidenceTable`: the fallback for anything else
| Prop | Type | |
| --- | --- | --- |
| `columns` | `{ key: string, label: string, align?: "start" \| "end" }[]` | ≤ 6 |
| `rows` | `Record<key, Datum \| Rich>[]` | ≤ 12 |
| `caption` | Rich | |

**Use** when the data is comparable but not chartable (mixed units, ≤ 2 rows per kind), or as the downgrade
target of rule 4. **Don't** use for qualitative pros/cons. That's a `DecisionMatrix` or prose.

### Structure

#### `Timeline`: dated or ordered events
| Prop | Type | |
| --- | --- | --- |
| `axis` | `"date" \| "ordinal"` | `ordinal` = sequence without trustworthy dates (an architecture's evolution). |
| `events` | `{ at: string, title: string, detail?: Rich, kind?: string, cite: CiteId[] }[]` | 3–12 |
| `kinds?` | `{ key: string, label: string }[]` | ≤ 4 kinds (enforcement / breach / law). |
| `caption` | Rich | |

**Use** when order or spacing in time is part of the argument ("the FTC moved from fines to algorithm
destruction within a year"). **Don't** use for < 3 events, or when the dates are unsourced. An event's
date must be in its quote (same `numberInQuote` check on the year).

#### `DecisionMatrix`: options × criteria
| Prop | Type | |
| --- | --- | --- |
| `options` | `{ key: string, label: string }[]` | 2–6 (rows) |
| `criteria` | `{ key: string, label: string, better?: "high" \| "low" }[]` | 2–6 (columns) |
| `cells` | `{ option: string, criterion: string, rating: -2..2 \| null, note?: string, cite: CiteId[] }[]` | |
| `recommend?` | `{ option: string, why: Rich }` | |
| `caption` | Rich | |

A rating is ordinal, never a fake score. `null` = "the run found nothing", rendered as an empty dashed
cell, never as 0. **Use** when the question is "which approach?" and the run compared options. **Don't**
use with uncited cells. Every non-null cell needs `cite`.

#### `Quadrant`: two measured axes, labelled regions
| Prop | Type | |
| --- | --- | --- |
| `x`, `y` | `{ label: string, split: Datum \| number }` | Split lines (e.g. median margin). |
| `regions` | `[string, string, string, string]` | Top-left, top-right, bottom-left, bottom-right. |
| `points` | `{ label: string, x: Datum, y: Datum }[]` | 4–20 |
| `caption` | Rich | |

**Use** only when both coordinates of every point are cited measurements (menu engineering on the user's
own POS data, effort/impact with sourced estimates). **Don't** use to draw a framework with made-up dots.
The menu run's Stars/Dogs matrix has no item data, so it stays prose. This is the component most likely to
be misused. The validator rejects a `Quadrant` whose points are `basis: "estimate"`.

#### `ArgumentMap`: which claims rest on which evidence
| Prop | Type | |
| --- | --- | --- |
| `thesis` | Rich | |
| `nodes` | `{ id: string, text: string, stance: "supports" \| "contradicts" \| "qualifies", cite: CiteId[], parent?: string }[]` | 3–9 |
| `caption` | Rich | |

**Use** in a `contested` answer, to show that the thesis survives the contradicting evidence (or doesn't).
**Don't** use as decoration in a settled answer. The run graph already shows the work. This shows only the
argument's shape.

---

## 4. When the model should not draw at all

The prompt's guidance, in priority order:

1. Prefer a sentence. Draw only when the picture says something the sentence can't: scale, spread, order,
   or the shape of a disagreement.
2. At most **one visual per group and three per answer**. A short answer with six charts is a dashboard.
3. Never draw a number you'd hedge in prose without the hedge. Use `cmp`, `basis: "estimate"`, ranges.
4. If the data is mostly vendor or SEO claims, show `SourceMix` or `ConflictSplit` before any bar chart.
5. An inconclusive run gets no visuals except `SourceMix` (why it's thin).

## 5. Component → native rendering (summary, details in RECOMMENDATION.md)

| Component | SwiftUI / Swift Charts | Effort |
| --- | --- | --- |
| Answer, Group, Claim | `Text` with `AttributedString` runs + chip overlay (already in the app's evidence chips) | low |
| Stat | `Text` + a `Capsule` meter (no Charts needed) | low |
| RangeCompare | `Chart` + `RuleMark(xStart:xEnd:y:)` + `PointMark` + `RuleMark(x:)` reference | low |
| BarCompare | `Chart` + `BarMark(x:y:)` + `.annotation(position: .trailing)` | low |
| TrendLine | `Chart` + `LineMark` + `PointMark` + `.chartXSelection` | low |
| SmallMultiples | `Grid` of the above with a shared `.chartXScale(domain:)` | low |
| ConflictSplit | Plain SwiftUI layout (`HStack` of cards) | low |
| SourceMix | `Chart` + `BarMark(x:stacking:)` one row, or `SectorMark` (avoid) | low |
| EvidenceTable | `Grid` (SwiftUI `Table` is too heavy for 5 rows inside a scroll view) | low |
| Timeline | `Chart` + `PointMark(x: .value(date))` + `RuleMark` for ordinal; custom layout for labels | medium (label collision) |
| DecisionMatrix | `Grid` of cells. `RectangleMark` heatmap is possible but loses notes. | low |
| Quadrant | `Chart` + `PointMark` + `RuleMark` splits + `.annotation` region labels | medium (point-label collision) |
| ArgumentMap | `Canvas` + custom tree layout. **Swift Charts can't do this.** | high |

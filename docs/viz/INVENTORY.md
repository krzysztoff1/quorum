# Visualization inventory

Which content in Quorum's real food-tech answers benefits from which visual. This is the evidence behind the
component list in [`CATALOG.md`](CATALOG.md).

Runs surveyed:
- Personalization ROI: `Quorum/runs/Zanim zacznę deep research… 2026-08-10-162410`, three angles, 36 sources.
- Menu composition: `notes/jak-zrobic-idealne-menu.md` and `notes/reaserch-perfect-restaurant-menu.md`.
  Also `notes/how-to-compose-ideal-restaurant-menu.md`, where all four angles halted with no data.
- Order prediction: `notes/jak-zbudowa-generatywny-system-predykcji-zam-wie.md`, backed by a fixture, not
  live research.
- Competitor onboarding: `notes/how-are-competitors-solving-onboarding-…`, a dry run with no data.

## What in the real answers wants a picture

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
| Where the evidence comes from | 13 sources in a2: 1 research firm, 1 data panel, 1 company-reported, 3 press, 7 vendor or SEO | Not shown | Tier distribution strip | `SourceMix` (engine-derived) |
| Which claim rests on which | "Monetization moved to retail media" ← 3 ad figures, ← Kroger 84.51° claim; contradicted by nothing | Not shown | Small argument map | `ArgumentMap` |
| Same chart per entity | Retention per subscription (DashPass / Instacart+ / Walmart+), cost per region (order prediction fixture) | n/a | Small multiples, shared scale | `SmallMultiples` |

What does **not** want a picture: the legal findings (GDPR Art. 9 nuance, HIPAA gap). They are qualitative
and conditional, and a chart would make them look more settled than they are. Same for the gaps and open
questions, which stay a list. Onboarding (dry run) and menu composition (four halted angles) produced no
data at all. The picture is of nothing, so the renderer shows the inconclusive state, never an empty chart.

## Patterns

- **Most numbers in these answers are vendor or company-reported.** The visual that matters most is often
  the one that shows that fact (`SourceMix`, `ConflictSplit`), not the one that makes the number look big.
- **"Same measure" is rarely the same.** Uber, Instacart and DoorDash ad revenue are a run rate, ads + other,
  and ads, as of three different periods. Any comparison chart needs `asOf` and `scope` per datum, and a
  visible warning when they differ.
- **Ranges and hedges are the norm** (`>$1B`, `1–2%`, `5–15%`, `~20%`). The datum must keep the hedge (`cmp`,
  `lo`/`hi`), or the chart overstates precision.
- **Frameworks without data are common** (menu-engineering quadrant, "golden triangle"). They stay prose.
  A chart with made-up dots is the easiest way to lose trust.
- **Half the food-tech runs produced no data at all** (halted angles, dry runs). The renderer's inconclusive
  state matters as much as any chart.

# design/viz: visual answers

The visualization track for the dogfood plan. It covers which parts of an answer become charts, how every
plotted number stays traceable to a verified quote, and how that renders natively (owner decision (b):
engine-validated spec, SwiftUI + Swift Charts).

**The written research lives in [`docs/viz/`](../../docs/viz/).** This folder keeps the mockups. The
`CATALOG.md` and `RECOMMENDATION.md` here are stubs that link to `docs/viz/`, so there is only one copy.

| File | What |
| --- | --- |
| [`docs/viz/INVENTORY.md`](../../docs/viz/INVENTORY.md) | Which content in the real food-tech runs wants which visual, and the patterns behind the rules |
| [`docs/viz/CATALOG.md`](../../docs/viz/CATALOG.md) | Spec format, the `Datum` (every number carries `cite[]` + engine `trust`), and 15 components with use / don't-use rules |
| [`docs/viz/RECOMMENDATION.md`](../../docs/viz/RECOMMENDATION.md) | The concrete design for option (b): Zod catalog, streaming, validation and repair, Codable mirror and TS↔Swift sync, Swift Charts mapping, reconciliation with PRD 10 |
| [`docs/viz/JSON-RENDER-EVALUATION.md`](../../docs/viz/JSON-RENDER-EVALUATION.md) | What json-render is, what we borrow and what we don't, and the spike's findings |
| `mockups/answer-viz.html` | The personalization answer with 8 components in D1 direction A's tokens. Hover any mark or chip for its source quote. Click pins, `T` toggles a chart's table view, `B` toggles showcase vs "as emitted" (the 3-visual budget). Hash states: `#pin:roi-3`, `#pin:ads-2`, `#pin:cf-1`, `#pin:dm-ttfresh`, `#budget+table:ads` |
| `mockups/shots/*.png` | Captures of those states at 1280×900 |
| [`spikes/json-render/`](../../spikes/json-render/) | Throwaway reference: Zod catalog, prompt generation, validator, resolver, repair, JSONL stream compiler, JSON Schema export, and a Swift package that decodes the fixtures |

Components in the mockup: `RangeCompare`, `SourceMix`, `BarCompare` (with the mixed-basis warning and an
untraced bar), `TrendLine`, `DecisionMatrix`, `Timeline`, `Stat` ×2, `ConflictSplit`, plus the
engine-derived tier strip in the header.

The mockup is in English, though the run was in Polish. Production answers follow the question's language
(CATALOG rule 6). Quotes are reconstructed from the angle notes, and the tiers and critic verdict are staged
as in D1, because this run predates stored snapshots.

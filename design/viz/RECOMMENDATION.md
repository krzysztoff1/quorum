# Visual answers: integration design (option b)

**Decision (owner, 2026-10-09):** option (b). The engine (TS, AI SDK, Zod) owns the catalog and emits and
validates catalog-constrained JSON. The macOS app renders it with SwiftUI and Swift Charts. There is no
WKWebView, no React and no web shell. This document is the concrete design for (b). It also reconciles the
design with PRD 10 (`dogfood/arch-rethink`, `prds/10-architecture-rethink.md` §2.3 and §5), which reached
the same decision and defers the catalog to `design/viz/CATALOG.md`.

Companion files:
- `CATALOG.md`: inventory and the 15 components, with when to use and when not to.
- `mockups/answer-viz.html` and `shots/`: look and feel, 8 components in one answer.
- `spikes/json-render/`: Zod catalog, validator, resolver, repair, stream compiler, JSON Schema export, and a
  Swift package that decodes the fixtures.

## Contents

1. [Options considered, and why (b)](#1-options-considered-and-why-b)
2. [The Zod catalog](#2-the-zod-catalog)
3. [Streaming and partial specs](#3-streaming-and-partial-specs)
4. [Validation and repair](#4-validation-and-repair)
5. [The Swift side: Codable mirror and keeping TS and Swift in sync](#5-the-swift-side-codable-mirror-and-keeping-ts-and-swift-in-sync)
6. [Swift Charts mapping, and what it can't do well](#6-swift-charts-mapping-and-what-it-cant-do-well)
7. [What PRD 10 should take from this](#7-what-prd-10-should-take-from-this)
8. [Spike results](#8-spike-results)
9. [Build order](#9-build-order)

---

## 1. Options considered, and why (b)

| | (a) React + json-render in a WKWebView | **(b) Native renderer of an engine-validated spec** | (c) Web shell |
| --- | --- | --- | --- |
| Look | Any chart lib, matches the HTML mockups 1:1 | Swift Charts: native and crisp. A few looks need `chartOverlay` (§6). | Same as (a) |
| Trust plumbing | The datum → source inspector path crosses a JS bridge into PDFKit | Same process as `SourceInspector` / `CitedReader`, which already exist | Inspector rebuilt in web |
| json-render fit | Official renderer | Borrow the spec shape and the SpecStream idea. The renderer is ours. | Official renderer |
| Cost now | A second UI stack inside the app | 1 Zod catalog + 1 Codable mirror + ~13 SwiftUI views | Rebuild every surface |
| Agent visual verification | Strong | Via the `--render` PNG mode (PRD 10 §6) | Strong |

(b) wins because the answer's value is the trust path (datum → quote → snapshot), and that path is native
already. json-render's useful ideas are the **catalog as the single source of the prompt and the
validator**, the **flat element map** and **append-only JSONL patches**. All three are data formats, not
React, so they carry over intact. If a share page is ever needed, the same stored spec can be rendered by
`@json-render/react` or by an engine `export --format html`. Nothing in this design prevents that.

---

## 2. The Zod catalog

Location in the real build: `engine/src/answer/catalog.ts`. The spike version is `spikes/json-render/src/catalog.ts`.

### 2.1 Two schemas from one source

```ts
// What the model writes. No trust fields: the model can't author confidence or tiers.
const ModelDatum = z.object({
  v: z.number().optional(), lo: z.number().optional(), hi: z.number().optional(),
  unit: Unit, scale: z.enum(["k","M","B"]).optional(), cmp: z.enum(["gt","lt","approx"]).optional(),
  basis: z.enum(["reported","derived","estimate"]),
  cite: z.array(CiteId).min(1),
  asOf: z.string().optional(), scope: z.string().max(48).optional(), label: z.string().max(32).optional(),
}).refine(d => d.v !== undefined || (d.lo !== undefined && d.hi !== undefined), "either v, or lo and hi")

// What the app decodes: the engine adds trust after resolution.
const ResolvedDatum = ModelDatum.extend({
  trust: z.object({
    tier: z.enum(["supported","close","unsupported","unresolved"]),   // worst tier across cite[]
    trace: z.enum(["quoted","derived","untraced"]),                    // PRD 10's name for numberInQuote
    confidence: z.enum(["high","medium","low","unverified"]),
  }),
})
```

Each component is defined once with a props schema, and the two element unions are derived from that list:

```ts
const component = <P extends z.ZodTypeAny>(type: string, props: P, meta: { use: string; avoid: string; children?: "claims+visuals" | "groups" }) => ({ type, props, meta })

export const CATALOG = [
  component("RangeCompare", z.object({
      measure: z.string().max(60),
      rows: z.array(z.object({ label: z.string().max(32), value: Datum, group: z.string().optional() })).min(2).max(8),
      reference: z.object({ label: z.string(), value: Datum }).optional(),
      axis: z.object({ min: z.number().optional(), max: z.number().optional(), log: z.boolean().optional() }).optional(),
      caption: Rich,
    }),
    { use: "sources give different magnitudes or scopes for the same measure", avoid: "rows measuring different things; a single estimate" }),
  // … the other 14, as in CATALOG.md §3
] as const
```

- `Element = z.discriminatedUnion("type", CATALOG.map(c => z.object({ type: z.literal(c.type), props: c.props, children: z.array(Key).optional() })))`
- `Spec = { v: 1, root: Key, elements: z.record(Key, Element) }`

**The prompt is generated from the catalog.** It lists each type with its `use` and `avoid` text, the props
rendered compactly from the schema, and one tiny example. The prompt and the validator can't drift (PRD 10
§2.3 requires this). It is json-render's `catalog.prompt()`, done in 60 lines without the dependency.

### 2.2 How each datum carries citations and confidence

There are three layers, each owned by one party:

| Field | Written by | Meaning |
| --- | --- | --- |
| `cite[]` | model | Which resolved citations this number comes from. Ids are the run's own (`a2c6`), the same as prose `[^a2c6]`. |
| `basis` | model | What the model *claims*: in the quote, computed from inputs, or its own estimate. |
| `trust.tier` | engine | Worst `CitationTier` across `cite[]`, from the existing quote location (exact / normalized / fuzzy / unresolved) and the claim sweep. |
| `trust.trace` | engine | Whether the number is actually in a cited, located quote, after unit normalization. If not, can it be recomputed from quoted inputs (`derived`)? Otherwise `untraced`. |
| `trust.confidence` | engine | Min of the owning claim's confidence and the tier floor. `unverified` unless the tier is `supported` or `close` and the trace is `quoted` or `derived`. |

`basis` and `trace` disagreeing is the interesting case. A model says `reported`, the engine finds the
number in no quote, and the result is `untraced`. That is exactly the DoorDash $1B bar in the mockup. The
renderer never hides it. It draws it in the amber hatch with ⚠, keeps it out of axis auto-scaling, and the
popover says "$1B not in passage".

**Normalization for `trace`** (implemented in the spike's `resolve.ts`): en/em dashes and "to" in ranges,
`%` ↔ "percent", `$2.1B` ↔ "$2.1 billion" ↔ "2,100 million", `>`/"more than"/"over", comma and period
decimals, thousands separators, and years for `Timeline` events. Matching is by value tolerance (±0.5% of
magnitude), not by string, so "two-thirds" is *not* matched to 67%. That's deliberate. Such a datum is
`derived` at best, and the model must say so.

### 2.3 Engine-derived components

`SourceMix` counts and `ConflictSplit.tierMix` are computed from the record (`citations`, `sources`), not
written by the model. The model places the component, and the engine fills the numbers. These are the
only numbers on the page without a quote, and they are labelled "engine-counted".

---

## 3. Streaming and partial specs

**Recommendation: don't stream the answer to the screen (agrees with PRD 10 §2.3). Do generate it as
element-granular JSONL**, because that makes partial failure cheap and keeps progressive reveal possible later.

**Why not stream to the UI.** The answer is only trustworthy after `trace`, tier resolution and the claim
sweep. Showing a chart for two seconds and then hatching half of it teaches the user to distrust the
page. Liveness during a run comes from the graph and `run.progress`, which already exist.

**Why JSONL anyway.** The synthesis model emits one `add` patch per line, json-render's SpecStream format
narrowed to append-only:

```jsonl
{"op":"add","path":"/root","value":"answer"}
{"op":"add","path":"/elements/answer","value":{"type":"Answer","props":{"lead":"…[^a2c6]","verdict":"leaning"},"children":[]}}
{"op":"add","path":"/elements/g1","value":{"type":"Group","props":{"title":"The sales lift is real, and small in grocery"},"children":[]}}
{"op":"add","path":"/elements/answer/children/-","value":"g1"}
{"op":"add","path":"/elements/roi","value":{"type":"RangeCompare","props":{…}}}
{"op":"add","path":"/elements/g1/children/-","value":"roi"}
```

- **One complete element per line.** The compiler parses only complete lines. A half-received line is
  never applied, so there is no partial-JSON parsing (no `jsonrepair`, no `partial-json`).
- **Whitelisted paths.** Only `/root`, `/elements/<key>`, `/elements/<key>/children/-` and
  `/elements/<key>/props/<rows|bars|events|points|cells>/-` are allowed. `replace`, `remove` and `move` are
  rejected, so the model can't rewrite history or delete a visual the validator already accepted.
- **Validation per element, on arrival.** Each element is Zod-parsed when its line completes. An invalid
  element is quarantined (kept in a side list with its issues) and the stream continues. A child key that
  hasn't arrived yet is `pending`. At end of stream, pending children are dangling refs, which go to repair (§4).
- **Truncation is survivable.** If the model hits `max_tokens` mid-answer, every complete line before the
  cut is a valid partial spec. Repair continues from the last good line instead of regenerating the answer.
  This was the main reason to keep JSONL even without UI streaming.
- **The app sees one artifact.** The engine compiles the JSONL into the final `ResolvedSpec`, writes it to
  the run record (`answer.blocks[].spec`), and emits one `answer` event. The Swift side never parses patches.

If progressive reveal is ever wanted, the engine can forward per-element `answer_element` events *after*
each passes resolution. The Swift renderer already handles `pending` children (a skeleton row), so it's an
additive change.

The AI SDK path is `streamText` with a line splitter over `textStream`, then `compiler.push(chunk)`.
`streamObject` / `Output.object` is the wrong tool here: it re-validates the whole object on every delta,
and its partial objects can't express "this element is complete".

---

## 4. Validation and repair

Pipeline (engine, after synthesis or reconciliation). It matches PRD 10 §2.3 steps 1–6 and adds the
deterministic auto-fix layer:

```
JSONL ─► compile ─► Zod (per element) ─► references ─► rules ─► resolve (tier, trace) ─► fit/budget
                         │                    │            │                                 │
                         └──────────── issues: {path, code, severity} ───────────────────────┘
                                                   │
                          auto-fix (deterministic) ┤
                          1 repair call (cheap)    ┤
                          drop element → prose     ┘
```

**Issue codes** (the spike tests each one): `zod`, `unknown_type`, `bare_number`, `unknown_cite`,
`dangling_child`, `orphan`, `cycle`, `root_not_answer`, `mixed_units`, `as_of_required`, `too_few_data`,
`too_many_rows`, `visual_budget`, `estimate_in_quadrant`, `uncited_cell`, `untraced` (warn),
`mixed_basis` (warn), `truncated_line`.

**Repair, three layers:**

1. **Deterministic auto-fix (free).** This layer covers the following:
   - Coerce numeric strings (`"1.5"` → `1.5`, `"1,5"` → `1.5`).
   - Wrap a bare number in a Datum *only if* a sibling or the parent claim supplies `cite`. Otherwise it
     stays an error.
   - Drop unknown props.
   - Drop orphan elements.
   - Break a cycle at its last edge.
   - Downgrade a chart with fewer than 3 data to a `Stat` (1 datum) or an `EvidenceTable` (2).
   - Move visuals over the tier's budget to prose: keep the caption, which is cited, as a `Claim`.
   - A chart where more than half the data is `untraced` becomes an `EvidenceTable` (CATALOG rule 4).
2. **One repair call (≈$0.01, tool-less, low effort).** It gets the issues as JSON pointers, the offending
   elements only, and the catalog excerpt for those types, and it must answer with replacement JSONL lines
   for those keys. It never sees or rewrites the rest of the answer. This is the "repair prompt" built in
   the spike's `repair.ts`.
3. **Drop and file.** If the element is still invalid, it is removed, its caption survives as prose, and a
   minor `structure` objection is filed on the run (PRD 10's wording). **A bad chart never blocks the
   answer.**

**What must never be repaired automatically:** `unknown_cite` (inventing a citation is the one thing that
breaks the moat) and `untraced` (that's a finding about the source, not a formatting error). Both go to
the repair call or the claim sweep, never to auto-fix.

---

## 5. The Swift side: Codable mirror and keeping TS and Swift in sync

### 5.1 The mirror

```swift
public struct AnswerSpec: Decodable, Sendable { let v: Int; let root: String; let elements: [String: Element] }

public enum Element: Decodable, Sendable {
    case answer(Answer, children: [String]), group(Group, children: [String]), claim(Claim)
    case stat(Stat), rangeCompare(RangeCompare), barCompare(BarCompare), trendLine(TrendLine)
    case smallMultiples(SmallMultiples), conflictSplit(ConflictSplit), sourceMix(SourceMix)
    case evidenceTable(EvidenceTable), timeline(Timeline), decisionMatrix(DecisionMatrix)
    case quadrant(Quadrant), argumentMap(ArgumentMap)
    case unknown(type: String, fallbackMarkdown: String?)   // forward-compatible: render fallback_md

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "RangeCompare": self = .rangeCompare(try c.decode(RangeCompare.self, forKey: .props))
        // …
        default: self = .unknown(type: type, fallbackMarkdown: try? c.decode(String.self, forKey: .fallback_md))
        }
    }
}

public struct Datum: Decodable, Sendable, Hashable {
    let v: Double?, lo: Double?, hi: Double?
    let unit: Unit, scale: Scale?, cmp: Cmp?, basis: Basis
    let cite: [String], asOf: String?, scope: String?, label: String?
    let trust: Trust            // non-optional: the app only ever decodes ResolvedSpec
}
```

Rules:
- **Unknown `type` decodes, never throws.** It renders the engine's `fallback_md`. An older app reading a
  newer run degrades to a table, never to "failed to open run".
- **Unknown enum values decode to `.unknown`** for `Unit`, `Basis` and `SourceKind`, for the same reason.
- The app decodes `ResolvedSpec` only. `ModelSpec` exists only in TS.

### 5.2 Keeping TS and Swift in sync

**Source of truth: the Zod catalog.** Swift follows from it. There are three mechanisms, cheapest first:

1. **Emit JSON Schema from Zod** (`z.toJSONSchema`, zod 4) to `schema/qvs-resolved.schema.json`,
   committed, and regenerated by `bun run schema`. CI fails if the regenerated file differs (`git diff
   --exit-code`). Refinements don't survive into JSON Schema (the v-or-lo/hi rule, cross-field rules),
   which is fine: they're engine-side validation, not decoding shape.
2. **Golden fixtures decoded by Swift.** The engine's test suite writes `fixtures/*.resolved.json`: one
   per component, plus the real personalization answer, plus edge cases (unknown type, unknown unit,
   every trust combination). These are copied into the Swift test target by a script, not by hand.
   `swift test` decodes every fixture and asserts round-trip values. This catches *semantic* drift
   (a renamed prop) that the schema diff alone wouldn't break in Swift.
3. **A drift detector test** walks the JSON Schema's element union and asserts that the Swift `Element`
   enum has a case for every `type`, and that every required prop of each type is a stored property of
   the Swift struct. A new component in Zod fails `swift test` until the Swift side exists.

**Codegen (`quicktype` from the JSON Schema): evaluated, not recommended for the catalog.** See §8 for the
spike's measured verdict. In short, generated code handles the flat record types well (PRD 10's
`RunRecord`, `Claim`, `Citation`), but the discriminated element union and `Datum`'s v-or-range shape come
out as loosely-typed structs with every prop optional. That pushes `if let` noise into every view. The
catalog has ~15 types that change rarely, so **hand-written structs plus fixtures plus the drift detector**
are both cheaper and safer. Use codegen for the record envelope if PRD 10 wants it there.

---

## 6. Swift Charts mapping, and what it can't do well

Target is macOS 14 (`Package.swift`), so the selection APIs (`chartXSelection`, `chartYSelection`,
`chartGesture`) and annotation `overflowResolution` are available.

| Component | SwiftUI / Swift Charts building blocks | Fidelity vs mockup |
| --- | --- | --- |
| `RangeCompare` | `RuleMark(xStart:xEnd:y:)` with `.lineStyle(.init(lineWidth: 8, lineCap: .round))` for ranges, `PointMark` for points, `RectangleMark(xStart:xEnd:)` for the reference band, `.chartXScale(domain:)` plus a trailing `.annotation` arrow for off-scale values | Good. Group headers on a categorical y-axis aren't native: render one `Chart` per group with a shared x domain. |
| `BarCompare` | `BarMark(x:y:)`, `.annotation(position: .trailing)` for the value, `.chartYAxis` labels with a second line for `scope · asOf` via `AxisValueLabel { VStack }` | Good. Bars round all four corners (`.cornerRadius`), not just the data end. |
| `TrendLine` | `LineMark` + `AreaMark` (10% wash) + `PointMark`, `.chartXSelection(value:)` driving a `RuleMark` crosshair | Excellent: Swift Charts is at its best here. |
| `SmallMultiples` | `Grid` of the above, shared `.chartXScale/.chartYScale(domain:)` | Good |
| `Timeline` | `PointMark(x: .value("date", d))` + `.symbol(by: .value("kind", k))` (native circle, diamond, square), `.annotation(position: .top/.bottom)` | **Medium.** No label collision avoidance: the renderer precomputes alternating lanes. |
| `Quadrant` | `PointMark`, `RuleMark` splits, region labels as `.annotation` on invisible marks | **Medium.** Point-label collisions need a manual pass. |
| `Stat` | `Text` + `Capsule` meter. The unit waffle is a `LazyVGrid` of 50 rects or a `Canvas`. | Exact. No Charts needed. |
| `SourceMix` | An `HStack` of `Rectangle`s with 2 pt gaps, not `BarMark(stacking:)` | Exact. Charts can't put a surface gap between stacked segments. |
| `ConflictSplit`, `EvidenceTable`, `DecisionMatrix` | Plain SwiftUI `Grid` / `HStack` | Exact |
| `ArgumentMap` | `Canvas` + a small tree layout. **Not Swift Charts.** | **Hard.** Defer to v2. Nothing in the real runs needs it yet. |
| `Claim`, `Answer` prose | Existing `CitedReader` `AttributedString` with chip runs | See below |

### What Swift Charts (or SwiftUI) can't do well

1. **Trust tiers as mark *outlines*.** Charts marks are fill-only. There's no dashed or outlined `BarMark`
   or `RuleMark` border. The mockup's "close = outline, unresolved = dashed" look needs `chartOverlay` +
   `ChartProxy.position(for:)` to draw shapes over the plot. **Proposal:** express tiers as fills the
   framework supports natively. Supported is solid, close is a 45% fill, unsupported is the amber hatch via
   `ImagePaint`/`ShapeStyle` (hatching works as a foreground style), and unresolved is a 15% fill plus a
   "?" annotation. Keep outlines only in `Stat` and `ConflictSplit`, which are plain SwiftUI.
2. **Hover popover anchored to a datum.** Charts gives selection values, not mark frames. The popover is a
   `chartOverlay` that maps the selected datum back to a point with `proxy.position(forX:y:)` and places a
   custom view. That's fine, but it's custom code in every chart type. Build one `DatumHitLayer` modifier
   and reuse it everywhere.
3. **Keyboard focus on individual marks.** There's no per-mark focus. J/K over datums is implemented by
   driving the selection binding from a focus model the page owns, which matches the D1 keymap. VoiceOver
   is fine: `.accessibilityLabel/.accessibilityValue` per mark works, and the label should include the
   tier ("1 to 2 percent, verified quote").
4. **Hover on inline citation chips in prose.** SwiftUI `Text` can't attach hover to an attributed run.
   Today's chips are `openURL` links: click works, hover peek doesn't. The D1 peek-on-hover needs an
   `NSTextView` (TextKit 2) bridge for the reading column. This is the biggest SwiftUI gap on the answer
   page, it's independent of charts, and D1's direction A depends on it.
5. **Label collision** (Timeline, Quadrant). Swift Charts doesn't avoid collisions. Precompute lanes.
6. **Stacked-segment gaps and "square at the baseline, round at the data end" bars.** These are minor
   visual deviations from the HTML mockup. Accept them.

Everything else in the mockup is a straight port: the tokens (ink steps, jade/amber/iris, Instrument Sans
+ Source Serif 4), axis styling (`AxisMarks` with hairline `AxisGridLine`), the 10% area wash, 2 pt lines
and ringed points.

---

## 7. What PRD 10 should take from this

PRD 10 §2.3 already has the right pipeline. Concrete reconciliations:

| PRD 10 says | This design | Suggestion |
| --- | --- | --- |
| `Datum { value: number \| {lo,hi} \| string; citation_ids; confidence; derived?; trace }` | Flat `v / lo / hi`, `cite`, model `basis` + engine `trust{tier, trace, confidence}` | Take the flat numeric shape: no `string` values in a chart, and a union is harder for the model and for Codable. Keep PRD 10's `trace` name (used above). Rename `cite` → `citation_ids` if the record uses that everywhere. |
| Example names `KeyFigure`, `RangeEstimate`, `ComparisonTable`, `BarChart`, `ConflictView`, `SourceQualityBar`, `RankedList` | `Stat`, `RangeCompare`, `EvidenceTable`, `BarCompare`, `ConflictSplit`, `SourceMix`. `RankedList` has no equivalent: it's `BarCompare` (numeric) or `DecisionMatrix` (qualitative). | Use CATALOG.md names. PRD 10 defers to it. |
| Tier caps: Quick ≤ 2 visuals, Deep ≤ 3 | ≤ 1 per group, ≤ 3 per answer | Adopt PRD 10's per-tier caps plus the per-group rule. |
| "Answers are not streamed" | Agree for the UI. Generate as element JSONL for truncation and repair (§3). | Add "JSONL generation, single `answer` event" to §2.3. |
| `fallback_md` engine-rendered | Same, plus every component has a cited `caption` | Make the caption required: it's the accessibility label and the export text. |
| Swift types generated from JSON Schema | Hand-written catalog types + golden fixtures + drift detector; codegen for the envelope | See §5.2 and §8. |
| `dataset_id` props | Not in v1 | Inline Datums only until Wide exists. A dataset reference hides the citation one hop away. |
| Datum → claim in the claim sweep | Agree | Batch datums by their owning component, so the judge sees the chart's caption as context. |

On PRD 10 §5 (shell): this track agrees with **native for the dogfood and product phases**. The one
condition worth adding to §5's list is item 4 above. The reading column needs a TextKit 2 bridge for chip
hover. Budget it explicitly, because it is the single place where native is harder than web for this answer page.

---

## 8. Spike results

_Filled from `spikes/json-render/README.md`. See that file for commands and details._

(pending)

---

## 9. Build order

1. **Engine:** `answer/catalog.ts` (Zod, 6 components first: `Claim`, `Stat`, `RangeCompare`, `BarCompare`,
   `ConflictSplit`, `SourceMix`), prompt generation, JSONL compiler, validate, resolve (`trace`), repair,
   and `schema/qvs-resolved.schema.json`. Golden fixtures from the personalization run.
2. **App:** Codable mirror, fixture decode tests and drift detector, a `DatumHitLayer` and the source
   popover (reusing `SourceInspector`), then the 6 views, each renderable through `--render` for snapshots.
3. **Then:** `TrendLine`, `Timeline`, `DecisionMatrix`, `EvidenceTable`. Last: `Quadrant`,
   `SmallMultiples`. `ArgumentMap` waits until a real run needs it.
4. **In parallel, outside this track:** the TextKit 2 reading column (§6 item 4), needed by D1 regardless.

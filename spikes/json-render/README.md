# QVS v1 spike: catalog → constrained JSONL → validate/resolve → Swift decode

This is a throwaway reference for the answer view spec in [`docs/viz/CATALOG.md`](../../docs/viz/CATALOG.md). It covers
the Zod catalog, prompt generation, a streaming JSONL compiler, validation, trust resolution, repair, JSON Schema
emission and a Codable mirror in Swift. There is no React and no WKWebView. No model is called, because there is no
API key, so the "model output" is hand-written fixtures.

## Run it

```sh
bun install
bun test                   # 67 tests: numbers, fixtures/validate/resolve/repair, stream, schema+prompt
bun run src/demo.ts        # prompt excerpt, streaming snapshots (with a quarantined element), resolve, repair
bun run src/prompt.ts      # print the generated system-prompt catalog section (~8.2 KB, ~2k tokens)
bun run src/emit-schema.ts # regenerate schema/*.schema.json (a test fails if they're stale)
bun run src/gen-fixtures.ts# regenerate fixtures/*.resolved.json (a test fails if they're stale)
bun run typecheck          # tsc strict + noUncheckedIndexedAccess
cd swift && swift test     # 6 Swift Testing tests (8 cases): decode fixtures + schema drift detector
```

## What's here

| File | What | Written by |
| --- | --- | --- |
| `src/catalog.ts` | Zod schemas: `CiteId`, `Rich`, `Datum` (either-v-or-lo&hi refine), all 15 components, `ModelSpec` and `ResolvedSpec` built from one factory (`build("model" \| "resolved")`). Each component has a `description`, and props carry `.describe()`. | hand |
| `src/numbers.ts` | `numberInQuote` normalisation. | hand |
| `src/walk.ts` | Generic walkers (datums, cite refs, JSON pointers) shared by validate, resolve and repair. | hand |
| `src/validate.ts` | `validateSpec(spec, registry)`: per-element Zod parse mapped to named codes, then graph and semantic rules. | hand |
| `src/resolve.ts` | `resolveSpec(spec, registry)` attaches every ⚙ field. | hand |
| `src/stream.ts` | `SpecStream` JSONL compiler, `show()` snapshot printer, `chunkText()` 7–40-char token simulator. | hand |
| `src/repair.ts` | Auto-fix, then a one-retry repair prompt, then the fallback. | hand |
| `src/prompt.ts` | Generates the prompt section from the Zod catalog by walking `_zod.def`. | hand (output generated) |
| `src/emit-schema.ts` | `z.toJSONSchema` writes `schema/qvs-model.schema.json` and `schema/qvs-resolved.schema.json`. | hand (output generated) |
| `src/gen-fixtures.ts`, `src/demo.ts`, `src/index.ts` | Fixture regeneration, demo, engine-facing export surface. | hand |
| `fixtures/citations.json` | Resolved-citation registry for the personalization run: 33 citations, 28 documents. Quotes are faithful reconstructions from the angle notes, **not verbatim source text**. | hand |
| `fixtures/personalization.spec.jsonl` | What the model would stream: 25 lines, 18 elements, including 2 row appends and 3 child appends. | hand |
| `fixtures/kitchen-sink.spec.json` | Coverage for SmallMultiples, EvidenceTable, Quadrant, ArgumentMap and Stat.context. The Quadrant is **synthetic**. | hand |
| `fixtures/inconclusive.spec.json` | Inconclusive answer: Claim plus SourceMix by tier. | hand |
| `fixtures/*.resolved.json` | Output of compile → validate → resolve. | generated |
| `fixtures/invalid/*.json` (11) | `{description, expect:[codes], repair:[action kinds], spec \| jsonl}` | hand (via a one-off script) |
| `schema/*.schema.json` | JSON Schema 2020-12 (model 51 KB, resolved 56 KB, pretty-printed). | generated |
| `swift/` | SwiftPM `QVSDecode` (macOS 14, no deps): Codable mirror of `ResolvedSpec`, plus tests. | hand |

## Pipeline and formats

```
model ──JSONL add-ops──▶ SpecStream (per-line, per-element Zod) ──▶ validateSpec ──▶ repairSpec ──▶ resolveSpec ──▶ app
                          · half line never applied                  · named codes      auto → 1 retry → fallback   ⚙ trust etc.
                          · bad element → quarantined placeholder    · JSON pointers
                          · unknown child key → pending
```

The wire format is json-render's flat spec `{v, root, elements:{key:{type, props, children?}}}` streamed as RFC 6902
lines. Only four `add` targets are accepted: `/v`, `/root`, `/elements/<key>` (one complete element),
`/elements/<key>/children/-` and `/elements/<key>/props/<arrayProp>/-`. Anything else (`replace`, `remove`, a
deep prop write, re-adding an existing key) becomes `patch_rejected`. A row append re-validates the whole element
and rejects only that row.

**Zod owns the shape and validate.ts owns the rules.** Zod (and the JSON Schema emitted from it) holds types,
enums, required keys and strictness. Counts (≥ 3 data, ≤ 8 rows, 2–3 sides …), cite existence, unit consistency
and graph shape are semantic checks with their own codes, such as `chart_min_data`, `unit_mixed`, `cite_unknown`
and `cycle`. A `.min(3)` inside Zod would make the element unparseable, and an element that doesn't parse can't be
auto-downgraded to a Stat. The one exception is `cite: CiteId[].min(1)`, the core invariant, which stays in Zod.

**Severity.** §3's hard limits are `error`s. §4's "prompt guidance" limits are `warn`s, such as `visual_budget`
(more than one visual per group or more than three per answer), `stat_row`, `lead_long`, `title_long` and
`argmap_settled`. `number_not_in_quote` is also a `warn`, because the datum still renders, just marked unverified.

## How citations and confidence attach (resolve.ts)

- **Citation tier** uses the same ladder as `EvidenceIndex.tier(_:)` in QuorumCore. `match: unresolved`, an
  unknown id, or `grounding: none` gives `unresolved`. An id in `validation.unsupported_citations` gives
  `unsupported`. `fuzzy` gives `close`. Everything else is `supported`.
- **`Datum.trust`:**
  - `tier` is the worst tier across `cite[]`.
  - `numberInQuote` is true when every drawn number (v, or lo and hi) appears in at least one cited quote.
  - `confidence` follows this ladder:
    1. `unverified` if the tier is not supported/close, or the datum is `reported` and its number isn't in the quote.
    2. Otherwise `low` for an `estimate`.
    3. Otherwise `medium` for `derived` data or a `close` tier.
    4. Otherwise `high`.
  - Steps 2–4 are my invention: CATALOG only defines the floor.
- **`Claim.confidence`** keeps the model's value, unless none of its markers resolves to supported/close. Then it
  becomes `unverified`.
- **`BarCompare.mixedBasis`** is `{asOf, scope}`: true when the bars differ on that field. It is also set inside
  SmallMultiples BarCompare panels.
- **`ConflictSplit.sides[].tierMix`** counts distinct ids from the headline datum plus the summary markers.
- **`SourceMix.counts`** is `[{key, n}]`, sorted by n. `by: tier` counts distinct citation ids. `by: kind` counts
  distinct **sources** per document `kind`. The scope is `answer` (every id under the root), `group` (the parent
  group's subtree) or an explicit list of ids.
- **Item tiers.** Timeline events get `tier` and `dateInQuote` (date axis only). DecisionMatrix cells get `tier`
  when they have citations. ArgumentMap nodes get `tier`.

On the real fixture, the DoorDash $1B ads bar comes out `{tier: unsupported, numberInQuote: false, confidence:
unverified}`. The Starbucks 4–6% row comes out `close / true / medium`. `c_memory` (DoorDash blog, `unresolved`) is
floored to `unverified`. The ads chart gets `mixedBasis {asOf: true, scope: true}` (run rate vs full year vs 2024).

## Repair loop (repair.ts)

1. **Auto-fix**, deterministic and repeated until stable:
   - drop unknown keys
   - coerce `"1.5"` to `1.5`
   - drop references to missing children
   - break cycles (remove the back-edge)
   - drop orphans
   - set `root` when there is exactly one Answer
   - downgrade a chart with too few data: 1 datum becomes a Stat, 2 become an EvidenceTable
   - move a group's 3rd+ visual to the next group with room, or to a new group, or drop it
2. **One model retry.** `buildRepairPrompt` lists the issues by JSON pointer, the offending elements' current JSON,
   the catalog text for those component types only, and the valid citation ids if any were unknown. For
   `bare-number` it is about 1 KB. The reply is JSONL that replaces or removes whole elements. Replacement is
   allowed only in repair mode, never in the stream. It goes through auto-fix again. Tests drive this with a fake
   model callback.
3. **Fallback.** Invalid visuals are dropped. Prose (Answer/Group/Claim) is kept even with a `cite_unknown`: the
   unknown id resolves as `unresolved` and floors the claim. A Claim that fails its own parse is rebuilt as a bare
   `{text, confidence: "low"}`. Only a broken Answer makes the result `renderable: false`.

The 11 invalid fixtures end up as follows:

| Fixture | Repair outcome |
| --- | --- |
| `chart-two-data` | downgraded to an EvidenceTable |
| `children-cycle` | cycle broken |
| `sloppy-model` | coerced plus key dropped |
| `number-not-in-quote` | nothing to do (warn only) |
| `truncated-line` | ref to the never-arrived element dropped |
| `unknown-cite` | Claim kept, Stat dropped |
| `unknown-component`, `bare-number`, `bar-units-mixed`, `bar-asof-missing`, `quadrant-estimate` | dropped when no model retry fixes them |

## Sizes

Bundled with `bun build --minify --target=bun`. gzip uses `-9`.

| Bundle | min | gz |
| --- | --- | --- |
| catalog + validate + resolve + stream (zod external) | 28.9 KB | 10.8 KB |
| everything in `src/index.ts` incl. prompt + repair (zod external) | 38.9 KB | 14.3 KB |
| same, with zod bundled | 500 KB | 106 KB |
| zod 4 alone (`strictObject` + `toJSONSchema`, not tree-shakable) | 461 KB | 93 KB |
| `@json-render/core@0.21.0` `index.mjs` | 121 KB | 28.8 KB |
| `@json-render/core@0.21.0` chunk | 21 KB | 4.5 KB |
| json-render `createSpecStreamCompiler` alone, tree-shaken | 5.9 KB | 2.0 KB |

The engine already ships zod, so the marginal engine cost is about 11–14 KB gz. Source is ~1.3k lines of TS and ~360
lines of Swift. The 0.21.0 `index.mjs` is larger than the 77.6 KB the brief quoted for an earlier release.

**json-render comparison.** Our JSONL fixture fed to json-render's `createSpecStreamCompiler` (installed in /tmp, not
in this package) compiles to the same 18 elements, with row and child appends applied. The wire format is compatible.
Their compiler applies every op (`replace`, `remove` …) and does no per-element validation, so an invalid element
lands as-is. Ours whitelists append-only adds and quarantines. Keeping our ~150-line compiler is cheaper than
wrapping theirs.

## JSON Schema → Swift sync: verdict

- **Swift's Codable mirror is hand-written (~360 lines).** A drift test keeps it in sync. It reads
  `schema/qvs-resolved.schema.json` and checks two things in both directions:
  - the set of component `type`s equals `QVSElement.known.keys`;
  - each component's top-level prop keys equal the Swift `CodingKeys`. SmallMultiples uses the union of its variants.

  I checked that it fires: removing `Stat.context` from Swift failed `everyPropIsKnown`, while every decode test
  still passed, because `Decodable` silently ignores extra keys. Without this test, drift would go unnoticed.
  Nested shapes such as `sides[].tierMix` are covered only by decoding the generated fixtures. Extending the drift
  walk to nested objects is the next step if it's needed.
- **quicktype 26 (`npx quicktype -s schema --lang swift`) works offline-ish but isn't usable for the decode layer.**
  - It flattens the 15-way `oneOf` into one `ElementProps` struct with every prop optional (`lead?`, `bars?`,
    `cells?` …) and a separate `type` enum.
  - It merges same-named props of different shapes: RangeCompare `rows` and EvidenceTable `rows` both become
    `[[String: Headline]]`. This decodes without error and is semantically wrong.
  - It generates names like `PurpleBar` and `FluffyX`, emits `v: Double`, and has no nested discrimination for
    SmallMultiples.

  It could serve as a diff aid, but it isn't worth wiring in. Hand-written Swift plus the schema drift test is the
  recommendation.

## Findings and failure modes

- **zod 4 `toJSONSchema` silently drops `.refine()`.** It doesn't warn. The Datum either/or rule was lost until it was
  re-added as `oneOf` via the `override` hook (see `emit-schema.ts`). `lo ≤ hi` has no JSON Schema equivalent, so a
  test pins that Zod rejects `lo:3, hi:2` while the schema accepts it. Transforms throw ("cannot be represented"),
  so the catalog has none. `z.int()` emits ±2^53 bounds (cosmetic).
- **zod 4.6 `.describe()` returns a clone, but `$ref`s still work.** The clone keeps `_zod.parent`, so a described
  `Datum` emits `{description, $ref: "#/$defs/Datum"}`. `globalRegistry.get(clone)` does *not* inherit the parent's
  `id`, so the prompt generator walks `_zod.parent` to find names. Ids are global, so the resolved variants are
  suffixed (`DatumResolved`, `ElementResolved`).
- **Zod issue codes need translating for repair.** A bare number arrives as `invalid_type expected object` (or
  `invalid_union` inside `Datum | string`), and an unknown component arrives as `invalid_union` "No matching
  discriminator". `parseElement` dispatches on `type` itself and maps issues to `bare_number`, `numeric_string`,
  `unknown_key`, `missing_prop`, `invalid_enum` and `unknown_component`, which the repair loop and prompt can act on.
- **Number normalisation edge cases:**
  - A separator followed by exactly three digits is ambiguous: `2,100` and `1.500` keep both readings
    (2100/2.1 and 1.5/1500). That's what makes `$2.1B ≈ 2,100 million` work, at a small false-positive risk.
  - A range's trailing scale and `%` carry to both ends (`1-2 billion`, `5 to 15 percent`).
  - `%` and non-% never cross-match: 80% ≠ 80 restaurants.
  - Scale is compared on absolute values, so `v:2000, scale:M` matches "$2B".
  - `22/100` and `4x` work as plain numbers.
  - Not handled: written-out numbers ("three times", "a third"), fractions, "half", `bps`, and "tripled".
    "Fewer than a third" in a caption is prose and isn't checked.
- **`reported` vs the quote is the real trust signal.** The validator correctly flags the DoorDash $1B (verified quote,
  number absent). It would also flag any number the model rounds, such as "nearly 70%" drawn as 69, which is the
  intent.
- **Swift discriminated-union decoding is easy but hand-rolled.** It is a manual `init(from:)` switching on `type`,
  with an `.unknown(type)` case so a newer engine never crashes an older app. SmallMultiples needs *nested*
  discrimination: the panel props' type depends on the sibling `of`, decoded as `Panel<TrendLine>` etc. `Datum |
  string`, `Datum | number`, `string | number` (TrendLine x) and `"answer" | "group" | [ids]` each need a small
  `singleValueContainer` enum.
- **CATALOG internal inconsistencies** (handled as described under deviations below):
  - §3 says ≤ 2 visuals per group, §4 says ≤ 1.
  - Rule 1 says a chart needs ≥ 3 data, but RangeCompare allows 2–8 rows.
  - `Quadrant.split: Datum | number` contradicts "no bare-number prop anywhere".
- **The streaming UX works.** A parent arrives first with all children `…pending`, and they fill in as lines
  complete. A malformed element renders `✗key` and the rest of the stream is unaffected. The final spec is identical
  across 20 chunkings.
- **`SourceMix by kind` needs a source kind per document,** and PROTOCOL's `documents` have none. The fixture adds
  `kind` by hand. The engine needs a classifier (URL heuristics plus a cheap model call) before this works for real.

## Deviations from CATALOG.md (to fold back)

1. **`SourceKind` gains `"data-panel"`** (Second Measure, Statista panels). CATALOG §1 itself counts "2 data panels" in
   a2, but the enum had no value for them.
2. **Documents need `kind`** for `SourceMix by:"kind"` (a PROTOCOL addition, see above).
3. **Visual budget.** I treat §3 "≤ 2 visuals per group" as the hard rule (error `group_visuals`) and §4's "≤ 1 per
   group, ≤ 3 per answer" as guidance (warn `visual_budget`). `SourceMix` doesn't count as a visual.
4. **RangeCompare keeps 2–8 rows** (not ≥ 3): two ranges are four numbers on one axis. Rule 1 applies to BarCompare
   (3–8) and TrendLine points (≥ 3). A 1-row RangeCompare downgrades to a Stat.
5. **TrendLine `asOf` is not required.** The `x` value already carries the time. BarCompare `asOf` is enforced
   (`asof_missing`).
6. **Extra ⚙ engine fields beyond CATALOG:**
   - `Timeline.events[].tier` and `dateInQuote?`
   - `DecisionMatrix.cells[].tier?`
   - `ArgumentMap.nodes[].tier`
   - `SourceMix.counts` as `[{key, n}]`, which keeps order and avoids `[String: Int]` keys in Swift

   These are the "same numberInQuote check on the year" made concrete, plus tiers for the other cite-bearing items.
7. **Datum confidence ladder** (high/medium/low below the floor) is defined here. CATALOG only defines the floor.
8. **SmallMultiples panel props omit `caption`.** The component's own caption covers them. Swift models chart
   `caption` as optional for that reason.
9. **`DecisionMatrix.cells[].cite` may be empty** in the schema (for `null` cells). "Non-null needs a cite" is the
   semantic rule `matrix_cell_uncited`.
10. **Group children** can't be Answer/Group (`group_children`), and Answer children must be Groups
    (`answer_children`). This is implied by CATALOG but not stated as a rule.
11. **`Quadrant.split` keeps `Datum | number`** as CATALOG says. It is the single sanctioned bare number (a drawn split
    line, not a claim). Worth stating explicitly next to "no bare-number prop anywhere".

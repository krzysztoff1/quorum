# json-render evaluation

[json-render](https://json-render.dev) (Vercel Labs; `@json-render/core` + `@json-render/react`) was the
candidate technology for Quorum's visual answers. This note records what it is, how it measured, what
Quorum borrows from it under the owner's decision (b), and what the spike in
[`spikes/json-render/`](../../spikes/json-render/) found. The design itself is in
[`RECOMMENDATION.md`](RECOMMENDATION.md).

## What it is

json-render has four parts:
- **Catalog.** You define components and actions with Zod props and a description each (`defineCatalog`).
- **Prompt.** `catalog.prompt()` generates the system-prompt section that tells the model what it may emit.
- **Spec.** The model emits a flat element map: `{ root, elements: { key: { type, props, children: [keys] } } }`.
- **SpecStream.** The spec streams as JSONL [RFC 6902](https://datatracker.ietf.org/doc/html/rfc6902) patches,
  one per line, compiled progressively by `createSpecStreamCompiler`. `validateSpec` / `autoFixSpec` check
  and patch common issues.

Renderers are `@json-render/react`, `react-native` and `react-pdf`. There is no SwiftUI renderer. Other
features (`$state` bindings, `$computed`, visibility conditions, actions, state-store adapters) target
interactive generative UIs, not a read-only answer.

## Measured (npm tarballs, gzip -9)

| Package | Dist entry, raw | gzip | Runtime deps |
| --- | --- | --- | --- |
| `@json-render/core` 0.19.0 | 77.6 KB + 19.8 KB shared chunk | 18.3 KB + 4.2 KB | `zod ^4` (peer) |
| `@json-render/core` 0.21.0 (latest) | 121 KB + 21 KB chunk | 28.8 KB + 4.5 KB | `zod ^4` (peer) |
| `@json-render/react` 0.19.0 | 51.8 KB + 5.0 KB chunk | 11.3 KB + 2.1 KB | `@json-render/core`, `react ^19.2` (peer) |
| json-render `createSpecStreamCompiler` alone, tree-shaken | 5.9 KB min | 2.0 KB | |
| **Quorum spike**: catalog + validate + resolve + stream (zod external) | 28.9 KB min | 10.8 KB | `zod` (engine has it) |
| **Quorum spike**: everything incl. prompt + repair | 38.9 KB min | 14.3 KB | |

`core` grew by about 55% in two minor releases. It is pre-1.0 and moving fast, which is another reason to
borrow the formats rather than pin the package. Option (a) would have put ≈ 45 KB gz of json-render, plus
React 19 and a chart library, into a WKWebView.

## Verdict

**Borrow the formats. Don't take the dependency.** This is option (b), decided by the owner on 2026-10-09.

| json-render idea | Quorum | Why |
| --- | --- | --- |
| Catalog in Zod, one source for prompt and validation | **Adopt** (engine `answer/catalog.ts`) | The prompt and the validator can't drift. That is the main value. |
| `catalog.prompt()` | **Adopt the idea**, ~60 lines of our own | We need per-component use/avoid rules and the Datum contract in the prompt, not generic UI guidance. |
| Flat element map | **Adopt as is** | It maps to SwiftUI directly (element-keyed views, `ForEach` over children), and PRD 10 adopts it too. |
| SpecStream (JSONL RFC 6902 patches) | **Adopt, narrowed**: `add` only, one complete element per line, whitelisted paths | Truncation-safe generation and per-element validation. `replace`/`remove`/`move` would let the model rewrite accepted visuals. |
| `validateSpec` / `autoFixSpec` | **Replace** with our validator and three-layer repair | Our failures are about trust (unknown cite id, number not in quote), which json-render knows nothing about. |
| `$state`, `$computed`, actions, visibility | **Skip** | A trusted answer is read-only. Computed values would be numbers that no source says. |
| React renderer | **Skip** (no WKWebView, no web shell) | The trust path (datum → quote → PDFKit/snapshot) is already native. A share page can still use it later on the same stored spec. |

## What json-render doesn't give us (and we built)

1. **Per-datum provenance.** json-render props are free-form. Quorum's catalog has no bare-number prop:
   every number is a `Datum` with `cite[]`, and the engine attaches `trust` (tier, trace, confidence).
2. **Numeric trace.** The check that the plotted value is actually in a located quote, after normalizing
   ranges, units and scales. This is the core trust feature for charts.
3. **Engine-derived components.** `SourceMix` and conflict tier mixes are counted by the engine. The model
   only places them.
4. **Budget and downgrade rules.** ≤ 3 visuals per answer, ≥ 3 data per chart, and majority-untraced
   charts become tables.

## Spike findings

_See [`spikes/json-render/README.md`](../../spikes/json-render/README.md) for commands and details._

The spike implements the borrowed parts for real.
- **TS (Bun, zod 4):** Zod catalog of all 15 components, prompt generator, JSONL stream compiler,
  validator, resolver (tier, numeric trace, confidence), three-layer repair, and JSON Schema export.
- **Swift package:** decodes the resolved fixtures.
- **Tests:** `bun test` 67/67, and `swift test` green.

### What worked

- **The wire format is compatible with json-render.** Our personalization JSONL (25 lines) fed to
  json-render's own `createSpecStreamCompiler` builds the same 18 elements, row and child appends included.
  A future React share page could consume our stored specs.
- **Streaming behaves as designed.**
  - Half-received lines are never applied.
  - Children that haven't arrived render as pending.
  - Invalid elements are quarantined while the stream continues.
  - The final spec is identical across 20 random chunkings (7–40 chars).
- **Citations and confidence attach cleanly.**
  - The model writes `cite[]` and `basis`. The resolver adds `trust{tier, numberInQuote, confidence}`.
  - On the real run: DoorDash's $1B resolves to unsupported / not in quote / unverified, the Starbucks
    figure to close / medium, and the 403'd DoorDash blog claim is floored to unverified.
  - The ads chart gets `mixedBasis`.
- **Repair keeps prose alive.**
  - Deterministic fixes cover a 2-bar chart (→ table), cycles, sloppy keys, number strings and dangling
    references.
  - One model retry gets a compact repair prompt that addresses issues by JSON pointer.
  - After that, the visual is dropped.
  - Only a broken `Answer` root makes a spec unrenderable.

### Failure modes and surprises

1. **Zod 4's `toJSONSchema` silently drops `.refine()`.** The Datum "v, or lo and hi" rule vanished
   from the schema without a warning. It was re-added via the `override` hook as a `oneOf`. `lo ≤ hi`
   can't be expressed at all, so it's Zod-only and pinned by a test. Transforms throw, so the catalog
   uses none.
2. **Zod errors are useless for repair as-is.** A bare number surfaces as a generic type or union error,
   and an unknown component as "No matching discriminator". The validator dispatches on `type` itself and
   translates the error into codes the repair layer can act on: `bare_number`, `numeric_string`,
   `unknown_key`, `missing_prop`, `invalid_enum`, `unknown_component`.
3. **Count rules must not live in Zod.** A `.min(3)` makes a 2-bar chart unparseable, and then it can't
   be downgraded to a table. Zod holds shape. Counts, citation existence and units are separate rules
   with codes.
4. **json-render's compiler is too permissive for us.** It applies `replace`/`remove`/`move` and doesn't
   validate elements. Our ~150-line append-only compiler is cheaper than wrapping it.
5. **Number normalization has an ambiguity:**
   - `2,100` and `1.500` are ambiguous. The matcher keeps both readings, which is what matches `$2.1B` to
     "2,100 million", at a small false-positive risk.
   - Written-out numbers ("a third", "tripled"), fractions and basis points don't match. Those datums
     come out untraced, which is the safe failure.
6. **`SourceMix` by kind can't work on today's protocol.** `documents` carry no source kind. The fixture
   is hand-labelled, and the engine needs a classifier.
7. **JSON Schema → Swift codegen (quicktype 26) is wrong in a quiet way.**
   - It flattens the element union into one all-optional struct.
   - It merges same-named props of different shapes: RangeCompare and EvidenceTable `rows` become one
     type that decodes without error.

   Instead: hand-written Codable plus a two-way drift test against the schema. The drift test is the only
   thing that caught a deliberately removed Swift prop, because `Decodable` ignores unknown keys.

There was no API key in the environment, so the spec is hand-written to match what the synthesis model
would emit, not generated. The first live run should record a real model-emitted spec as a fixture and
count how often each repair layer fires.

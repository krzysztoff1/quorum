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

## Measured (v0.19.0, inspected from the npm tarballs)

| Package | Dist entry, raw | gzip -9 | Runtime deps |
| --- | --- | --- | --- |
| `@json-render/core` | 77.6 KB + 19.8 KB shared chunk | 18.3 KB + 4.2 KB | `zod ^4` (peer) |
| `@json-render/react` | 51.8 KB + 5.0 KB chunk | 11.3 KB + 2.1 KB | `@json-render/core`, `react ^19.2` (peer) |

The browser cost of option (a) would therefore have been ≈ 36 KB gzip for json-render, plus React 19
(≈ 60 KB gzip) and a chart library, inside a WKWebView. npm listed 0.21.0 as the latest at the time, and
0.19.0 was the cached tarball. The API is still pre-1.0 and moving.

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

_See [`spikes/json-render/README.md`](../../spikes/json-render/README.md) for commands._

(pending: filled when the spike completes)

# Shell analysis: native SwiftUI vs a web UI

Supporting research for [PRD 10](10-architecture-rethink.md) §5. It answers the brief's question 5: is native
SwiftUI still the right shell for a Linear-grade, keyboard-first UI and an eventual product, compared with a web
UI over the same engine?

**Outcome:** keep native for dogfooding *and* for the product app, as a pure renderer of an engine-written record.
Add a second, web renderer of the same answer spec only when sharing or a second platform needs it.

Owner decision (b) (2026-10-09) settled the visual components: a Zod catalog validated in the engine, rendered
by SwiftUI and Swift Charts. That is a strong signal for native. This page records the reasoning, so the
decision can be revisited with the facts in hand.

## 1. What the question really depends on

The shell choice is cheap to reverse only if the layers below it don't care which renderer reads them. PRD 10
makes them renderer-agnostic:
- one engine-written record (`run.json`, JSON Schema exported from Zod)
- a json-render-shaped answer spec (`{v, root, elements}`)
- engine-decided `display`, `trust` and `fallback_md`

With that in place, "SwiftUI or web" decides only **how fast and how well the screens get built and verified**.
It doesn't decide where logic lives. Without it, the choice would also decide how much domain logic gets
duplicated, which is the problem behind today's drift (`current-architecture.md` §8).

## 2. Facts gathered

| Fact | Source | Bears on |
|---|---|---|
| The UI target is 8,152 lines. The UX proposal replaces most reading surfaces. `CitedReader`, `SourceInspector`, the graph view (as "Show the work") and the `QuickSwitch` ranking survive. | `inventory.md` §2, UX `PROPOSAL.md` §6.4 | Much of the UI gets rebuilt either way. Native's sunk-cost advantage is the trust plumbing (PDFKit and snapshot inspectors), not the screens. |
| The D1 and UX mockups are HTML/CSS with a token set (blue-ink dark theme, Instrument Sans / Source Serif 4, hairlines at 7.5–13%) | `design/mockups/answer-page/`, `design/ux-rethink/` | A web UI could lift them nearly 1:1. Native has to translate the tokens. |
| Every QVS component maps to Swift Charts or SwiftUI at low effort, except `Timeline`/`Quadrant` (medium, label collision) and `ArgumentMap` (high, custom `Canvas`) | `docs/viz/CATALOG.md` §5 | Native visuals are feasible. Defer `ArgumentMap`. |
| The reading column needs a **TextKit 2 bridge** for chip hover. It is "the single place where native is harder than web for this answer page." | `docs/viz/RECOMMENDATION.md` §6–7 | A real native cost; budget it explicitly |
| json-render ships React and React Native renderers only. Its catalog is Zod; its spec is a flat element map streamed as JSONL patches. | json-render.dev (fetched 2026-10-09), `docs/viz/JSON-RENDER-EVALUATION.md` | The data formats carry over to native; the renderer doesn't. A web share page could use `@json-render/react` directly. |
| The engine uses only `node:` modules (child_process, crypto, fs, path, stream, url). No Bun-specific APIs. | `grep` over `engine/src` | An Electron shell could run the engine in-process. A Tauri shell would run it as a sidecar. Either is possible later. |
| The app already renders views off-screen (`GraphSnapshot` uses `ImageRenderer` for `--snapshot`) | `Sources/Quorum/GraphSnapshot.swift` | A `--render <run.json>` mode is a small extension. It gives agents and CI eyes on native views. |
| Several features shipped "never visually confirmed": PRDs 03 and 04 and the graph polish | Project notes | Verification tooling matters more than the choice of toolkit (see `verification.md`) |
| Linear's desktop app is a web app in Electron | public knowledge | The Linear-grade bar is about design discipline, not toolkit. Web can reach it, and so can native. |

## 3. Options

| Option | Shape | For | Against |
|---|---|---|---|
| **A. Native SwiftUI** (chosen) | The app renders the record; Swift Charts draws the visuals | <ul><li>The trust path (datum → quote → PDFKit/snapshot) stays in one process and already exists.</li><li>Swift Charts quality.</li><li>Native menu bar, notifications, global hotkey, power handling.</li><li>No new toolchain.</li></ul> | <ul><li>Keyboard focus, `List` performance and inline chips in text need care (TextKit 2).</li><li>Weaker agent tooling.</li><li>A share page needs a second renderer.</li></ul> |
| B. React in a WKWebView, inside the Swift app | Native shell, web reading surfaces | Reuses the mockups 1:1; `@json-render/react` | <ul><li>Two UI stacks in one app.</li><li>The datum → inspector path crosses a JS bridge.</li><li>Keyboard shortcuts conflict between the web view and menus.</li></ul> |
| C. Tauri (Rust + system WebView) + engine sidecar | Full web UI | <ul><li>Cross-platform.</li><li>Small binary.</li><li>First-class sidecar support.</li></ul> | <ul><li>A Rust toolchain.</li><li>Rebuild every surface, including the inspectors (PDF via pdf.js).</li></ul> |
| D. Electron + engine in-process | Full web UI, Node main process | <ul><li>The engine imports directly, which removes the binary packaging problem entirely.</li><li>The Linear precedent.</li></ul> | <ul><li>Footprint (Chromium).</li><li>Rebuild every surface.</li><li>"Feels like a web app" risk.</li></ul> |
| E. Local web app in the browser (`engine serve`) | Engine serves the UI and SSE | Fastest to prototype | <ul><li>No global hotkey or native notifications.</li><li>It's a browser tab, not a tool.</li></ul> |

### Scored against what matters now

| Criterion (weight) | A native | B hybrid | C/D web shell |
|---|---|---|---|
| Trust path quality: inspector, highlights (high) | ●●● | ●● | ●● |
| Speed to the first dogfood-ready new UX (high) | ●●● (app exists; ~13 catalog views) | ●● | ● (rebuild everything) |
| Linear-grade keyboard and density (high) | ●● (achievable, needs TextKit 2 and focus work) | ●●● | ●●● |
| Agent buildability and visual verification (medium) | ●● (with `--render` + snapshots) | ●●● | ●●● |
| One source of domain types (medium) | ●● (envelope codegen + hand-written catalog with drift detector) | ●● | ●●● |
| Sharing an answer (low now, high later) | ● (needs a second renderer) | ●● | ●●● |
| Cross-platform (low now) | ● | ● | ●●● |

## 4. Recommendation

**Dogfood phase: A.** Keep the SwiftUI app as a pure renderer of the record.

**Product phase: stay A for the app.** Add a web renderer of the *same answer spec* for sharing: either an
engine `export --format html`, or a small React page using `@json-render/react`. Revisit the shell only if a
second platform or team use becomes a goal. Then the candidates are C or D, and the engine, record and catalog
carry over unchanged.

**Disclosure.** Before decision (b) I leaned toward B or C. The reasons were that agents can drive and screenshot
web UIs headlessly, the mockups are HTML, and domain types would live in one language. PRD 10's architecture
removes most of that argument:
- Once the app holds no domain logic, the duplication shrinks to generated or drift-checked types.
- `--render` gives agents eyes.
- Native wins the part that *is* the product: the trust path.

### Conditions that keep native viable (review rules)

1. **The app never regains domain logic.** It doesn't build prompts, parse model output, count, title, match
   quotes or write run data (PRD 10 §1.2).
2. **Types stay in sync mechanically:**
   - Record envelope types are generated from `schema/run.schema.json`.
   - Catalog element types are hand-written, as `docs/viz/RECOMMENDATION.md` §5 recommends after the spike:
     codegen turns the element union and the `Datum` shape into all-optional structs.
   - Golden fixture decode tests and a drift detector keep them honest.
3. **Every view is renderable from a fixture** (`--render`), and catalog components are snapshot-tested.
4. **The TextKit 2 reading column is budgeted as its own work item.** It's needed by D1 regardless.

### Triggers to revisit

- **Sharing.** The owner wants to forward a verified answer to colleagues. Build the web renderer, not a new shell.
- **A second platform**, or several users on one record store. Evaluate C or D then.
- **Native velocity stalls.** If, after M9, new screens take markedly longer natively than the HTML mockups
  suggest they would on the web, run a time-boxed B spike on the answer page.

## 5. Cost sketch

| Path | Up-front cost | Ongoing cost |
|---|---|---|
| A (chosen) | ~13 catalog views; the TextKit 2 column; `--render`; the rewritten shell per UX (M9) | Each new component in Swift as well as Zod; drift detector maintenance |
| Web share renderer (later) | One React page over the stored spec, or an engine HTML export | Each component twice (Swift + web), unless the share view is the `fallback_md` tables only |
| C/D full web shell (if triggered) | Rebuild every surface plus PDF/snapshot inspectors; packaging | One UI stack; strongest agent tooling |

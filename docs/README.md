# Docs index

Research, design and decision notes for Quorum. Start here to find a doc. Each link is relative to this folder.

## Decisions (2026-10-09)

- Engine-only pipeline; the Swift fallback is deleted. Dogfood an installed .app.
- Subscription evidence: engine direct fetch only (no Jina, no paid key required).
- UX shape C: inbox of questions, each a short thread (scoping → answer → follow-ups). Answer page = D1 A+B merge (answer.html), no Linear icons.
- Deleted: plan review, spawning + approvals, post-run Chat, Benchmark (git tag first), dry-run executor, note-appending writer, presets/templates/model pickers. Old runs not imported; brain folder moves out of the repo.
- Quick: quote checks only (no critics), hard 4:30 cutoff with partial answer. Follow-ups default to Quick.
- Numbers not found in their quote are shown flagged unverified. Scoping always shows the resolved question for one-key confirm.
- TextKit 2 hover on citation chips is planned (M5). Sources get a type label (primary / vendor / SEO / academic / news).
- Build plan: PRD 10 migration steps M1–M11.

The build plan is in [PRD 10](architecture/10-architecture-rethink.md), section 7.

## Architecture

- [PRD 10: architecture rethink](architecture/10-architecture-rethink.md): one engine, one record, one contract. The proposal and migration plan.
- [Current architecture map](architecture/current-architecture.md): how a run executes today, with file:line evidence.
- [Kill / keep / freeze inventory](architecture/inventory.md): per-file table with line counts.
- [Shell analysis](architecture/shell-analysis.md): native SwiftUI vs a web UI, with the options and recommendation.
- [Verification strategy](architecture/verification.md): the verification ladder (L0–L5) and why "never run live" happened.
- [M3: the verification floor](architecture/m3-verification.md): what each rung guarantees now, the canary, the installed app.
- [M4: the canonical run record](architecture/m4-run-record.md): `run.json` written by the engine, the `~/Quorum` brain folder, `stats`, the record checks and `export --md`.
- [PR checklist](architecture/pr-checklist.md): canary result for engine changes, screenshot for UI changes.

## UX

- [UX audit](ux-rethink/AUDIT.md): the current app, with screenshots in [`docs/ux-rethink/screens/`](ux-rethink/screens/).
- [UX proposal](ux-rethink/PROPOSAL.md): IA, concepts, flows, keyboard map, and the engine hand-off.
- [UX mockups](../design/ux-rethink/index.html): clickable screens for the shape comparison and journey (source in [`design/ux-rethink/`](../design/ux-rethink/)).

## Design

- [Answer page (design track D1)](design/answer-page.md): design notes, decisions and proposed tokens.
- [Answer page mockups](../design/mockups/answer-page/answer.html): the chosen direction (A + B). The other two directions and screenshots are in [`design/mockups/answer-page/`](../design/mockups/answer-page/).

## Visualization

- [Inventory](viz/INVENTORY.md): which content in the real runs wants which visual.
- [Visualization catalog (QVS v1)](viz/CATALOG.md): the spec format and 15 components, with use and don't-use rules.
- [Integration design (option b)](viz/RECOMMENDATION.md): validation, streaming, Swift Charts mapping, and reconciliation with PRD 10.
- [json-render evaluation](viz/JSON-RENDER-EVALUATION.md): what we borrow and what we don't.
- [Viz mockup](../design/viz/mockups/answer-viz.html): the personalization answer with 8 components (source in [`design/viz/`](../design/viz/)).
- [json-render spike](../spikes/json-render/README.md): throwaway reference code for the catalog, validator, resolver and stream compiler.

## Market

- [Competitive landscape](competitive-landscape.md): AI deep-research tools, as of 2026-10-09.
- [Raw research notes](research/): six files covering Manus and entrants, ChatGPT and Gemini, Perplexity / Claude / Grok, Elicit and citation studies, visual presentation, and a draft benchmark protocol ([06](research/06-benchmark-protocol-draft.md)).

## Reliability

- [Dogfood Phase 1 findings](reliability/p1-findings.md): the reliability pass and its root cause.
- [Run validation, 2026-08-10](run-validation-2026-08-10.md): a real food-tech run, checked end to end.

# Architecture

| Doc | What it is |
|---|---|
| [10-architecture-rethink.md](10-architecture-rethink.md) | **PRD 10**, the proposal: one engine, one record, one contract. The same text lives in `prds/10-architecture-rethink.md` (gitignored, next to PRDs 00–09); only the link paths differ. |
| [current-architecture.md](current-architecture.md) | How a run executes today, where every artifact and number comes from, what's duplicated across Swift and TS. File:line evidence at `4f16287`. |
| [inventory.md](inventory.md) | Per-file kill / keep / freeze table with line counts for all Swift and engine sources and tests, plus the hidden dependencies that fix the migration order |
| [shell-analysis.md](shell-analysis.md) | Native SwiftUI vs a web UI: facts, options A–E, scoring, the recommendation and its conditions, and the triggers to revisit |
| [verification.md](verification.md) | Why "never run live" happened and the verification ladder (L0–L5): CI end-to-end, replay fixtures, the live canary, `check` invariants, process rules |
| [m3-verification.md](m3-verification.md) | M3: what each rung guarantees now, the canary and how to schedule it, the installed app |
| [m4-run-record.md](m4-run-record.md) | M4: the run record the engine writes, the brain folder, `stats` and `check`, `export --md`, what the app reads and what was deleted |
| [m6-contract-v5.md](m6-contract-v5.md) | M6: protocol v5, the new commands, detached runs and re-attach, liveness events, the approvals and spawning deleted |
| [pr-checklist.md](pr-checklist.md) | PR rules: canary result for engine changes, screenshot for UI changes |

**Related research elsewhere in `docs/`:**
- `docs/ux-rethink/` (UX audit and proposal)
- `docs/viz/` (the QVS catalog and the native integration design)
- `docs/reliability/p1-findings.md` (the P1 root cause)
- `docs/run-validation-2026-08-10.md`
- `docs/competitive-landscape.md`

These live on their own `dogfood/*` branches until merged.

# M10: the legacy sweep

Pure deletion and relocation, no new behaviour. PRD 10 §7.1, step M10.

## App

- Removed the BYOK settings pane, `Keychain.swift`, `RunProfile.swift` (profiles, `ExperimentalProfiles`, `ModelID`,
  `CodexModel`, `ExecutorKind`), the Codex CLI probe, and the key plumbing into `EngineRunClient.start`.
  Settings keeps the store location, notifications, the terminal picker and Doctor.
- Removed types and helpers nothing reached after M9: `NodeStyleIcon`, `ResearchAngle` (kept as a test helper),
  `TopicRole`, `RunPhaseSummary`, the notes tree, `FocusRing`, `nodesMatching`, `isSpent`, `openTerminal` and a few
  unused tokens. The notes editor, note writer, Chat, RunTitler, Benchmark, dry run, plan review and approvals were
  already gone in M2-M9.
- `.gitignore` no longer reserves a repo-local `/Quorum/`; the default store is `~/Quorum`.

## Engine

- Moved to `engine/src/frozen/` (tests in `engine/tests/frozen/`): `agent.ts`, `codex.ts`, `pricing.ts`, `engine.ts`
  (single-topic runner), `record-fixture.ts`, the `resolveModel` half of `providers.ts`, and the price half of
  `config.ts` (`priceConfig.ts`).
- Extracted what the default path still needs: `parseFencedJson` into `fence.ts`, page reading into `pageRead.ts`,
  `SearchLike` into `search.ts`.
- `runTopic` accepts only `claude-code[/alias]`; the `research` command is gone (`quorum-engine` with no known
  command prints usage and exits 2). `args.ts` lost the single-topic flags.
- Kept on purpose: `search.ts` (Tavily/Brave) because `mcp-serve` and the CLI backend still use it as an optional
  env-key feature.
- Deleted: the per-run shared search client, the engine and Codex branches of `backend.ts`, `isChart`, `IdFactory`,
  and the tests that only covered them. The four transcript fixtures were re-recorded because their fake topics now
  report `backend: "cli"`.

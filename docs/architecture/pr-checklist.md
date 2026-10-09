# PR checklist

The rules that make "never run live" impossible to merge. The ladder behind them is in
[verification.md](verification.md); what each rung guarantees today is in [m3-verification.md](m3-verification.md).

## Always

- CI is green: `engine` (typecheck and unit tests), `e2e` (the compiled engine end to end) and `test` (`swift test`).
- A recorded fixture changed only on purpose. Fixtures live in `engine/fixtures/` and are compared, never silently
  overwritten. Re-record with `cd engine && bun run fixtures:update`, then review the diff.

## Engine changes need a canary run

Required when the PR touches `engine/src` run paths, prompts, the protocol, the record schema or the catalog.

1. Install what you are about to merge: `scripts/install.sh`.
2. Run `scripts/canary.sh`. It runs one cheap live Quick-ish run through your Claude subscription (Haiku, 1 angle,
   1 round), then `quorum-engine check`.
3. Paste its single `PASS` or `FAIL` line into the PR. A `FAIL` blocks the merge until it is explained.

If the PR bumps the protocol, the record schema or the catalog version, re-record the fixtures too.

## UI changes need a screenshot

Required for anything a person can see.

1. Install the build under review: `scripts/install.sh --open`.
2. Attach a screenshot of the installed app showing the change. `swift run` is not enough, because it takes a different
   engine path than the app you will actually dogfood.

## Docs-only and test-only PRs

Neither needs a canary run or a screenshot.

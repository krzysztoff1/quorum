# M7: scoping

PRD 10 §7.1, step M7, built from §4.2 (scoping) and §4.3 (follow-ups), the UX proposal's shape C (composer and scoping flow) and the owner decisions of 2026-10-09.

**Branch:** `dogfood/m7-scoping`, on `main` at `2b7a29a` (M6). M5 (answer spec) runs in parallel; this step stays out of the answer view, synthesis and the record's answer fields.

## What the owner decided, and where it lives

| Decision | Where |
|---|---|
| Always show the resolved question before a run, one key (Enter) to confirm. Ask clarifying questions only when the question is vague, never more than a short exchange | `ScopingFlow` (Core): a clear question goes straight to the confirm card; a vague one gets one round of at most two questions (engine cap three), and the second `scope` call always returns a brief |
| The run's title is `brief.title`, never a model's clarifying reply | `newQuestion` builds `question.json` from the brief; `check` fails any other title |
| Research agents never ask the user anything | One shared paragraph in the research, synthesis and planning system prompts |
| The output language is the question's, scoping exchange and title included | The scoper writes every string in the question's language; `brief.language` is told to every agent; `check` compares |
| Follow-ups default to Quick | `scope` with a `parent_run_id` is always `quick` (no follow-up UI exists yet; that is M9) |
| Quick \| Deep picker in the composer, Quick by default, room for Wide, the scoper may recommend Deep with a reason | `Tier`, the composer's segmented control (⇥ flips it) and the confirm card's two rows. Tier behaviour is M8: M7 only carries it |

## The `scope` command

Stateless; one tool-less call on `claude-haiku-4-5` through the `claude` CLI, 45 s at most. Reference: [`engine/PROTOCOL.md`](../../engine/PROTOCOL.md).

```
in   {question, clarifications?: [{question, answer}], parent_run_id?}
out  {needs_scoping, brief, questions?: [{id, text, multi, options: [{id, label}]}], fallback_reason?}
```

### The `Brief`

One shape, used on the wire, in `question.json` and in `run.json` (`brief`):

```ts
Brief {
  asked: string               // the user's own words
  question: string            // the RESOLVED question: what the agents are given
  title: string               // <= 60 chars, a noun phrase, in the question's language
  language: string            // ISO 639-1, or "und"
  tier: "quick" | "deep"      // what will run: the user's choice
  suggested_tier: "quick" | "deep"
  tier_reason: string         // one line, in the question's language
  clarifications: { question: string; answer: string }[]
}
```

`question` keeps the name M4 gave it (the text a run researches, which is now the resolved one) so every record on disk still validates: the new fields are all optional in the schema, which stays `quorum.run/1`. The engine always writes them. A record from before M7 has no `title`; `StoredRun.title` and `check` fall back to the old behaviour for it.

### How it behaves

- **Clear question:** `needs_scoping: false` and a brief. Typos are fixed in `question`; `asked` keeps the user's words.
- **Vague question:** `needs_scoping: true`, a proposal brief, and the questions. The app asks them, then calls `scope` again with `clarifications`. That reply is always a brief: there is no third round, and a model that asks again is ignored.
- **The model cannot help** (signed out, timeout, junk reply): still a brief, made from the user's own words, with `fallback_reason`. The confirm card says so. If the engine cannot even be launched the app does the same without a brief, and the run's engine makes one.
- **Title guard:** a title that is empty, long, an apology, a request to clarify or a question back to the user is replaced by one cut from the resolved question.
- **Isolation.** The scoper is run with `--safe-mode --no-session-persistence` from `$TMPDIR/quorum-isolated`. The first live try ran from the repo: the CLI loaded CLAUDE.md and memory, and a Polish question about personalisation came back resolved as "personalisation in research apps such as Quorum". The same try spent 10 s of system CPU scanning a temp folder of 12,000 entries. The planner, synthesis and validators still run unisolated; that is a follow-up (they are not scoping, and changing them moves the canary).
- **Latency.** Live Haiku through the CLI answers a clear English question in about 6 s and a vague Polish one, with two questions, in 9 to 12 s. The UX proposal's "under 2 s" is not reachable through a CLI cold start (a one-word call alone takes 3 s). The composer shows "Reading your question…" and Esc goes back to editing.

## The run

`run`'s stdin config gains `brief` (what the app got from `scope`, with the user's tier) and `tier`. The engine researches `brief.question`, titles the question `brief.title` (`title_source: "scope"`), tells every agent the language of the words the user typed (`brief.asked`) and `brief.language` ("The language code is "pl""), gives the planner and the synthesis the user's `clarifications`, and keeps the brief in `run.json`. `title_source` is `"scope"` whenever a brief is carried. With no brief (the canary, `--replay`, an engine that could not scope) it makes one from the question and any `clarifications` in the config, Quick.

The "don't ask" paragraph, in the research, synthesis and planning prompts: *the scope is fixed and nobody is there to answer. Never ask the user a question, never ask for clarification, never offer options: state the assumption in one line and carry on.*

### Integrity checks

| Check | Fails when | Warns when |
|---|---|---|
| `title` | `question.title` is not `brief.title`; or the old guard (apology, clarifier, question back) trips on a scoped title | no `question.json` |
| `language` | `question.json`'s language is not `brief.language`, or `brief.language` is not the language of the words the user typed (`brief.asked`) | the title, or the answer, reads as another language than the brief's |

The warnings stay warnings because the language detector is a stopword heuristic and short titles are noisy.

## The composer

`ScopingFlow` is a pure state machine in `QuorumCore` (28 tests): drafting → scoping → clarifying → confirming. The SwiftUI view (`ScopingView`) renders it; keys go through one `NSEvent` monitor, because `.focusable()` + `onKeyPress` never received them in the first build.

| Step | Keys |
|---|---|
| Drafting | ↩ asks (⇧↩ newline), ⇥ flips Quick / Deep |
| Clarifying | row 1 `1`–`4`, row 2 `Q W E R`, row 3 `A S D F` pick; ↩ continues; Esc back to your words; "…or say it in your own words" |
| Confirming | ↩ starts, ⇥ flips Quick / Deep, `E` edits the resolved question, Esc back to your words; "Research my original wording" sends no brief |

The two angle counts (Quick 3, Deep 5) replace the old "How many angles?" picker until M8 defines the tiers. The sidebar row and the run header show `brief.title`.

## Deleted

| What | Lines |
|---|---|
| `Chat.swift` (`ChatModel`, `ChatRunner`, `ChatSeed`, `SessionHistory`, `ChatView`, `ChatBubble`, `ProjectFileScan`); the 112 lines of `TerminalApp` and `ClaudeCodeLauncher` moved to `ClaudeCodeLauncher.swift` unchanged | 501 − 112 = **389** |
| `Mention.swift` and `MentionTests.swift` (the chat's @-mention autocomplete) | 50 + 35 = **85** |
| The Chat tab, the chat model picker and the chat session seeding in `Views.swift`; chat wording elsewhere | **65** |

The commit alone is +137 −667. `RunTitler` was already gone: M4 removed it with the digest and report writers, so there was nothing of it left to delete. "Open in Claude Code" is kept: the note context menu and, for a topic that has a CLI session, the toolbar's Continue and Fork.

Added: engine `scope` (+`brief.ts`, +prompts), the flow, the view and their tests. Whole branch against `2b7a29a`: Swift sources and tests +1,210 −751, engine sources +245 −43, engine tests, e2e and fixtures +681 −37.

## Verification

- `swift build`, `swift test`: **349** tests (325 at M6; 28 new for the flow, the scope reply and the keys, one for the legacy title fallback, 35 removed with `Mention`).
- `cd engine && bun run typecheck && bun run test`: **661** unit tests (621 at M6). `scope` has 27 of its own, covering a clear question, a typo, a vague Polish question, the three-question cap, the second call never asking again, follow-ups staying Quick, title guards, every fallback and the real CLI call (arguments, isolation, signed out).
- `bun run test:e2e`: **30** tests (25 at M6). New: `scope` against the compiled binary for a clear English question, a typo, a vague Polish question then its answers, and a signed-out CLI; and a scoped run whose question is titled `brief.title`, whose record carries the brief and tier, and whose `check` passes.
- **CI on PR #14** (`engine`, `e2e`, `test`): all green.
- **Live scoper** (Haiku through the CLI, from the compiled engine): "waht is the diffrence between bun and node for a web server" came back resolved as "What is the difference between Bun and Node for a web server?", titled "Bun vs Node for web servers", `quick`; "zrób research systemów personalizacji w food tech" was judged clear, Polish throughout, `deep` with a Polish reason; "personalizacja" and "co z tym AI" were vague and got two Polish questions with four options each.
- **Canary**, live, through the engine built into the app under review:

  ```
  PASS 4m10s $0.361775 build 5abce55 · en · status inconclusive · trust shaky · 2 cited · 2 snapshots · 6 claims checked · 0 markers stripped · ~/.quorum-canary/20261010-015842/questions/01M4HHNNDZ0XPBNYVPSRMA065G/runs/01M4HHNNDZ0Z5A5Q5T81N4W0RV
  PASS 4m22s $0.365070 build 5abce55 · pl · status inconclusive · trust shaky · 1 cited · 1 snapshots · 1 claims checked · 0 markers stripped · ~/.quorum-canary/20261010-020259/questions/01M4HHXFE5ZTXTHEPADW028HJT/runs/01M4HHXFE5CH2W3V9MJD9HA9JP
  ```

  Its `title` and `language` checks pass. An earlier `pl` canary on build `841e0d7` **failed** ("no claim was checked against a quote": one angle, one page fetched, nine quotes never declared, trust `unchecked`). The same question on a build of M6 (`2b7a29a`) then **failed on time** (297 s against 270 s) while its quotes were fine; a Polish GUI run on `5abce55` ended `unchecked` too. The three `pl` outcomes with the M7 engine are 1 fail, 1 pass, 1 unchecked, so a Haiku Polish research run with one angle is flaky, at M6 as well as now; nothing in M7 touches what an angle fetches or quotes. It is the same upstream flakiness M5's notes record for the canary on main.
- **The app, driven by keystrokes** (a build of this branch, `5abce55`, run from `/tmp` with its own bundle id and a throwaway brain folder `/tmp/m7-brain`, Draft effort, Haiku; see below for why it is not the installed one):
  1. A vague Polish question, "personalizacja", then Return. About 12 s later the scoper's two questions came back in Polish ([screenshot](screens/m7-clarifying-pl.png)). Pressing `1` and `W` picked options ([screenshot](screens/m7-clarifying-pl-picked.png)); Return sent the answers.
  2. The resolved-question card arrived with "Jak implementować personalizację w aplikacjach webowych z uwzględnieniem best practices?", Deep suggested with a one-line Polish reason ([screenshot](screens/m7-confirm-pl.png)). Tab flipped it to Quick; Return started the run.
  3. The sidebar row and the run header read **"Personalizacja w aplikacjach webowych"** ([screenshot](screens/m7-running-title-pl.png)); `question.json` says `title_source: "scope"`, `language: "pl"`, `original_text: "personalizacja"`; the run used 3 angles (Quick). The finished record passes `title` and `language`.
  4. A clear English question with typos, "waht is the diffrence between bun and node for a web server?", skipped the clarifying step and showed the card with the typos fixed ([screenshot](screens/m7-confirm-en-typo-fixed.png)). Return started it; the run is titled **"Bun vs Node.js for web servers"**, `title_source: "scope"`, `en`.
  5. `E` turned the resolved question into an editable field ([screenshot](screens/m7-edit-resolved.png)); Esc went back to the question as typed, with the tier kept.

The first build of the key handling did not work: `.focusable()` with `onKeyPress` never received the digits or Return. The screenshots above are from the build with the `NSEvent` monitor.

## Not verified

- **`scripts/install.sh` was not run.** Another thread's installed Quorum (M5, `~/Applications/Quorum.app`, brain folder `/tmp/m5-real`) was open and being driven; `install.sh` quits and replaces it. The build above is the same `make-app.sh` output, copied to `/tmp` with a different bundle id and executable name so it could run beside it (it was killed twice by that thread's `quit Quorum` before the rename). Run `scripts/install.sh --open` once that thread is done.
- **Esc during "Reading your question…"**, and **a late scope reply arriving after Esc**, are covered by the flow's tests and a token in the view, not driven. So are the free-text field in the clarifying card and "Research my original wording".
- **The engine failing to launch** during scoping (the confirm card's "couldn't check this question" banner) is unit-tested in the flow and in the engine's fallbacks, not shown on screen.
- **The scoper's latency.** 6 to 12 s measured, 15 to 28 s while a build or a canary was loading the machine. The UX proposal's 2 s target is not met and cannot be with a CLI cold start.
- **Haiku sometimes drifts out of the question's language inside an option** (one Portuguese option appeared in a Polish exchange before the prompt told it never to mix; not seen after).
- The planner, synthesis and validator calls still run unisolated, so they still load the user's CLAUDE.md and memory. Isolating them is a follow-up that moves the canary.
- The 450-pt default window puts the clarifying card's Continue button below the fold (the card scrolls). The restyle is M9.

## Review fixes

PR review found seven problems, all fixed test-first.

- **An uncommitted edit of the resolved question was dropped** when Start was clicked with the mouse, and the next card opened still in edit mode. The editing state (`editingResolved`, `resolvedDraft`) now lives in `ScopingFlow`; `confirm()` commits the draft, and `edit()`, `submit()` and `reset()` clear it. Editing works from the fallback card too.
- **A clarifier could become the question and the title.** A `resolved` that apologises or asks the user to clarify is replaced by the user's own words, and the title falls back to those words. `title_source` is `"scope"` whenever a brief is carried (it used to be guessed by comparing strings); `check` does not hold a title that is the user's own trimmed words to the clarifier rules.
- **Language.** `brief.language` is read off the user's words and only falls back to the model's code when those words show none; the agents are told the language of `asked`, not of the model's rewrite; `check` compares the brief's language with `asked`'s, so it can fire.
- **Clarification answers reach the agents.** The planner and the synthesis are given them, and a run started without a brief (the scoper failed after the user answered) still carries them as `clarifications` in the config.
- **The key monitor ignores every window but the composer's**, so Return in Settings cannot start a paid run.
- **Late replies.** Each `ScopeRequest` carries a ticket (not sent to the engine); `receive` and `fail` drop a reply whose ticket is not the pending one, and Esc clears it and terminates the in-flight scoper process.
- **A refused start no longer wipes the clarified brief**: `startRun` returns whether it started, and the flow resets only then.

Also: an empty title is treated as missing (`"???"` is titled "Untitled question", and a blank title in either file falls through to the next); the live title of a run started from "Research my original wording" is read from the stored record instead of the whole question; `doctor` fails a `claude` that does not know `--safe-mode` or `--no-session-persistence`; terminal hand-offs quote `'` in paths.

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

`run`'s stdin config gains `brief` (what the app got from `scope`, with the user's tier) and `tier`. The engine researches `brief.question`, titles the question `brief.title` (`title_source: "scope"`), tells every agent `brief.language` ("The language code is "pl""), and keeps the brief in `run.json`. With no brief (the canary, `--replay`, an engine that could not scope) it makes one from the question: `title_source: "question"`, Quick.

The "don't ask" paragraph, in the research, synthesis and planning prompts: *the scope is fixed and nobody is there to answer. Never ask the user a question, never ask for clarification, never offer options: state the assumption in one line and carry on.*

### Integrity checks

| Check | Fails when | Warns when |
|---|---|---|
| `title` | `question.title` is not `brief.title`; or the old guard (apology, clarifier, question back) trips on a scoped title | no `question.json` |
| `language` | `question.json`'s language is not `brief.language` | the title, or the answer, reads as another language than the brief's |

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

RESULTS

## Not verified

NOTVERIFIED

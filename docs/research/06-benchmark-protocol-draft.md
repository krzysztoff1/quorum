# Draft: fair benchmark protocol — Quorum vs Manus / ChatGPT Deep Research / Gemini Deep Research

Status: **draft for review, nothing here has been run.** Written 2026-10-09 alongside [`../competitive-landscape.md`](../competitive-landscape.md). The question list is a starting point; every question needs a human-verified answer key before any run.

## Goal and non-goals
- **Goal:** find out whether Quorum's *trust* (verifiable claims, calibrated confidence, explicit conflicts) and *answer shape* (short, readable) beat the incumbents on real food-tech business questions, at comparable effort and cost.
- **Non-goal:** a publishable leaderboard. With ~10 questions this is directional evidence, not statistical proof. Say so in any write-up.

## What the existing harness already does (and what it doesn't)
`Sources/Quorum/Benchmark.swift` already runs Quorum against a plain-Claude arm and against pre-written external reports (`--external <dir>`, `--reuse-quorum`), with binary rubric coverage, both-position judging, and a Claude + Codex judge panel where a "consensus winner" needs every judgment to agree. Gaps for *this* protocol:
1. **Judges include Claude.** The first external run (Quorum vs ChatGPT DR, 4–0) was already caveated as Claude-judges-Claude. For this benchmark the content judges must be non-Claude (see Judges).
2. **No claim-support audit.** Rubric coverage measures whether answers *mention* things, not whether their cited claims are *supported*. The competitor evidence says this is the axis that matters (DeepTRACE: 12.5%–97.5% unsupported statements across tools).
3. **Default questions are not food-tech** (PFAS etc.).
4. **No presentation scoring** — presentation is judged on rendered output, which text-only judging discards.

## Systems under test
| Arm | System | Setting |
|---|---|---|
| A | Quorum **Quick** and **Deep** | Claude subscription, default tiers |
| B | ChatGPT Deep Research | highest tier the owner already pays for; plan not edited (accept the default plan) |
| C | Gemini Deep Research | same; note whether Pro or Ultra (visual reports are Ultra-only) |
| D | Manus | Wide Research for list questions; standard research mode otherwise |
| E (recommended add) | Perplexity Deep Research with **Check Sources** | it ships the closest claim-checking feature; excluding it would hide the most relevant competitor |
| F (control) | Plain Claude Research | architecture control: does Quorum beat the platform it runs on? |

Record for every run: product version/model label, date, plan tier, wall-clock time, credits/usage consumed, whether the answer arrived as text, document, or UI.

## Equal-ish budget
Consumer products cannot be capped, so "equal budget" is defined by **cost ceiling and effort setting**, not tokens:
- Use each product's **default / highest standard research mode** — no hand-tuned prompting for any arm. Same prompt text for all (copy-paste), no follow-ups.
- Log cost in comparable units: Quorum — tokens/usage from its ledger (it runs on subscription, so also compute the API-equivalent); Manus — credits consumed; ChatGPT/Gemini — usage-limit fraction consumed, plus API-equivalent estimates (Gemini documents ~$1–3/task DR, ~$3–7 Max; o3-deep-research ≈ $1.5/task estimated). Quote these as estimates.
- Report **quality per cost and per minute** next to quality; do not hide that Quorum Deep may spend more or less than a competitor's default run.
- Optional **Arm 2 (API-matched):** run the same questions through the Gemini and OpenAI deep-research APIs with a fixed ~$5/task cap to remove subscription-tier noise; skip if effort is tight.
- Run each question **twice per arm** (Manus and Kimi reviews report run-to-run inconsistency) and report the spread.

## Questions (~10, frozen before any run)
Cover six types, 1–2 each. These are *drafts*; the owner replaces them with questions they actually need answered, and writes the answer key.
1. **Market sizing with conflicting sources** — e.g. size and growth of workplace/corporate food-ordering in the EU or Poland; sources are known to disagree, so scoring includes whether the conflict is surfaced rather than averaged away.
2. **Competitor/pricing comparison** — e.g. which corporate lunch-ordering / meal-benefit platforms operate in Poland, with commission and pricing model.
3. **Regulation/compliance** — e.g. obligations for allergen information on app-delivered meals in Poland/EU; answer must cite primary law.
4. **Contested evidence** — e.g. ghost-kitchen unit economics (profitable or not); tests one-sidedness.
5. **Wide / list** — e.g. 30–40 EU workplace-food startups with HQ, model, funding stage, latest round, each with a source (Manus's home turf; tests per-cell verification).
6. **Trap** — a **false premise** (e.g. "why did <company that is still operating> shut down?") and a **fresh-fact** question where the correct answer changed in the last 90 days. Verify the premise/answer first.

## Gold standard (built before runs, by a human)
For each question the owner writes: (a) a **coverage checklist** of 8–15 binary items (as the harness already does, but domain-curated), (b) **3–5 anchor facts** with primary-source URLs (numbers, dates, legal citations), (c) known **traps** (stale figure, false premise, conflicting-source pair). Freeze and commit the answer key before running anything.

## Blinding and normalisation
- **Content track:** convert each output to plain Markdown, strip product names, logos, UI chrome and any "Deep Research"/"Manus" boilerplate, keep citations/links intact. Randomise arm order and swap positions (harness already does both orders).
- **Presentation track:** judged separately on screenshots of the native rendered output, *not* blind (UI identifies the product). Do not mix presentation into the content score.
- Caveat to state: stylistic fingerprints survive normalisation; it is blinding in effort, not in guarantee.

## Judges
- **No Claude judge on the content track.** Panel = one OpenAI-family judge + one Gemini-family judge + (if available) one open-weights judge from a third lab.
- **Self-preference control:** drop each judge's own vendor's system from *that judge's* ballots (the GPT judge doesn't score ChatGPT DR; the Gemini judge doesn't score Gemini DR) and report per-judge results. Quorum runs on Claude, so no judge on the panel shares its family.
- A winner is recorded only if both position orders agree (existing rule); disagreement = tie.
- **Human spot-check:** the owner re-grades a random 30% of coverage items and all claim-support audit disagreements; report judge–human agreement. If agreement is poor, discard LLM-judge results rather than average them.

## Rubric (content track) — weights are proposals
| # | Dimension | How scored | Weight |
|---|---|---|---|
| 1 | **Claim support** | mechanical audit (below): % of atomic claims supported by their cited source | 30% |
| 2 | **Correctness vs answer key** | anchor facts right/wrong/missing; traps caught | 20% |
| 3 | **Coverage** | binary checklist items hit | 15% |
| 4 | **Conflict & uncertainty handling** | conflicting sources surfaced with both sides; stated uncertainty matches evidence (see calibration) | 15% |
| 5 | **Decision usefulness / concision** | answer-first? would a founder act on it? penalise length not backed by content | 10% |
| 6 | **Verifiability** | median seconds for a human to verify a sampled claim (below) | 10% |

## Mechanical trust metrics (not LLM-opinion)
Run on every output, with the same extractor and verifier for all arms:
1. **Atomic-claim extraction** — split each output into claims; keep claims that carry a citation, and separately count *uncited* factual claims.
2. **URL health** — % of cited URLs that resolve (HTTP 200 and non-error content). Prior work found 5–18% non-resolving across commercial systems (arXiv 2604.03173).
3. **Quote presence** — for systems that give quotes: % of quotes found verbatim in the fetched page. Competitors without quotes score N/A, not zero; report separately.
4. **Support rate** — fetch each cited page; a verifier (non-Claude LLM given only the claim + page text) labels supported / partial / unsupported / contradicted. **Human audit of 20% of labels**, all of them for the Wide table. Report unsupported-statement rate in the same form as DeepTRACE for comparability.
5. **Calibration (arms with confidence only: Quorum; Perplexity Check Sources if it emits a score):** bucket claims by stated confidence; report the support/correctness rate per bucket. Parallel's Basis API reports this shape (High 85.9–97.5% correct, Low 36–65%, vendor test) so there is a reference. Arms without confidence are scored on dimension 4 only.
6. **Time-to-verify** — a human is handed 5 random claims per output, timed to confirm/refute using only the output's own citations/UI. Report median seconds. This is where click-through quote verification should show up, if it works.
7. **Conflict recall** — on questions seeded with a known source conflict, did the output present both values and sources?

## Presentation track (human, not blind)
Three raters (owner + two others), 1–5 on: scannability in 30 s, whether the visual encodes the claim (vs decoration), whether evidence is reachable in ≤2 clicks, trust signals legible without reading prose. Store screenshots in `docs/research/benchmark-runs/<date>/`. Do not credit chart count.

## Wide question handling
Score the table per cell: cell correct (vs answer key sample of ≥15 rows), cell cited, cited source supports cell. Row completeness. Manus's own docs say quality degrades for small lists and tested only up to 250 items; use ≥30 rows so the test is fair to it.

## Analysis
- Report per-arm means with bootstrap 95% CIs over questions×runs; pairwise blind win-rates per judge; the mechanical trust metrics as the headline.
- Pre-register: decision rule "Quorum claims a trust advantage only if its unsupported-statement rate is lower than every competitor's and the human-audited support rate agrees". Otherwise report the null.
- Publish raw outputs and the answer key with the results so others can re-grade.

## Threats to validity (write these into the report)
- n≈10 questions; domain = food-tech business; results don't generalise to academic questions (Elicit/Consensus home turf).
- Product versions change weekly; stamp dates. ChatGPT/Gemini limits may force runs across several days.
- The verifier LLM can be wrong; hence human audit. Source pages can change or be paywalled between run and audit — snapshot every cited page at run time.
- The owner built Quorum and writes the answer key; mitigate by having someone else write ≥half the checklist, or freeze the key before seeing any outputs.
- Manus/Gemini UI differences (document vs chat vs sheet) make "same output" conversion lossy.

## Cost estimate (rough)
Quorum's last internal 4-question run cost ≈ $42 at the $10/angle config (from the project's own notes), ~13 min per question; ChatGPT/Gemini/Perplexity are subscription-metered; Manus burns credits (third-party reports 4k–10k credits per heavy run — verify on a pilot). Pilot with 2 questions × 1 run per arm before committing to the full ~10×2.

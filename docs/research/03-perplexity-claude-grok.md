# Raw notes: Perplexity, Claude Research, Grok DeepSearch

Compiled 2026-10-09 by a research subagent. Perplexity's own hub/changelog/pricing returned 403/404 to the fetcher; Perplexity claims come from trade-press rewrites or the releasebot changelog mirror (one entry set re-fetched by the author ✔). Several 2026 "comparison" blogs (Suprmind, Talkory, aiunpacker) look like marketing and were excluded. Tags: **[V]** vendor, **[I]** independent.

## Perplexity
- **Deep Research** upgrade ~Feb 4–5, 2026: claims Opus 4.5 in same harness; 79.5% on DeepSearchQA; open-sourced DRACO benchmark (self-authored, Perplexity leads — treat as marketing) [V, via] https://analyticsindiamag.com/ai-news/perplexity-releases-advanced-deep-research-upgrade-open-sources-draco-benchmark
- **Model Council** (Feb 5–6, 2026): one query → three frontier models in parallel → synthesiser flags agreement/contradiction. Max-only ($200/mo). Disagreement is model-level, not claim-level. [V-rewrite] https://www.resultsense.com/news/2026-02-10-perplexity-launches-model-council-multi-model-research/
- **Labs** (May 29, 2025): 10+ min runs, code execution, charts, reports/spreadsheets/dashboards/mini web apps; Assets + App tabs [V-rewrite] https://techcrunch.com/2025/05/29/perplexitys-new-tool-can-generate-spreadsheets-dashboards-and-more/
- **Computer** (Feb 25, 2026): ~19 models, parallel sub-agents in sandboxes; Max $200/mo, 10k credits; ~$500M annualised revenue [I] https://sacra.com/research/perplexity-computer-vs-claude-cowork/
- **2026 changelog entries ✔** (releasebot mirror of Perplexity's changelog) https://releasebot.io/updates/perplexity-ai :
  - Mar 13: finance answers get "a traceability layer, letting you audit information back to its original sources" (live in Deep Research).
  - May 29: context panel with live progress/artifacts/credits; "traceable claims for financial data".
  - Jun 19: Deep Research moves inside Computer (reports, spreadsheets, decks).
  - **Jul 27: "Check Sources" — "verifies claims against the underlying evidence" and summarises how well an answer is supported; Source Context Panel keeps citations beside the response.**
  - Oct 5: inline interactive charts and 3D visualisations in Computer threads.
- Architecture: agent loop (search/read/reason); no public detail on parallel subagents for Deep Research.
- Output: reviewers call it fastest with cleanest citations but shallower, ~10-page reports [I] https://echai.ventures/how-founders-use-ai/search-research/which-ai-research-tool-should-i-actually-use-chatgpt-claude-gemini-perplexity-or-grok ; https://www.aryabhconsulting.com/blog/deep-research-ai-tools-comparison-2025-gemini-vs-chatgpt-vs-perplexity-for-business-research
- Price: Pro $20/mo; 2026 DR cap unverified (sources range ~20/day to ~20/mo) https://www.usecarly.com/blog/perplexity-limits/ (low quality).
- Data: cloud; consumer chats train by default with opt-out; opt-out not retroactive [I] https://joindeleteme.com/ai-privacy-settings/perplexity-ai-opt-out-data-training-guide/
- **Independent:** DeepTRACE (Aug 2025): Perplexity DR 58.0% citation accuracy, 97.5% unsupported statements, 63.1% one-sided on debate queries ✔ https://arxiv.org/html/2509.04499 ; Tow Center (Mar 2025): wrong on 37% (best of eight tested) https://www.cjr.org/tow_center/we-compared-eight-ai-search-engines-theyre-all-bad-at-citing-news.php ; Hyperresearch DRACO rerun (10 tasks, one judge) 57.8 https://hyperresearch.ai/benchmarks/draco (not fetched).

## Claude Research (Anthropic)
- Lead agent (Opus 4 in eval) plans and spawns 3–5 parallel subagents (Sonnet 4), each running 3+ tools in parallel; separate CitationAgent attributes claims at the end. +90.2% vs single-agent Opus 4 on internal eval; ~15× chat tokens. Own failure modes: prefers SEO content farms, chases nonexistent sources, duplicated work. No adversarial validators described. [V] https://www.anthropic.com/engineering/multi-agent-research-system (2025-06-13)
- Research launched Apr 2025, later up to 45 min [I] https://analyticsindiamag.com/ai-news-updates/anthropic-releases-new-research-feature-for-claude ; checkable citations [V] https://claude.com/blog/research
- **Citations API:** returns `cited_text` + char/page/block location; pointers "guaranteed valid" because parsed, not model-written [V] https://platform.claude.com/docs/en/build-with-claude/citations — proves the pointer exists, not that the passage supports the claim. Whether claude.ai Research UI uses it / highlights passages beside prose: **unconfirmed**.
- **Inline interactive visuals** (Mar 12, 2026; HTML/SVG; all plans; Cowork Apr 22) [V] https://claude.com/resources/articles/claude-builds-visuals ; [I] https://thenewstack.io/anthropics-claude-interactive-visualizations/ . Artifacts on every plan (Sep 16, 2026) [V] https://support.claude.com/en/articles/12138966-release-notes
- **Claude Science** (Jun 30, 2026, beta): orchestrator + specialised subagents; reviewer agents flag "incorrect citations, untraceable numbers, and figures that don't match their underlying code"; provenance trail [V] https://www.anthropic.com/news/claude-science-ai-workbench . The one Anthropic product with validators; science vertical only.
- Managed Agents "outcomes" (May 2026): second-agent quality gate, developer API https://9to5mac.com/2026/05/07/anthropic-updates-claude-managed-agents-with-three-new-features/
- Cowork research preview (macOS desktop; Max Jan 12, Pro Jan 16, 2026; computer use Mar 23); pricing page now says "Claude Cowork is now just Claude" [V] release notes above.
- Price: Free no Research; Pro $17/mo annual ($20 monthly); Max from $100; rolling 5-hour + weekly caps shared with Claude Code; Research "can use them up faster" [V] https://claude.com/pricing ; https://support.claude.com/en/articles/11088861-using-research-on-claude
- Data: Research is cloud-run; consumer chats used for training unless opted out (Aug 2025 policy; sources disagree on opt-in/out); retention up to 5 yrs if allowed else 30 days [I] https://www.bitdefender.com/en-au/blog/hotforsecurity/anthropic-shifts-privacy-stance-lets-users-share-data-for-ai-training
- Independent: no rigorous audit of Claude Research citation accuracy found. URL study tested Claude search models, not Research: 3.0–3.2% hallucinated URLs, 7.8–8.5% non-resolving https://arxiv.org/html/2604.03173v1

## Grok DeepSearch / DeeperSearch (xAI)
- DeepSearch launched with Grok 3 (Feb 2025): "synthesizes key information and reasons about conflicting facts" [V] https://x.ai/news/grok-3 . No primary doc for DeeperSearch; may be legacy naming.
- 2026 models Grok 4.20 (beta Feb 17) → 4.7; API `grok-4.20-multi-agent-0309`; $2/$6 per 1M (4.7) [V] https://docs.x.ai/docs/models . Agent roster (Harper/Benjamin/Lucas, Heavy = 16 agents) and "65% fewer hallucinations" are third-party only, unverified https://www.verdent.ai/guides/grok-4-20-multi-agent-system
- Distinctive source: X posts via `web_search`/`x_search` tools; API returns source URLs automatically [V] https://docs.x.ai/docs/guides/tools/overview . UI reportedly doesn't clearly separate X vs web citations (unverified) https://www.buildfastwithai.com/ai-tools/grok-deepsearch
- Price: third-party only (SuperGrok Lite $10 / $30 / $100 / Heavy $300) — unverified https://geotoolbox.ai/blog/grok-pricing
- Data: cloud; trains on conversations by default with opt-out [I] https://joindeleteme.com/ai-privacy-settings/grok-privacy-settings-guide/
- Independent: Tow Center Mar 2025 Grok 3 wrong on 94% (worst), 154/200 links to error pages — stale. No audit of Grok 4.x DeepSearch found.

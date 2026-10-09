# Raw notes: Manus, Wide-Research peers, open-source and local entrants

Compiled 2026-10-09 by a research subagent; spot-checked claims are marked ✔ (re-fetched by the author). Tags: **[V]** vendor claim, **[I]** independent/third-party. Pricing mostly comes from third-party blogs (Manus's own pricing page was not retrievable) and conflicts across sources.

## Manus

**Wide Research architecture**
- Main agent splits the request; each item gets its own agent with a clean context window, its own VM, tools and internet. Sub-agents do not talk to each other; the main agent merges results. [V] https://manus.im/features/wide-research
- "Hundreds of independent agents in parallel", no exact number. Tested up to 250 items. Not recommended for fewer than 10 items or sequentially dependent tasks. ✔ [V] https://manus.im/docs/features/wide-research
- The docs page says **nothing** about citations, sources, verification or fact-checking, and does not say which plans include Wide Research. ✔
- Per-agent model not stated. SiliconANGLE: Manus runs on third-party models incl. Anthropic's [I] https://siliconangle.com/2026/04/27/china-blocks-metas-acquisition-ai-agent-developer-manus/. Wikipedia: no foundation model of its own [I] https://en.wikipedia.org/wiki/Manus_(AI_agent). Latest stable listed: 1.6 (Dec 15, 2025); free tier runs "1.6 Lite" [I] https://www.usecarly.com/blog/manus-ai-review/ (Carly is a competitor).
- Claims "uniform quality at any scale"; publishes no benchmarks (VentureBeat noted the same at launch) [I] https://venturebeat.com/business/youve-heard-of-ai-deep-research-tools-now-manus-is-launching-wide-research-that-spins-up-100-agents-to-scour-the-web-for-you
- Manus's own blog (per a secondary summary): quality degrades past ~5 items in a single context and later items can be fabricated — the motivation for per-item agents [V] https://manus.im/blog/manus-wide-research-solve-context-problem

**Output shape**
- Sortable/filterable spreadsheets, reports, datasets, visualizations, images. Examples: 250 AI-researcher profiles, 100-sneaker matrix. [V] https://manus.im/docs/features/wide-research
- Elsewhere: slides, websites, apps; "Cloud Computer" on the top tier [I] https://www.firecrawl.dev/blog/best-ai-for-research
- No screenshot of a Wide Research table found; docs offer replay links only.

**Verification:** none documented. "Verification" = sub-agent isolation limits context pollution [V]. Firecrawl lists Manus citation checking as "not specified" [I] https://www.firecrawl.dev/blog/best-ai-for-research

**Pricing (third-party; unreliable)** [I] https://wf.lindy.ai/blog/manus-ai-pricing, https://www.usecarly.com/blog/manus-ai-review/
- Free: 1,000 credits + 300 daily. Paid $20/$40/$200 per month for 4k/8k/40k credits. Team $20/seat pooled. Annual −17%. Credits don't roll over. Add-on packs ≈2× plan rate. Cannot estimate a task's cost in advance.
- Reported burn: 4,000–10,000 credits per run; looping/failed tasks still bill [I] https://www.nocode.mba/articles/manus-ai-pricing

**Reliability reports [I, small blogs]:** same prompt → conflicting facts across runs; announces completion with little evidence https://future-stack-reviews.com/manus-ai-review-2026/ ; several reviewers advise against critical workflows https://www.layer3labs.io/guides/manus-ai-review

**Local/cloud/data:** cloud only; SOC 2 and no-training claims relayed via https://www.usecarly.com/blog/manus-ai-review/ (training opt-out listed as Team feature). Aug 2026 data-deletion notice for data created since Dec 29, 2025 (regulatory) — same source.

**Meta saga:** Meta announced ~$2B deal Dec 29–30, 2025 https://www.cnbc.com/2025/12/30/meta-acquires-singapore-ai-agent-firm-manus-china-butterfly-effect-monicai.html ; some customers left https://www.cnbc.com/2026/01/21/metas-2b-manus-deal-pushes-away-some-customers-sad-it-happened.html ; China NDRC blocked it Apr 27, 2026 https://techcrunch.com/2026/04/27/china-vetoes-metas-2b-manus-deal-after-months-long-probe/ ; Meta cut ties Jun 15; Manus independent again Aug 11 (Wikipedia). Effect on users: unverified; no churn data.

## Wide-Research peers

**Kimi Agent Swarm (Moonshot)** — up to 300 parallel sub-agents, 4,000+ tool calls; Word/PDF/MD/PPT/charts/tables; no verification step described; swarm from the $19/mo plan at several × credit rate. [V] https://www.kimi.com/en/help/agent/agent-swarm ; review [I]: over-allocates agents, 2 of 8 batch articles needed rewrite, confidently wrong figures https://www.mayhemcode.com/2026/08/kimi-agent-swarm-review-features.html

**Perplexity Computer** (Feb 25, 2026) — ~19 models, parallel sub-agents, cloud sandbox; docs/slides/micro-apps; Max $200/mo https://eesel.ai/blog/perplexity-computer (competitor-authored), https://sacra.com/research/perplexity-computer-vs-claude-cowork/ . **Model Council** (Feb 2026): 3 models + synthesizer table of agreements/differences; no per-citation checking https://designcompass.org/en/2026/02/11/perplexity-model-council-synthesizing-responses-from-multiple-ais/

**Genspark / Skywork / MiniMax** — parallel agents; pricing unclear; Genspark Trustpilot 1.7★ citing billing disputes [I] https://fast.io/resources/genspark-ai-review-2026/ ; Skywork DR agent v2 27.8% BrowseComp (38.7% parallel) [V, Aug 2025] https://www.techwalls.com/skywork-deep-research-agent-v2/ ; MiniMax pricing unconfirmed.

## Open-source / APIs
- **GPT-Researcher** (Apache-2.0): planner → parallel execution agents (one per question) → publisher; PDF/Word/MD; no verification step; ~$0.40/task self-reported; BYO keys. https://github.com/assafelovic/gpt-researcher ; https://www.digitalapplied.com/blog/open-source-deep-research-agents-2026-guide
- **LangChain Open Deep Research** (MIT): #6 on DeepResearch Bench (RACE 0.4344); **repo archived Aug 21, 2026**. https://github.com/langchain-ai/open_deep_research
- **Stanford STORM**: outline → cited article; last push Sep 2025.
- **Tongyi DeepResearch** (Apache-2.0): 30.5B/3.3B-active model; BrowseComp 43.4 at launch; quiet since Sep 2025. https://github.com/Alibaba-NLP/DeepResearch
- **You.com ARI** retired; sells usage-billed Research API. https://resources.rework.com/tools/ai-agents/best-ai-research-agents-2026
- **Parallel Task API** — every output field carries citations, excerpts, reasoning and a low/med/high confidence label; vendor test: High-confidence 85.9–97.5% correct, Low 36–65% (May 2025). Ultra ≈ $0.30/task; 92% on a 100-question BrowseComp subset [V]. https://www.parallel.ai/blog/introducing-basis-with-calibrated-confidences ; https://parallel.ai/benchmarks.md . Closest shipped analogue to per-claim confidence + excerpts; cloud API, no UI, no conflict view.
- **Exa / Tavily / Firecrawl** — search/research APIs; no claim-verification layer; Firecrawl deprecated its deep-research API. https://www.firecrawl.dev/blog/best-deep-research-apis
- **Scite** — 1.6B+ citation statements classified supporting/contrasting/mentioning; scholarly only. **Elicit** — see 04 notes.

## Local / own-subscription neighbours (Quorum's closest analogues)
- **comu365/claude-deep-research** (Claude Code skill): Sonnet researchers must give a verbatim quote from a page they opened; writer drafts from notes only; Opus fact-checker re-opens every source and grades supported/partial/unsupported; conflicts shown side by side. 1 commit, 0 stars. https://github.com/comu365/claude-deep-research
- **Socialpranker/deepdive** — 12-phase pipeline, claims ledger with dissent protection, red team, four-layer citation verification (snippet read only). https://github.com/Socialpranker/deepdive
- Others (snippets only): HadiFrt20/deepresearch, jamoeight/claude-code-deep-research-v2. **Local Deep Research** (Ollama/SearXNG) claims ~95% SimpleQA, self-reported.
- **Claude Cowork** — local macOS desktop agent on the user's plan (Jan 2026; GA Apr 9) https://www.infoq.com/news/2026/01/claude-cowork ; no research-citation features found.
- No native macOS app found combining multi-agent research + citations + BYO subscription/key.

## Verification-gap evidence
- Deep-research agents produce more citations but hallucinate URLs at higher rates than search-augmented LLMs; `urlhealth` cut non-resolving URLs 6–79× to <1% https://arxiv.org/abs/2604.03173
- Feb 2026 position paper: claim-level auditability is the bottleneck (no experiments) https://www.alphaxiv.org/abs/2602.13855
- Secondary claim (unverified): 14-LLM benchmark, links resolve >94% but claim support 39–77% https://www.newscatcherapi.com/blog-posts/best-deep-research-tools

## Unverified
NotebookLM passage-level behaviour (see 05), Genspark/MiniMax/Skywork pricing, per-plan Wide Research availability, any neutral per-claim verification rate for any of these.

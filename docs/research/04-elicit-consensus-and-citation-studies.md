# Raw notes: Elicit, Consensus, scholarly tools, and independent citation-accuracy studies

Compiled 2026-10-09 by a research subagent; DeepTRACE table re-fetched by the author ✔. Tags: **[V]** vendor, **[I]** independent. Aggregator sites (costbench etc.) are not authoritative.

## Elicit
- **Research Agent** (beta Dec 9, 2025): decomposes prompt into a "systematic program", clarifying questions first, then search/evaluate/synthesise loop; templates incl. competitive landscapes [V] https://elicit.com/blog/introducing-research-agent-workflows . **Aug 4, 2026 relaunch**: "proprietary harness with process verification", "investigates multiple angles, compares conflicting findings" — single vs multi-agent not stated [V] https://elicit.com/blog/introducing-elicit-research-agent
- Sources: 138M+ papers, Library, web, ClinicalTrials.gov, FDA/EMA, press releases, up to 20 uploads; effort levels Fastest→Smartest (limited beta) [V] https://support.elicit.com/en/articles/11241729 . **Reports and Systematic Review are academic-corpus only** [V] https://support.elicit.com/en/articles/14756886
- Systematic review pipeline (PRISMA 2020, May 6, 2026): every extracted value "one click away from supporting quotes, tables, or figures"; every screening decision stores a reason + quote; searches logged [V] https://elicit.com/blog/systematic-review-for-prisma-2020
- Agent output: "sentence-level citations" [V]; no documented deterministic quote-existence check. Quote-level evidence is documented for review/extraction, not agent output.
- 2026 launches: API (Mar 3), API+MCP (Jul 15), Routines (Sep 30), shared Library/Projects [V] https://elicit.com/blog
- **Vendor accuracy (May 6, 2026):** 95% recall, 97% abstract screening, 99% full-text screening, 96% extraction over 994 Cochrane reviews. Caveats in their own post: 769 answers/198 open-access studies scored; questions reconstructed by an LLM; LLM graded; humans checked 42 answers; medical only [V] https://elicit.com/blog/evaluating-elicit-slr
- **Independent:**
  - Lagisz et al., *Research Synthesis Methods*, May 29, 2026 (7 ecology/environment reviews): ~87% accuracy; tuned prompts generalised worse (69% of variables kept ≥87%); ~90% values matched across two accounts but supporting quotes matched only 46%, reasoning 30%; high-accuracy mode values 77%, quotes 10%; "complement, not replace" humans. https://www.cambridge.org/core/journals/research-synthesis-methods/article/using-elicit-ai-research-assistant-for-data-extraction-in-systematic-reviews-a-feasibility-study-across-environmental-and-life-sciences/C97DAEC70C3173A260F0B12E729E7250
  - Hilkenmeier et al., Sage 2025: 81.4% vs 86.7% human, n.s. https://journals.sagepub.com/doi/10.1177/08944393251404052
  - Lau & Golder 2025: search sensitivity ~37.9% under real SR strategies (secondhand) https://perplexityaimagazine.com/ai-tools/elicit-ai-review-2026/
  - Elicit Reports eval 2025 [V]: 17 PhDs rated 7.3/10, claimed to beat ChatGPT/Perplexity/Gemini DR; competitor scores unverified https://blog.elicit.com/elicit-reports-eval
- Output: extraction tables (20 cols Pro / 30 Scale), reports, figures, PPT (preview), .bib/.ris, PRISMA PDF/Word https://elicit.com/pricing
- Pricing (Sep 30, 2026 page) [V] https://elicit.com/pricing : Basic free; Pro $49/user/mo ($588/yr); Scale $169/user/mo; Enterprise custom ("no training on your data by default"). Cloud only. Speed: no published latency.

## Consensus
- Index ~200M papers (OpenAlex + Semantic Scholar); hybrid retrieval, rerank top ~1,500; paywalled papers mostly abstract-only; Scholar Agent built with OpenAI [I] https://aarontay.substack.com/p/a-2025-deep-dive-of-consensus-promises (Nov 2025)
- Deep Search: no clarifying questions, <10 min, PRISMA-like flow diagram, claims-and-evidence table, timeline, research gaps. Summer '26: agent workspace with full step trace; 400M+ sources [V] https://consensus.app/home/blog/what-has-changed-in-consensus-summer-26/ . Sep–Oct 2026: figures/tables from cited papers https://consensus.app/home/blog/see-the-figures-behind-your-answer/ ; Research Gaps Matrix https://consensus.app/home/blog/introducing-new-research-gaps-matrix/ ; "Consensus Everywhere" in ChatGPT/Claude/Copilot https://consensus.app/home/blog/consensus-everywhere/ ; Skills (Oct 5) https://consensus.app/home/blog/introducing-skills/
- **Citation Grounding** (Aug 2026): each citation shows exact supporting quote + section header on hover; click jumps to passage, highlighted in PDF when available [V] https://consensus.app/home/workshops/citation-grounding/ . No published accuracy; no independent evaluation found.
- **Consensus Meter:** Yes/No/Possibly/Mixed over ~top 20 papers; ~10% misclassification (vendor) https://consensus.app/home/blog/consensus-meter/ ; critique: vote-counting ignoring sample size/effect size/bias; LLM-generated study-design labels [I] Tay (above). Remaining failure mode: source faithfulness (real paper, misread). Repeat runs rank slightly differently.
- Pricing (aggregators, unverified): Free ~3 Deep Searches/mo; Pro ~$10 (~15); Deep ~$45→$65 (Sep 2, 2026 reported) https://costbench.com/changelog/consensus-price-increase-2026-09/ . Cloud only; data policy unverified.

## Others
Scite (1.2B+ citation statements; Reference Check; no independent accuracy study) https://libguides.mcmaster.ca/ai-tools-for-research/assistant-by-scite · Undermind (adaptive search, ~150 results evaluated) · Google Scholar Labs (experimental) https://www.techbuzz.ai/articles/google-scholar-labs-uses-ai-to-find-studies-but-ditches-citations · OpenEvidence (medical; reference-existence checked, support not; 34–41% on complex cases in preprint) https://pubmed.ncbi.nlm.nih.gov/42686938/ · Ai2 Asta (June 2026: retrieved/cited docs often mismatch) https://arxiv.org/abs/2606.08301

## Independent citation / claim accuracy studies
- **DeepTRACE** (ICLR 2026; 303 queries: 168 debate, 135 expertise; LLM judge validated against humans) ✔ https://arxiv.org/html/2509.04499v1 — Table 1 (Aug 27, 2025):

| System | One-sided % (debate) | Overconfident % | Unsupported statements % | Citation accuracy % |
|---|---|---|---|---|
| GPT-5 Deep Research | 54.7 | 15.2 | 12.5 | 79.1 |
| Gemini Deep Research | 80.1 | 11.2 | 53.6 | 50.3 (prose says 40.3) |
| Perplexity Deep Research | 63.1 | 5.6 | 97.5 | 58.0 |
| Copilot Think Deeper | 94.8 | 0.0 | 90.2 | 62.1 |
| YouChat Deep Research | 63.1 | 19.6 | 74.6 | 72.3 |

- **Tow Center / CJR** Mar 2025 (8 AI search engines, 1,600 queries): >60% wrong attributing excerpts; Perplexity 37% wrong, Grok-3 94%; premium tiers more confidently wrong. Search, not DR; no 2026 update found. https://www.cjr.org/tow_center/we-compared-eight-ai-search-engines-theyre-all-bad-at-citing-news.php
- **URL hallucination** (arXiv 2604.03173, Apr 2026; 53,090 URLs): 5–18% non-resolving, 3–13% no Wayback record; Business lowest non-resolving (5.4%); self-correction tool cut 6–79× to <1% https://arxiv.org/abs/2604.03173
- **DeepResearch Bench (RACE/FACT)**: Gemini DR averaged 111.21 effective citations/report; exact citation-accuracy percentages not confirmed https://arxiv.org/abs/2506.11763
- **DRACO** (Perplexity + Harvard, 2026; Perplexity co-authored → biased): Perplexity 70.5, Gemini 59.0, o3 52.1, o4-mini 41.9 https://arxiv.org/abs/2602.11685
- **ResearchRubrics** (Scale AI): Gemini DR 0.677, OpenAI 0.664, Perplexity 0.566; none above ~68% https://www.emergentmind.com/papers/2511.07685
- **DeepFact** (Apr 2026): unassisted PhD experts only 60.8% accurate verifying claims in DR reports; audit-then-score method reached 90.9% after four rounds https://arxiv.org/abs/2603.05912 (supports a separate validator pass)
- 2026 orthopaedics study: Perplexity worst on reference reliability among ChatGPT/Gemini/Perplexity https://pubmed.ncbi.nlm.nih.gov/42558550/
- **Gaps:** no independent 2026 head-to-head across OpenAI/Gemini/Perplexity/Claude/Manus; no independent Manus evaluation.

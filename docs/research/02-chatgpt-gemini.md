# Raw notes: ChatGPT Deep Research and Gemini Deep Research

Compiled 2026-10-09 by a research subagent. OpenAI help-center, launch post and release notes returned HTTP 403, so most OpenAI facts are from secondary coverage. No screenshots were retrievable. Tags: **[V]** vendor, **[I]** independent.

## ChatGPT Deep Research
- Launched Feb 3, 2025 on a specialised o3; GPT-5.2-based since Feb 2026 [I] https://en.wikipedia.org/wiki/ChatGPT_Deep_Research
- **Feb 10–11, 2026 update:** editable research plan before run; progress tracking, mid-run redirect and added sources; site-restricted research; connected apps as sources; full-screen report viewer (TOC left, expandable citations right); export to Markdown/Word/PDF; Plus/Pro first. [I, relaying OpenAI] https://www.macrumors.com/2026/02/11/chatgpt-deep-research-mode-document-viewer/ ; https://www.androidheadlines.com/2026/02/chatgpt-deep-research-full-screen-document-viewer-update.html . MCP connections added (Wikipedia).
- Architecture: browsing agent, ~5–30 min, analyses text/images/PDFs. **Single vs multi-agent/parallelism: no primary source (unverified).** Agent mode merged Operator + Deep Research (Jul 2025); 68.9% BrowseComp [V, via search summary of https://openai.com/index/introducing-chatgpt-agent/ — not fetchable].
- Citations: inline links + source list. No per-claim confidence, no quote-level highlighting, no self-check step found. OpenAI itself says it may make factual errors, cite rumours, and not convey uncertainty accurately (launch caveats, via Wikipedia).
- Output: long text report + tables ("very long block of text unless the prompt specified format" — 2025 tester https://www.sectionai.com/blog/chatgpt-vs-gemini-deep-research). Native charts in reports: unverified.
- Limits: 2025 figures Plus/Team/Ent 25/mo, Pro 250, Free 5 light. 2026 per-tier numbers conflict across third parties (unverified) https://ai.zenken.co.jp/en/post/chatgpt-usage/
- API: `o3-deep-research` $10 in / $2.50 cached / $40 out per 1M tokens, 200k ctx; only snapshot 2025-06-26; tools web_search, code_interpreter, mcp [V] https://developers.openai.com/api/docs/models/o3-deep-research ; `o4-mini-deep-research` $2/$8 [V]. Est. ≈$1.45/task (o3) [I] https://tokencost.app/blog/gemini-deep-research-agent-cost . API still 2025 models, not GPT-5.2.
- Cloud only; training governed by account "Improve the model" toggle [V] https://help.openai.com/en/articles/7730893-chatgpt-data-controls . DR-specific retention: unverified.
- **GPT-6 "Intelligent UI" (Oct 7–8, 2026):** chat answers built from a fixed library of pre-built streamable components (interactive charts, editable graphs, maps, calculators); users can dial visuals down [I] https://techbriefly.com/2026/10/08/openai-chatgpt-gpt-6-interactive-visuals/ ; teardown (not OpenAI-confirmed): ~70 components + "AppBlock" HTML escape hatch https://www.explainx.ai/blog/chatgpt-intelligent-ui-gpt-6-interactive-answers-explained-2026 . Neither source says it applies to Deep Research.

## Gemini Deep Research
- Consumer app: "powered by Gemini 3"; multi-point plan; browses hundreds of sites; optional Gmail/Drive/Chat; async with notification; 1M ctx + RAG follow-ups [V] https://gemini.google/overview/deep-research/ ; "Edit plan"; ~5–10+ min; export via Canvas → Docs; Audio Overview [V] https://support.google.com/gemini/answer/15719111 . Plan editing and visuals are unavailable when Workspace sources are included.
- **Visual reports (Dec 15, 2025, Ultra-only):** charts, diagrams, interactive simulators [V] https://blog.google/products/gemini/visual-reports/ ; [I] https://www.eweek.com/news/gemini-deep-research-adds-visual-reports-charts/ (eWeek links it to experimental Dynamic View; slow, occasionally unreliable).
- Internals (planner/task manager) not described by Google. Same research infra powers Gemini app, NotebookLM, Search, Finance [V] https://blog.google/innovation-and-ai/models-and-research/gemini-models/next-generation-gemini-deep-research/
- **API (Apr 21, 2026):** `deep-research-preview-04-2026` and `deep-research-max-preview-04-2026` on Gemini 3.1 Pro (preview). Collaborative planning; `visualization:"auto"` → charts/infographics inline (HTML or Nano Banana, base64) only when the prompt asks; MCP, File Search, Google Search, URL context, code execution; multimodal inputs. Interactions API only, no custom function tools/structured output, max 60 min. Google warns of prompt-injection/exfiltration and says "review the citations" [V] https://ai.google.dev/gemini-api/docs/interactions/deep-research . Google estimates $1–3/task (DR), $3–7/task (Max) [V same page]. Prior agent shuts down Oct 23, 2026.
- Plans: AI Plus $7.99, Pro $19.99, Ultra $99.99/$199.99 [I] https://9to5google.com/2026/05/25/google-ai-plus-pro-ultra-gemini-features/ ; since May 17, 2026 limits are compute-based (5-hour refresh + weekly cap); no per-plan DR counts [V] https://support.google.com/gemini/answer/17004136
- Data: cloud; chats kept 18 months by default; human-reviewed chats up to 3 years [I] https://www.zdnet.com.au/article/dont-tell-your-ai-anything-personal-google-warns-in-new-gemini-privacy-notice/

## Independent evidence
- **Reference hallucination (Rao, Wong, Callison-Burch, 2026):** Gemini-2.5-pro DR 13.3% hallucinated URLs / 18.5% non-resolving; OpenAI DR 3.5% / 10.1%; deep-research agents pooled 10.7% vs 4.8% for plain search-augmented LLMs; 2025-era agents. [I] https://arxiv.org/html/2604.03173v1
- **DeepResearch Bench:** leaderboard moved to a GPT-5.5 judge; old/new scores not comparable. https://github.com/Ayanami0730/deep_research_bench
- **Tow Center, Mar 2025:** AI search wrong on >60% of news-citation queries https://fortune.com/2025/03/18/ai-search-engines-confidently-wrong-citing-sources-columbia-study
- **EBU/BBC, Oct 2025:** 45% of assistant answers had ≥1 significant issue; Gemini 76% (mostly sourcing). General assistants, not DR. https://www.infodocket.com/2025/10/22/bbc-largest-study-of-its-kind-shows-ai-assistants-misrepresent-news-content-45-of-the-time-regardless-of-language-or-territory/
- No rigorous 2026 independent head-to-head found. 2025 anecdote: Gemini wins breadth/exports, ChatGPT depth.
- Verification burden: Guardian's Andrew Rogoyski — checking output can take many hours (via Wikipedia).

## Demo links (could not view images)
https://www.macrumors.com/2026/02/11/chatgpt-deep-research-mode-document-viewer/ · https://blog.google/products/gemini/visual-reports/ · https://www.philschmid.de/deep-research-update

# Raw notes: how competitors present results visually

Compiled 2026-10-09 by a research subagent. Direct screenshot URLs were scarce: WebFetch can't see image content and openai.com / perplexity.ai returned 403. Only the Manus image URLs below are confirmed images; everything else is text description needing hands-on verification. Tags: **[V]** vendor, **[I]** independent.

## Manus
- Four output surfaces: slide deck (PPTX export), interactive dashboard (filters, clickable charts, shareable link), PDF report, standalone webpage; chart types bar/line/pie/scatter/heat/radar; generation method not documented [V] https://manus.im/docs/features/data-visualization
- PowerPoint mode (beta): native .pptx, charts backed by data tables, "Elements" toggles, "Edit Data" spreadsheet overlay [V] https://manus.im/blog/manus-ppt-slides — images: https://files.manuscdn.com/assets/dashboard/materials/2026/07/14/ccd61331244c5a1b1025225a82bc17180e466143f25cfa6ee97a14ef1067c016.webp · https://files.manuscdn.com/assets/dashboard/materials/2026/07/13/2b5da8b81e13a237e79a389c82bb68bcc6ad820378c7da24cb4aa74a2cf2a1e8.webp
- Wide Research output = "sortable matrix" in spreadsheet or webpage [I] VentureBeat https://venturebeat.com/ai/youve-heard-of-ai-deep-research-tools-now-manus-is-launching-wide-research-that-spins-up-100-agents-to-scour-the-web-for-you
- Reviews [I]: Taskade — sometimes clean spreadsheet, sometimes "a malformed CSV with merged cells" https://www.taskade.com/blog/manus-ai-review ; Lindy — Wide Research a differentiator, web-app design "not there yet" https://www.lindy.ai/blog/manus-ai-review ; Plus AI (competitor) — slides good with Nano Banana Pro, no citations shown, no approve step https://plusai.com/blog/manus-ai-slide-generator-review/
- Lesson: many formats, trust not visible.

## ChatGPT Deep Research
- Feb 10, 2026 full-screen viewer: TOC left, citations/sources panel right; PDF/Word/MD export; live progress; editable plan [I] https://www.androidheadlines.com/2026/02/chatgpt-deep-research-full-screen-document-viewer-update.html ; https://forums.macrumors.com/threads/chatgpts-deep-research-mode-gets-a-fullscreen-document-viewer.2477526/
- Charts/tables in reports: only a dated 2025 comparison ("when its code tool runs") https://trilogyai.substack.com/p/comparative-analysis-of-deep-research — unverified.
- GPT-6 Intelligent UI (Oct 7–8, 2026): fixed component library, streamable, dial-down control [I] https://techbriefly.com/2026/10/08/openai-chatgpt-gpt-6-interactive-visuals/ ; https://www.explainx.ai/blog/chatgpt-intelligent-ui-gpt-6-interactive-answers-explained-2026 ; official post not fetchable https://openai.com/index/gpt-6-for-everyone/ . Applies to Deep Research? Unverified.
- Critique: "a wall of text with very long paragraphs" https://www.gradually.ai/en/deep-research/ ; https://www.liveplan.com/blog/planning/deep-research-chatgpt-vs-gemini

## Gemini Deep Research
- Visual reports (Dec 2025, Ultra): model decides to add images/charts/diagrams/interactive simulators with adjustable variables; refine in Canvas; export to Docs [V] https://blog.google/products/gemini/visual-reports/ ; https://9to5google.com/2025/12/16/gemini-deep-research-images/
- API (Max): charts/infographics inline via HTML or Nano Banana; user-editable plan [V] https://blog.google/innovation-and-ai/models-and-research/gemini-models/next-generation-gemini-deep-research/
- Visuals vanish if Gmail/Drive added as sources; simulators in Docs export unclear [I] https://www.gend.co/blog/gemini-deep-research-visual-reports-2026
- Generative UI / Dynamic View: model codes a custom interactive response per prompt; raters "strongly preferred" it [V] https://research.google/blog/generative-ui-a-rich-custom-visual-interactive-user-experience-for-any-prompt/ (demo site generativeui.github.io unverified)
- Pre-visual-reports: "very well formatted", numbered chapters + exec summary, "no fancy charts or images" [I] https://www.liveplan.com/blog/planning/deep-research-chatgpt-vs-gemini

## Perplexity
- Citation UI teardown: domain chips with "+N", hover carousel (1/N), favicon source row, sidebar, Links tab, "Check sources on selection"; weaknesses: three overlapping routes, no jump from "+N" to card, no per-citation "wrong source" feedback [I] https://aiuxplayground.com/teardowns/perplexity/citations
- Labs: charts/reports/dashboards/apps; Assets tab; one reviewer: Shopify 10-K charts "impressive", mini-app "didn't function correctly" [I] https://www.nocode.mba/articles/perplexity-labs-review ; https://www.datacamp.com/tutorial/perplexity-labs
- 2026 changelog ✔ (see 03 notes): traceability layer (Mar 13), Check Sources + Source Context Panel (Jul 27), inline interactive charts / 3D (Oct 5) https://releasebot.io/updates/perplexity-ai
- Reports compact (~10 pages) and better structured than ChatGPT's [I] https://www.aryabhconsulting.com/blog/deep-research-ai-tools-comparison-2025-gemini-vs-chatgpt-vs-perplexity-for-business-research

## Claude
- Inline interactive charts/diagrams (beyond the artifacts panel); HN: praise ("beautiful, tabbed, interactive charts unprompted") and critique: "improves the perceived confidence of the LLM but doesn't do much for correctness", "Interactive slop is still slop." [I] https://news.ycombinator.com/item?id=47352751
- Research output: inline citations/links; no dedicated report viewer documented (unverified).
- Claude Science reviewer agent + provenance trail [V] https://www.anthropic.com/news/claude-science-ai-workbench ; Citations API location types, no UI guidance [V] https://platform.claude.com/docs/en/build-with-claude/citations ; https://claude.com/blog/introducing-citations-api

## Grok
No review covers DeepSearch chart/citation layout. One tester found Grok the only tool linking sources inline, with concise reports [I, dated] https://www.gradually.ai/en/deep-research/

## Elicit / Consensus / Scite / NotebookLM (design references)
- Elicit: clicking inside a report reveals supporting quotes and reasoning; extraction cells show quotes + reasoning, CSV export [V] https://support.elicit.com/en/articles/4168449 ; quote cards "1 of 6", most relevant first [I] https://support.elicit.com/en/articles/3090497 ; no confidence indicator documented.
- Consensus Meter: aggregate Yes/No/Possibly bar over top 20 with classified results beneath; verbatim quotes; ~10% misclassification [V] https://consensus.app/home/blog/consensus-meter/ ; Study Snapshot cards https://pasqualepillitteri.it/en/news/1291/consensus-ai-search-engine-220-million-scientific-papers-guide-2026 ; critics: equal-weight vote-counting.
- Scite Smart Citations: supporting (green) / mentioning / contrasting (blue) sentences, per-paper tallies, filter [V] https://help.scite.ai/zh/article/how-does-scite-work-1eje9i9 ; per-class accuracy ~97% mentioning, 64% supporting, 59% contrasting [I] https://library.hkust.edu.hk/sc/trial-scite/
- NotebookLM: numbered inline citations; click opens source at passage (highlight unconfirmed; "puzzling" sections per reviewers) [I] https://learnprompting.org/blog/notebooklm-guide ; https://fastcompanyme.com/?p=30148 ; Studio: mind maps, infographics, slides, audio/video, data tables https://9to5google.com/2026/02/06/notebooklm-slide-customization/ ; Deep Research report imports sources [V] https://blog.google/technology/google-labs/notebooklm-deep-research-file-types/

## UI evidence
- Two CHIIR studies (394 and 372 participants): clicking stays rare in every condition; hover cards support quick checks; an aligned sidebar did best as citation density rose [I] https://arxiv.org/abs/2512.12207 ; https://arxiv.org/abs/2601.14611
- No shipped product found displaying calibrated per-claim confidence; raw model self-confidence is a weak signal https://iamvera.ai/blog/ai-confidence-scores-false-certainty/

## Patterns
**Worth stealing:** aligned evidence sidebar; quote-first chips with "1 of N"; labelled supporting/contrasting sentence list (Scite); show the inputs behind any roll-up; per-claim Check Source with the check already run; provenance trail; fixed component library for charts; editable chart data; plan review before run; dial-down for visuals; one export hub.
**Table stakes now:** inline chips, hover preview, sources list/sidebar, full-screen viewer with TOC, live progress + visible plan, PDF/Word/MD export, tables, inline interactive charts (Claude, ChatGPT, Perplexity as of Oct 2026), slides/dashboards.
**Avoid:** decorative visuals outrunning correctness; overlapping source routes; equal-weight meters; visuals that disappear under some modes.

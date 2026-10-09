import { titleFromQuestion } from "./title.js";
import type { Question, RecordCitation, RecordSource, RunRecord } from "./schema.js";

const MARKER = /\[\^([A-Za-z0-9_-]{1,32})\](?!:)/g;
const QUESTION_ID_TAIL = 5;
const SLUG_WORDS = 10;

export function exportMarkdown(record: RunRecord, question: Question | undefined): string {
  const citations = new Map(record.citations.map((c) => [c.id, c]));
  const sources = new Map(record.sources.map((s) => [s.id, s]));
  const body = resolvedBody(record.answer?.markdown ?? "", citations);
  const used = [...new Set([...body.matchAll(MARKER)].map((m) => m[1]!))];
  const parts = [
    frontmatter(record, question),
    `# ${titleOf(record, question)}`,
    lead(record),
    body,
    uncheckedNotice(record),
    openItems(record),
    sourceList(used, citations, sources),
    used.map((id) => `[^${id}]: ${footnote(citations.get(id)!, sources)}`).join("\n"),
  ];
  return parts.filter((p) => p.trim()).join("\n\n") + "\n";
}

export function answerFileName(question: Pick<Question, "id" | "title">): string {
  const slug = question.title.toLowerCase()
    .normalize("NFKD").replace(/\p{M}/gu, "")
    .replace(/ł/g, "l")
    .split(/[^\p{L}\p{N}]+/u).filter(Boolean).slice(0, SLUG_WORDS).join("-");
  const tail = question.id.slice(-QUESTION_ID_TAIL).toLowerCase();
  return `${slug || "answer"}-${tail}.md`;
}

function resolvedBody(markdown: string, citations: Map<string, RecordCitation>): string {
  return markdown.replace(MARKER, (marker, id: string) => (citations.has(id) ? marker : "")).trim();
}

function titleOf(record: RunRecord, question: Question | undefined): string {
  return question?.title || titleFromQuestion(record.brief.question);
}

function frontmatter(record: RunRecord, question: Question | undefined): string {
  const lines = [
    "---",
    `title: ${yamlString(titleOf(record, question))}`,
    `headline: ${yamlString(record.answer?.headline ?? "")}`,
    `question: ${yamlString(question?.resolved_text ?? record.brief.question)}`,
    `status: ${record.status}`,
    `trust: ${record.stats.trust_level}`,
    `date: ${record.created_at.slice(0, 10)}`,
    `sources_cited: ${record.stats.sources_cited}`,
    `sources_read: ${record.stats.sources_read}`,
    `claims: ${record.stats.claims}`,
    `run: ${record.id}`,
    `question_id: ${record.question_id}`,
    `build: ${yamlString(record.pipeline.build)}`,
    "---",
  ];
  return lines.join("\n");
}

function lead(record: RunRecord): string {
  if (!record.answer) {
    return `> No answer was written${record.status_note ? `: ${record.status_note}` : "."}`;
  }
  return record.answer.headline ? `> ${record.answer.headline.replace(/\s+/g, " ").trim()}` : "";
}

function uncheckedNotice(record: RunRecord): string {
  if (record.pipeline.grounding !== "none") return "";
  return "> ⚠️ No evidence was captured for this run, so no quote below was checked against a stored source.";
}

function openItems(record: RunRecord): string {
  const sections: string[] = [];
  const conflicts = record.conflicts.filter((c) => record.open_items.conflicts.includes(c.id));
  if (conflicts.length > 0) {
    sections.push("### Conflicts\n\n" + conflicts.map((c) => `- **${c.statement}** — ${c.positions.join(" · ")}`).join("\n"));
  }
  const objections = (record.validation?.objections_open ?? []).filter((o) => record.open_items.objections.includes(o.id));
  if (objections.length > 0) {
    sections.push("### Objections still standing\n\n"
      + objections.map((o) => `- ${o.lens.replace(/_/g, " ")} · ${o.severity} — ${o.statement} → ${o.followup}`).join("\n"));
  }
  const gaps = record.gaps.filter((g) => record.open_items.gaps.includes(g.id));
  if (gaps.length > 0) sections.push("### Gaps\n\n" + gaps.map((g) => `- ${g.text}`).join("\n"));
  const failed = record.tasks.filter((t) => record.open_items.failed_tasks.includes(t.id));
  if (failed.length > 0) {
    sections.push("### Tasks that did not finish\n\n"
      + failed.map((t) => `- ${t.title} — ${t.status}${t.note ? `: ${t.note}` : ""}`).join("\n"));
  }
  return sections.length > 0 ? "## Open items\n\n" + sections.join("\n\n") : "";
}

function sourceList(used: string[], citations: Map<string, RecordCitation>, sources: Map<string, RecordSource>): string {
  const order: string[] = [];
  for (const id of used) {
    const sourceId = citations.get(id)!.source_id;
    if (!order.includes(sourceId)) order.push(sourceId);
  }
  if (order.length === 0) return "";
  const rows = order.map((sourceId, index) => {
    const source = sources.get(sourceId);
    const matches = used.map((id) => citations.get(id)!).filter((c) => c.source_id === sourceId).map((c) => c.match);
    const type = source ? ` · ${source.source_type}` : "";
    return `${index + 1}. ${link(source, sourceId)}${type} — ${badge(matches)}`;
  });
  return "## Sources\n\n" + rows.join("\n");
}

function badge(matches: RecordCitation["match"][]): string {
  if (matches.some((m) => m === "exact" || m === "normalized")) return "✓ verified";
  if (matches.includes("fuzzy")) return "≈ close match";
  return "⚠️ not verifiable";
}

function footnote(citation: RecordCitation, sources: Map<string, RecordSource>): string {
  const source = sources.get(citation.source_id);
  const parts = [link(source, citation.source_id)];
  if (citation.page !== undefined) parts.push(`p. ${citation.page}`);
  if (citation.quote) parts.push(`“${citation.quote.replace(/\s+/g, " ").trim()}”`);
  parts.push(citation.match === "unresolved" ? "(quote not found in the stored source)" : `(${badge([citation.match])})`);
  return parts.join(" — ");
}

function link(source: RecordSource | undefined, fallback: string): string {
  if (!source) return fallback;
  const title = (source.title.trim() || source.host).replace(/[\[\]]/g, "");
  return source.url ? `[${title}](${source.url})` : title;
}

function yamlString(value: string): string {
  return JSON.stringify(value.replace(/\s+/g, " ").trim());
}

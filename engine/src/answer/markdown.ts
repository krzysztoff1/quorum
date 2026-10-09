import { VISUAL_TYPES, type Element, type Spec } from "./catalog.js";
import { readingOrder } from "./datums.js";
import { formatDatum } from "./numbers.js";
import { isDatum } from "./walk.js";

export function answerMarkdown(spec: Spec, fallback: Record<string, string>): string {
  const root = spec.elements[spec.root];
  if (!root) return "";
  const blocks: string[] = [String(root.props.lead ?? "").trim()];
  for (const group of root.children ?? []) {
    const element = spec.elements[group];
    if (!element) continue;
    if (element.props.title?.trim()) blocks.push(`## ${element.props.title.trim()}`);
    for (const child of element.children ?? []) {
      const block = spec.elements[child]?.type === "Claim" ? String(spec.elements[child]!.props.text).trim() : fallback[child];
      if (block) blocks.push(block);
    }
  }
  return blocks.filter(Boolean).join("\n\n");
}

export function fallbackMarkdown(spec: Spec): Record<string, string> {
  const out: Record<string, string> = {};
  for (const key of readingOrder(spec)) {
    const element = spec.elements[key]!;
    if (VISUAL_TYPES.has(element.type) || element.type === "SourceMix") out[key] = visualMarkdown(element);
  }
  return out;
}

function visualMarkdown(element: Element): string {
  const props = element.props;
  const caption = typeof props.caption === "string" ? props.caption.trim() : "";
  switch (element.type) {
    case "Stat":
      return section(props.label, caption, ["", props.label], [
        [props.label, value(props.value), cites(props.value)],
        ...(props.of ? [[props.of.label ?? "of", value(props.of), cites(props.of)]] : []),
        ...(props.context ? [[props.context.label ?? "compared with", value(props.context), cites(props.context)]] : []),
      ]);
    case "RangeCompare":
      return pointsTable(props.measure, caption, [...props.rows, ...(props.reference ? [props.reference] : [])]);
    case "BarCompare":
      return pointsTable(props.measure, caption, props.bars);
    case "ConflictSplit":
      return section(props.question, caption, ["", props.question, "Why"], props.sides.map((side: any, index: number) => [
        `${side.label}${props.leaning?.side === index ? " (leaning)" : ""} · ${side.source_type}`,
        isDatum(side.headline) ? value(side.headline) : String(side.headline),
        String(side.summary).replace(/\|/g, "/"),
      ]), props.settle ? `Would settle it: ${props.settle}` : "");
    case "SourceMix":
      return [caption, (props.counts ?? []).map((c: any) => `${c.key} ${c.n}`).join(" · ") + (props.total ? ` (of ${props.total})` : "")]
        .filter(Boolean).join("\n\n");
    case "EvidenceTable":
      return section("", caption, props.columns.map((c: any) => c.label),
        props.rows.map((row: any) => props.columns.map((c: any) => {
          const cell = row[c.key];
          if (isDatum(cell)) return `${value(cell)} ${cites(cell)}`.trim();
          return cell === undefined ? "" : String(cell).replace(/\|/g, "/");
        })));
    default:
      return caption;
  }
}

function pointsTable(measure: string, caption: string, points: { label: string; value: Record<string, any> }[]): string {
  const withAsOf = points.some((p) => p.value.as_of);
  const withScope = points.some((p) => p.value.scope);
  const header = ["", measure, ...(withAsOf ? ["As of"] : []), ...(withScope ? ["Scope"] : []), "Sources"];
  const rows = points.map((p) => [
    p.label, value(p.value), ...(withAsOf ? [p.value.as_of ?? ""] : []), ...(withScope ? [p.value.scope ?? ""] : []), cites(p.value),
  ]);
  return section(measure, caption, header, rows, "", 1);
}

function section(title: string, caption: string, header: string[], rows: string[][], footer = "", numeric = -1): string {
  const align = header.map((_, i) => (i === numeric ? "---:" : "---"));
  const table = [`| ${header.join(" | ")} |`.replace(/\|  \|/g, "| |"), `|${align.join("|")}|`, ...rows.map((r) => `| ${r.join(" | ")} |`)];
  return [title ? `**${title}**` : "", caption, table.join("\n"), footer].filter(Boolean).join("\n\n");
}

function value(datum: Record<string, any>): string {
  const text = formatDatum(datum as any);
  const trust = datum.trust;
  if (datum.basis === "estimate") return `${text} (estimate)`;
  if (!trust || trust.confidence !== "unverified") return text;
  return trust.trace === "untraced" && datum.basis === "reported" ? `${text} ⚠ not in quote` : `${text} ⚠ unverified`;
}

function cites(datum: Record<string, any>): string {
  return (datum.cite as string[]).map((id) => `[^${id}]`).join("");
}

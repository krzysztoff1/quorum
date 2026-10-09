import { markerIds } from "../validate.js";
import type { RecordStats, RunRecord, TrustLevel } from "./schema.js";

export type StatsInput = Omit<RunRecord, "stats" | "checks">;

const SOLID_SHARE = 0.7;
const SHAKY_SHARE = 0.4;
const RESEARCH_KINDS = new Set(["angle", "objection"]);
const FAILED_STATUSES = new Set(["error", "halted", "inconclusive"]);

export function citedSourceIds(record: Pick<StatsInput, "answer" | "tasks" | "citations">): Set<string> {
  const answer = record.answer;
  if (!answer) return new Set();
  const answerTask = record.tasks.find((t) => t.id === answer.task_id);
  const ids = new Set([...markerIds(answer.markdown), ...(answerTask?.findings ?? []).flatMap((f) => f.citation_ids)]);
  const cited = new Set<string>();
  for (const citation of record.citations) {
    if (ids.has(citation.id) && citation.match !== "unresolved") cited.add(citation.source_id);
  }
  return cited;
}

export function isRead(source: StatsInput["sources"][number]): boolean {
  return source.capture !== "failed" && (source.snapshot_path !== null || source.text_length > 0);
}

export function computeStats(record: StatsInput): RecordStats {
  const read = record.sources.filter(isRead);
  const citedIds = citedSourceIds(record);
  const cited = record.sources.filter((s) => citedIds.has(s.id));
  const claims = record.claims;
  const verdictCount = (verdict: string) => claims.filter((c) => c.verdict.verdict === verdict).length;
  const research = record.tasks.filter((t) => RESEARCH_KINDS.has(t.kind));
  const answerTask = record.answer ? record.tasks.find((t) => t.id === record.answer!.task_id) : undefined;
  const claimsSolid = claims.filter((c) => c.strength === "solid").length;
  const unverified = claims.filter((c) => c.confidence === "unverified").length;
  return {
    sources_read: read.length,
    sources_cited: cited.length,
    sources_by_type: countByType(read),
    cited_by_type: countByType(cited),
    citations: record.citations.length,
    citations_resolved: record.citations.filter((c) => c.match !== "unresolved").length,
    claims: claims.length,
    claims_solid: claimsSolid,
    claims_shaky: claims.length - claimsSolid,
    claims_unverified: unverified,
    verdicts: {
      supported: verdictCount("supported"),
      unsupported: verdictCount("unsupported"),
      misquoted: verdictCount("misquoted"),
      unjudged: verdictCount("unjudged"),
    },
    findings: answerTask?.findings.length ?? 0,
    conflicts_open: record.conflicts.filter((c) => c.status === "open").length,
    gaps: record.gaps.length,
    objections_open: record.validation?.objections_open.length ?? 0,
    stripped_markers: record.stripped_markers.length,
    tasks: research.length,
    tasks_failed: research.filter((t) => FAILED_STATUSES.has(t.status)).length,
    rounds: research.reduce((max, t) => Math.max(max, t.round), 0),
    cost_usd: record.cost.usd,
    duration_s: durationSeconds(record.created_at, record.finished_at ?? record.updated_at),
    trust_level: trustLevel(record, claims.length - unverified, claimsSolid),
  };
}

function countByType(sources: StatsInput["sources"]): RecordStats["sources_by_type"] {
  const counts = { primary: 0, vendor: 0, seo: 0, academic: 0, news: 0 };
  for (const source of sources) counts[source.source_type] += 1;
  return counts;
}

function durationSeconds(from: string, to: string): number {
  const ms = Date.parse(to) - Date.parse(from);
  return Number.isFinite(ms) ? Math.max(0, Math.round(ms / 100) / 10) : 0;
}

function trustLevel(record: StatsInput, judged: number, solid: number): TrustLevel {
  if (record.pipeline.grounding === "none" || judged === 0) return "unchecked";
  const share = solid / record.claims.length;
  const holds = record.validation?.holds ?? false;
  if (!holds || share < SHAKY_SHARE) return "shaky";
  if (share >= SOLID_SHARE && judged === record.claims.length) return "solid";
  return "moderate";
}

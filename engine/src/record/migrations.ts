import { CATALOG_VERSION } from "../answer/catalog.js";
import { draftFromProse, settleAnswer } from "../answer/index.js";
import { sentenceOwners } from "./owners.js";
import { RECORD_SCHEMA } from "./schema.js";
import { visualCounts } from "./stats.js";
import type { Migrations } from "../migrate.js";

function rebuiltAnswer(record: any): any {
  const legacy = record.answer;
  const citations = record.citations ?? [];
  const settled = settleAnswer(draftFromProse(String(legacy.markdown ?? ""), citations), {
    citations,
    sources: (record.sources ?? []).map((source: any) => ({ id: source.id, source_type: source.source_type })),
    grounding: record.pipeline?.grounding ?? "captured",
  });
  return {
    catalog: CATALOG_VERSION,
    task_id: legacy.task_id,
    headline: legacy.headline,
    origin: settled.origin,
    spec: settled.spec,
    display: settled.display,
    fallback_md: settled.fallback_md,
    check: settled.check,
    repairs: settled.repairs,
    markdown: settled.markdown,
  };
}

function runV1ToV2(record: any): any {
  const { answer: _legacy, ...rest } = record;
  if (!record.answer) return { ...rest, stats: { ...record.stats, ...visualCounts({}) } };
  const answer = rebuiltAnswer(record);
  const owners = sentenceOwners(answer.spec);
  const claims = (record.claims ?? []).map((claim: any) => (owners.has(claim.text) ? { ...claim, element_id: owners.get(claim.text) } : claim));
  return { ...rest, answer, claims, stats: { ...record.stats, ...visualCounts({ answer }) } };
}

export const RECORD_MIGRATIONS: Migrations = {
  "quorum.run/1": { to: RECORD_SCHEMA, upgrade: runV1ToV2 },
};

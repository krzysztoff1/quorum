import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { draftAnswer, draftMarkdown, settleAnswer } from "../src/answer/index.js";
import { datumUnits } from "../src/answer/datums.js";
import { checkRecord } from "../src/record/checks.js";
import { RunRecordSchema, type RunRecord } from "../src/record/schema.js";
import { markedSentences } from "../src/validate.js";
import { FIXTURES_DIR, matchFixture } from "./fixtureSupport.js";
import { foldFixture } from "./recordSupport.js";

interface Registry {
  documents: { source_id: string; url: string; title: string; source_type: string }[];
  citations: { id: string; source_id: string; quote: string; match: string; start?: number; end?: number }[];
}

const REGISTRY: Registry = JSON.parse(readFileSync(join(FIXTURES_DIR, "answer", "personalization.registry.json"), "utf8"));
const ANGLES = [
  { angle_id: "a1", title: "How platforms personalize" },
  { angle_id: "a2", title: "What personalization earns" },
  { angle_id: "a3", title: "What constrains diet data" },
];
const UNSUPPORTED = ["a2c4", "a2c9"];
const SEEN_AS = "unsupported";

const event = (type: string, fields: Record<string, unknown> = {}) => ({ type, ...fields });
const fenced = (summary: unknown) => "```json\n" + JSON.stringify(summary) + "\n```";
const usage = (cost: number) => ({ provider: "claude-code", model: "claude-sonnet-4-5", input_tokens: 1, output_tokens: 1,
                                   cache_read_tokens: 0, cache_write_tokens: 0, cost_usd: cost, search_calls: 0, fetch_calls: 0 });

async function answerRun(name: string): Promise<RunRecord> {
  const reply = "```qvs\n" + readFileSync(join(FIXTURES_DIR, "answer", `${name}.qvs.jsonl`), "utf8") + "```";
  const draft = await draftAnswer(reply, REGISTRY.citations);
  const markdown = draftMarkdown(draft);
  const claims = markedSentences(markdown);
  const datums = datumUnits(draft.spec, REGISTRY.citations);
  const verdicts = [
    ...claims.map(({ claim, ids }, i) => ids.some((id) => UNSUPPORTED.includes(id))
      ? { claim_id: `k${i + 1}`, claim, verdict: SEEN_AS, severity: "minor", reason: "the quote is a marketing estimate", citation_ids: ids }
      : { claim_id: `k${i + 1}`, claim, verdict: "supported" }),
    ...datums.map((d) => ({ claim_id: d.id, claim: d.claim, verdict: "supported" })),
  ];
  const settled = settleAnswer(draft, {
    citations: REGISTRY.citations,
    sources: REGISTRY.documents.map((d) => ({ id: d.source_id, source_type: d.source_type })),
    grounding: "captured",
    verdicts: verdicts as any,
  });
  const documents = REGISTRY.documents.map((d) => ({
    ...d, content_type: "html", capture: "ok", fetched_at: "2026-10-09T10:01:00.000Z",
    snapshot_path: `sources/${d.source_id}.md`, original_path: null, text_length: 4000, byte_size: 4000, page_offsets: [],
  }));
  const readerOf = (sourceId: string) => REGISTRY.citations.find((c) => c.source_id === sourceId)?.id.slice(0, 2) ?? "a1";
  const events = [
    event("run_start", { protocol_version: 4, engine_version: "0.1.0", build: "fixture", grounding: "captured" }),
    event("phase", { phase: "planning" }),
    event("plan", { angles: ANGLES.map((a) => ({ ...a, prompt: a.title })) }),
    event("phase", { phase: "researching" }),
    ...ANGLES.flatMap((angle) => [
      event("angle_status", { angle_id: angle.angle_id, status: "running" }),
      ...documents.filter((d) => readerOf(d.source_id) === angle.angle_id).map((d) => event("document", { angle_id: angle.angle_id, document: d })),
      event("topic_result", {
        angle_id: angle.angle_id, role: "research", status: "complete", backend: "cli", provider: "claude-code",
        model: "claude-sonnet-4-5", session_id: `s-${angle.angle_id}`, note: null, usage: usage(0.4),
        result: `${angle.title}.\n\n${fenced({ headline: angle.title, status: "complete", findings: [] })}`,
        citations: REGISTRY.citations.filter((c) => c.id.startsWith(angle.angle_id + "c")),
      }),
    ]),
    event("phase", { phase: "synthesizing" }),
    event("angle_status", { angle_id: "synthesis", status: "running" }),
    event("topic_result", {
      angle_id: "synthesis", role: "synthesis", status: "complete", backend: "cli", provider: "claude-code",
      model: "claude-sonnet-4-5", session_id: "s-synthesis", note: null, usage: usage(0.3),
      result: `${settled.markdown}\n\n${fenced({ headline: HEADLINES[name], status: "complete", findings: [], ...OPEN_ITEMS[name] })}`,
      citations: REGISTRY.citations, answer: settled,
    }),
    event("phase", { phase: "done" }),
    event("run_result", {
      status: "inconclusive", grounding: "captured", total_cost_usd: 1.62, note: "Two vendor figures stand unsupported.",
      topics: [], documents, capture_failures: [],
      validation: { status: "validated", holds: true, blocking: 0, spend_usd: 0.2, objections_admitted: 0, objections_resolved: 0,
        objections_outstanding: [], unsupported_citations: UNSUPPORTED,
        rounds: [{ round: 1, sweep: "run", critics: "run", claims_found: verdicts.length, claims_checked: verdicts.length,
                   verdicts, objections: [], discarded_objections: 0, holds: true }] },
    }),
  ];
  return foldFixture("x", events, { question: QUESTIONS[name]! });
}

const HEADLINES: Record<string, string> = {
  personalization: "Personalization pays, but less than vendors claim",
  allergy: "Most delivery listings carry no allergy features",
};

const OPEN_ITEMS: Record<string, { conflicts: unknown[]; gaps: string[] }> = {
  personalization: {
    conflicts: [{ claim: "How big is the revenue lift?", positions: ["benchmarks: 1–2% in grocery", "vendors: $2.1B at Starbucks"] }],
    gaps: ["Does any filing attribute revenue to Starbucks Deep Brew?"],
  },
  allergy: { conflicts: [], gaps: [] },
};

const QUESTIONS: Record<string, string> = {
  personalization: "How do food-delivery platforms personalize, what does it earn them, and what constrains diet data?",
  allergy: "How well do delivery apps handle allergies, and how many grocery shoppers pay for a delivery subscription?",
};

describe("golden answer records for the app's renderer", () => {
  for (const name of ["personalization", "allergy"]) {
    it(`records the ${name} answer, valid and passing every check`, async () => {
      const record = await answerRun(name);
      expect(RunRecordSchema.safeParse(record).success).toBe(true);
      expect(checkRecord({ record, question: undefined }).filter((c) => c.status === "fail")).toEqual([]);
      matchFixture(`record/${name}.run.json`, JSON.stringify(record, null, 2) + "\n");
    });
  }

  it("draws the vendor's ad figure the quote does not hold as unverified, and the close match as medium", async () => {
    const record = await answerRun("personalization");
    const elements = record.answer!.spec.elements as any;
    const doordash = elements.ads.props.bars.find((b: any) => b.label === "DoorDash");
    expect(doordash.value.trust).toEqual({ tier: "supported", trace: "untraced", confidence: "unverified" });
    expect(elements.roi.props.rows.find((r: any) => r.label === "Starbucks").value.trust.confidence).toBe("medium");
    expect(elements.mix.props.counts[0]).toEqual({ key: "primary", n: 3 });
  });

  it("turns a two-bar chart into a table on the way in", async () => {
    const record = await answerRun("allergy");
    expect((record.answer!.spec.elements as any).share.type).toBe("EvidenceTable");
    expect(record.answer!.repairs.map((r) => r.action)).toEqual(["downgrade"]);
  });
});

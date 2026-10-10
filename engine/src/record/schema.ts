import { z } from "zod";

export const RECORD_SCHEMA = "quorum.run/1";
export const QUESTION_SCHEMA = "quorum.question/1";

const SOURCE_TYPES = ["primary", "vendor", "seo", "academic", "news"] as const;
const CONFIDENCE = ["high", "medium", "low", "unverified"] as const;

export const QuestionSchema = z.object({
  schema: z.literal(QUESTION_SCHEMA),
  id: z.string(),
  created_at: z.string(),
  original_text: z.string(),
  resolved_text: z.string(),
  language: z.string(),
  title: z.string(),
  title_source: z.enum(["question", "scope"]),
  run_ids: z.array(z.string()),
});

export const RefusalSchema = z.object({
  kind: z.string(),
  reason: z.string(),
}).meta({ id: "RecordRefusal" });

export const TIERS = ["quick", "deep"] as const;

export const ClarificationSchema = z.object({
  question: z.string(),
  answer: z.string(),
}).meta({ id: "RecordClarification" });

export const BriefSchema = z.object({
  question: z.string(),
  language: z.string(),
  asked: z.string().optional(),
  title: z.string().optional(),
  tier: z.enum(TIERS).optional(),
  suggested_tier: z.enum(TIERS).optional(),
  tier_reason: z.string().optional(),
  clarifications: z.array(ClarificationSchema).optional(),
}).meta({ id: "RecordBrief" });

export const PipelineSchema = z.object({
  engine_version: z.string(),
  build: z.string(),
  protocol: z.number().int(),
  backend: z.string(),
  models: z.object({
    planner: z.string(),
    research: z.string(),
    synthesis: z.string(),
    validator: z.string(),
  }).meta({ id: "RecordModels" }),
  grounding: z.enum(["captured", "none"]),
  pid: z.number().int().optional(),
  heartbeat_at: z.string().optional(),
}).meta({ id: "RecordPipeline" });

export const AnswerSchema = z.object({
  format: z.literal("markdown"),
  task_id: z.string(),
  headline: z.string(),
  markdown: z.string(),
}).meta({ id: "RecordAnswer" });

export const VerdictSchema = z.object({
  verdict: z.enum(["supported", "unsupported", "misquoted", "unjudged"]),
  severity: z.enum(["blocking", "minor"]).optional(),
  reason: z.string().optional(),
}).meta({ id: "RecordVerdict" });

export const ClaimSchema = z.object({
  id: z.string(),
  text: z.string(),
  citation_ids: z.array(z.string()),
  confidence: z.enum(CONFIDENCE),
  strength: z.enum(["solid", "shaky"]),
  verdict: VerdictSchema,
  task_id: z.string(),
  round: z.number().int(),
}).meta({ id: "RecordClaim" });

export const CitationSchema = z.object({
  id: z.string(),
  source_id: z.string(),
  quote: z.string(),
  match: z.enum(["exact", "normalized", "fuzzy", "unresolved"]),
  start: z.number().int().optional(),
  end: z.number().int().optional(),
  page: z.number().int().optional(),
  task_id: z.string(),
}).meta({ id: "RecordCitation" });

export const SourceSchema = z.object({
  id: z.string(),
  url: z.string(),
  host: z.string(),
  title: z.string(),
  content_type: z.enum(["html", "pdf", "text"]),
  source_type: z.enum(SOURCE_TYPES),
  capture: z.enum(["ok", "degraded", "failed"]),
  fetched_at: z.string().nullable(),
  snapshot_path: z.string().nullable(),
  original_path: z.string().nullable(),
  text_length: z.number().int(),
  byte_size: z.number().int(),
  page_offsets: z.array(z.number().int()),
  read_by: z.array(z.string()),
  cited: z.boolean(),
}).meta({ id: "RecordSource" });

export const CaptureFailureSchema = z.object({
  source_id: z.string(),
  url: z.string(),
  stage: z.string(),
  error: z.string(),
  kind: z.string().optional(),
}).meta({ id: "RecordCaptureFailure" });

export const ConflictSchema = z.object({
  id: z.string(),
  statement: z.string(),
  positions: z.array(z.string()),
  status: z.enum(["open", "settled"]),
  task_id: z.string(),
}).meta({ id: "RecordConflict" });

export const GapSchema = z.object({
  id: z.string(),
  text: z.string(),
  task_id: z.string(),
}).meta({ id: "RecordGap" });

export const ObjectionSchema = z.object({
  lens: z.string(),
  statement: z.string(),
  severity: z.enum(["blocking", "minor"]),
  followup: z.string(),
}).meta({ id: "RecordObjection" });

export const OpenObjectionSchema = ObjectionSchema.extend({
  id: z.string(),
}).meta({ id: "RecordOpenObjection" });

export const ClaimVerdictSchema = z.object({
  claim_id: z.string(),
  claim: z.string(),
  verdict: z.enum(["supported", "unsupported", "misquoted"]),
  severity: z.enum(["blocking", "minor"]).optional(),
  reason: z.string().optional(),
  citation_ids: z.array(z.string()).optional(),
}).meta({ id: "RecordClaimVerdict" });

export const ValidationRoundSchema = z.object({
  round: z.number().int(),
  sweep: z.enum(["run", "skipped"]),
  critics: z.enum(["run", "skipped"]),
  claims_found: z.number().int(),
  claims_checked: z.number().int(),
  verdicts: z.array(ClaimVerdictSchema),
  objections: z.array(ObjectionSchema),
  discarded_objections: z.number().int(),
  holds: z.boolean(),
  note: z.string().optional(),
}).meta({ id: "RecordValidationRound" });

export const ValidationSchema = z.object({
  status: z.enum(["validated", "unvalidated"]),
  holds: z.boolean(),
  blocking: z.number().int(),
  spend_usd: z.number(),
  objections_admitted: z.number().int(),
  objections_resolved: z.number().int(),
  objections_open: z.array(OpenObjectionSchema),
  unsupported_citations: z.array(z.string()),
  rounds: z.array(ValidationRoundSchema),
}).meta({ id: "RecordValidation" });

export const OpenItemsSchema = z.object({
  conflicts: z.array(z.string()),
  objections: z.array(z.string()),
  gaps: z.array(z.string()),
  failed_tasks: z.array(z.string()),
}).meta({ id: "RecordOpenItems" });

export const FindingSchema = z.object({
  claim: z.string(),
  confidence: z.enum(CONFIDENCE),
  citation_ids: z.array(z.string()),
  sources: z.array(z.string()),
}).meta({ id: "RecordFinding" });

export const TaskSchema = z.object({
  id: z.string(),
  node_id: z.string(),
  kind: z.enum(["plan", "angle", "objection", "synthesis", "reconciliation", "verify"]),
  title: z.string(),
  prompt: z.string().optional(),
  round: z.number().int(),
  status: z.enum(["queued", "running", "complete", "inconclusive", "halted", "error"]),
  origin: z.string(),
  started_at: z.string().optional(),
  finished_at: z.string().optional(),
  cost_usd: z.number(),
  backend: z.string().optional(),
  model: z.string().optional(),
  session_id: z.string().optional(),
  headline: z.string().optional(),
  writeup: z.string().optional(),
  note: z.string().optional(),
  findings: z.array(FindingSchema),
  citation_ids: z.array(z.string()),
  source_ids: z.array(z.string()),
  transcript: z.string().optional(),
}).meta({ id: "RecordTask" });

export const GraphNodeSchema = z.object({
  id: z.string(),
  kind: z.string(),
  title: z.string(),
  parent_ids: z.array(z.string()),
  depth: z.number().int(),
  round: z.number().int(),
  status: z.string(),
  origin: z.string(),
  cost_usd: z.number().optional(),
  lens: z.string().optional(),
  objections: z.array(ObjectionSchema).optional(),
  why: z.string().optional(),
  provoked_by: z.string().optional(),
  statement: z.string().optional(),
  severity: z.string().optional(),
  est_cost_usd: z.number().optional(),
  rejected_reason: z.string().optional(),
}).meta({ id: "RecordGraphNode" });

export const GraphEdgeSchema = z.object({
  from: z.string(),
  to: z.string(),
  kind: z.string(),
  label: z.string().optional(),
}).meta({ id: "RecordGraphEdge" });

export const CostSchema = z.object({
  usd: z.number(),
  by_role: z.object({
    plan: z.number(),
    research: z.number(),
    synthesis: z.number(),
    verify: z.number(),
    validate: z.number(),
  }).meta({ id: "RecordCostByRole" }),
}).meta({ id: "RecordCost" });

export const LimitsSchema = z.object({
  cap_usd: z.number().optional(),
  deadline_s: z.number().optional(),
}).meta({ id: "RecordLimits" });

export const TimelineEntrySchema = z.object({
  at: z.string(),
  phase: z.string(),
}).meta({ id: "RecordTimelineEntry" });

export const StrippedMarkerSchema = z.object({
  task_id: z.string(),
  marker: z.string(),
}).meta({ id: "RecordStrippedMarker" });

export const SourceTypeCountsSchema = z.object({
  primary: z.number().int(),
  vendor: z.number().int(),
  seo: z.number().int(),
  academic: z.number().int(),
  news: z.number().int(),
}).meta({ id: "RecordSourceTypeCounts" });

export const StatsSchema = z.object({
  sources_read: z.number().int(),
  sources_cited: z.number().int(),
  sources_by_type: SourceTypeCountsSchema,
  cited_by_type: SourceTypeCountsSchema,
  citations: z.number().int(),
  citations_resolved: z.number().int(),
  claims: z.number().int(),
  claims_solid: z.number().int(),
  claims_shaky: z.number().int(),
  claims_unverified: z.number().int(),
  verdicts: z.object({
    supported: z.number().int(),
    unsupported: z.number().int(),
    misquoted: z.number().int(),
    unjudged: z.number().int(),
  }).meta({ id: "RecordVerdictCounts" }),
  findings: z.number().int(),
  conflicts_open: z.number().int(),
  gaps: z.number().int(),
  objections_open: z.number().int(),
  stripped_markers: z.number().int(),
  tasks: z.number().int(),
  tasks_failed: z.number().int(),
  rounds: z.number().int(),
  cost_usd: z.number(),
  duration_s: z.number(),
  trust_level: z.enum(["solid", "moderate", "shaky", "unchecked"]),
}).meta({ id: "RecordStats" });

export const CheckSchema = z.object({
  id: z.string(),
  name: z.string(),
  status: z.enum(["pass", "fail", "warn"]),
  detail: z.string(),
}).meta({ id: "RecordCheck" });

export const RunRecordSchema = z.object({
  schema: z.literal(RECORD_SCHEMA),
  id: z.string(),
  question_id: z.string(),
  kind: z.enum(["initial", "followup", "rerun"]),
  created_at: z.string(),
  updated_at: z.string(),
  finished_at: z.string().optional(),
  status: z.enum(["running", "complete", "inconclusive", "halted", "failed", "cancelled", "crashed"]),
  status_note: z.string().optional(),
  refusal: RefusalSchema.optional(),
  brief: BriefSchema,
  pipeline: PipelineSchema,
  answer: AnswerSchema.optional(),
  claims: z.array(ClaimSchema),
  citations: z.array(CitationSchema),
  sources: z.array(SourceSchema),
  capture_failures: z.array(CaptureFailureSchema),
  conflicts: z.array(ConflictSchema),
  gaps: z.array(GapSchema),
  validation: ValidationSchema.optional(),
  open_items: OpenItemsSchema,
  tasks: z.array(TaskSchema),
  graph: z.object({
    nodes: z.array(GraphNodeSchema),
    edges: z.array(GraphEdgeSchema),
  }).meta({ id: "RecordGraph" }),
  cost: CostSchema,
  limits: LimitsSchema,
  timeline: z.array(TimelineEntrySchema),
  stripped_markers: z.array(StrippedMarkerSchema),
  stats: StatsSchema,
  checks: z.array(CheckSchema),
});

export type Question = z.infer<typeof QuestionSchema>;
export type Brief = z.infer<typeof BriefSchema>;
export type Clarification = z.infer<typeof ClarificationSchema>;
export type Tier = (typeof TIERS)[number];
export type RunRecord = z.infer<typeof RunRecordSchema>;
export type RecordTask = z.infer<typeof TaskSchema>;
export type RecordClaim = z.infer<typeof ClaimSchema>;
export type RecordCitation = z.infer<typeof CitationSchema>;
export type RecordSource = z.infer<typeof SourceSchema>;
export type RecordGraphNode = z.infer<typeof GraphNodeSchema>;
export type RecordObjection = z.infer<typeof ObjectionSchema>;
export type RecordStats = z.infer<typeof StatsSchema>;
export type RecordCheck = z.infer<typeof CheckSchema>;
export type RecordStatus = RunRecord["status"];
export type TrustLevel = RecordStats["trust_level"];

export function runRecordJsonSchema(): Record<string, unknown> {
  return { title: "RunRecord", ...z.toJSONSchema(RunRecordSchema, { target: "draft-2020-12" }) };
}

export function questionJsonSchema(): Record<string, unknown> {
  return { title: "QuestionRecord", ...z.toJSONSchema(QuestionSchema, { target: "draft-2020-12" }) };
}

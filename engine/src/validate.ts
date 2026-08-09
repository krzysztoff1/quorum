import { parseFencedJson } from "./agent.js";
import { CLAIM_VERIFIER_SYSTEM_PROMPT, criticSystemPrompt } from "./systemPrompt.js";
import type { GroundingTier } from "./config.js";
import type { Citation, SourceDocument } from "./evidence.js";

export type ClaimJudgement = "supported" | "unsupported" | "misquoted";
export type ObjectionSeverity = "blocking" | "minor";
export type CriticLens = "coverage" | "conflicts" | "sources";
export type ObjectionLens = CriticLens | "claim_sweep" | "structure";

export const CRITIC_LENSES: CriticLens[] = ["coverage", "conflicts", "sources"];
export const VALIDATOR_TASKS: ObjectionLens[] = ["claim_sweep", ...CRITIC_LENSES];
export const CLAIM_BATCH_SIZE = 10;
export const OBJECTIONS_PER_CRITIC = 3;
export const CLAIM_BATCH_BUDGET_USD = 0.05;
export const CRITIC_BUDGET_USD = 0.1;

const ACTIONABLE_FOLLOWUP_WORDS = 4;
const CLAIM_EXCERPT_CHARS = 160;

export interface ClaimUnit {
  id: string;
  claim: string;
  citations: Citation[];
}

export interface ClaimVerdict {
  claim_id: string;
  claim: string;
  verdict: ClaimJudgement;
  severity?: ObjectionSeverity;
  reason?: string;
  /// The located quotes this claim was judged against, kept on a verdict that failed so the reader can
  /// badge the very chips the claim leans on rather than the answer as a whole.
  citation_ids?: string[];
}

export interface Objection {
  lens: ObjectionLens;
  statement: string;
  severity: ObjectionSeverity;
  followup: string;
}

export interface ValidationRound {
  round: number;
  sweep: "run" | "skipped";
  critics: "run" | "skipped";
  claims_found: number;
  claims_checked: number;
  verdicts: ClaimVerdict[];
  objections: Objection[];
  discarded_objections: number;
  holds: boolean;
  note?: string;
}

export interface Validation {
  status: "validated" | "unvalidated";
  holds: boolean;
  blocking: number;
  spend_usd: number;
  objections_admitted: number;
  objections_resolved: number;
  objections_outstanding: Objection[];
  /// The citations whose claims the last round still could not stand up. They are located quotes, so the
  /// reader may not draw them as verified and may not drop them either — they ship badged.
  unsupported_citations: string[];
  rounds: ValidationRound[];
}

export interface TaskVerdict {
  lens: ObjectionLens;
  title: string;
  status: string;
  objections: Objection[];
}

export interface ValidatorCall {
  id: string;
  systemPrompt: string;
  prompt: string;
  budgetUsd: number;
}

export type Judge = (call: ValidatorCall) => Promise<string>;

export interface AngleFindings {
  angle_id: string;
  result: string;
}

export interface ValidateInput {
  question: string;
  round: number;
  synthesisResult: string;
  citations: Citation[];
  research: AngleFindings[];
  documents: SourceDocument[];
  grounding: GroundingTier;
  budgetUsd: number;
  /// What the deterministic layer already knows is wrong with this answer — an unreadable summary, a claim
  /// whose marker a rewrite lost. Filed with the round's objections rather than asked of a model, because
  /// nothing here needs judging.
  filed: Objection[];
  judge: Judge;
}

/// One round of judgement over an answer nobody in here wrote: the deterministic layer's located quotes are
/// swept for claims they do not actually carry, then three lenses that cannot see each other file what is
/// still wrong. Nothing here edits the answer — every finding leaves as a verdict or an objection.
export async function validateSynthesis(input: ValidateInput): Promise<ValidationRound> {
  const units = input.grounding === "none" ? [] : claimUnits(input.synthesisResult, input.citations);
  const batches = claimBatches(units);
  const perCallBudgetUsd = input.budgetUsd / (batches.length + CRITIC_LENSES.length);
  if (perCallBudgetUsd <= 0) {
    return skippedRound(input.round, units.length,
                        "The run budget was spent before validation could start; nothing was checked.",
                        input.filed);
  }

  const verdicts: ClaimVerdict[] = [];
  const objections: Objection[] = [...input.filed];
  const sweepReplies = await Promise.all(batches.map((batch, index) => input.judge({
    id: `claim_sweep_${index + 1}`,
    systemPrompt: CLAIM_VERIFIER_SYSTEM_PROMPT,
    prompt: claimSweepPrompt(input.question, batch),
    budgetUsd: Math.min(CLAIM_BATCH_BUDGET_USD, perCallBudgetUsd),
  })));
  sweepReplies.forEach((reply, index) => {
    const read = parseClaimVerdicts(reply, batches[index]!);
    verdicts.push(...read.verdicts);
    if (read.unjudged.length > 0) objections.push(unjudgedObjection(read.unjudged));
  });

  let discarded = 0;
  const criticReplies = await Promise.all(CRITIC_LENSES.map((lens) => input.judge({
    id: `critic_${lens}`,
    systemPrompt: criticSystemPrompt(lens),
    prompt: criticPrompt(lens, input),
    budgetUsd: Math.min(CRITIC_BUDGET_USD, perCallBudgetUsd),
  })));
  criticReplies.forEach((reply, index) => {
    const read = parseObjections(reply, CRITIC_LENSES[index]!);
    objections.push(...read.objections);
    discarded += read.discarded;
  });

  return {
    round: input.round,
    sweep: input.grounding === "none" ? "skipped" : "run",
    critics: "run",
    claims_found: units.length,
    claims_checked: verdicts.length,
    verdicts,
    objections,
    discarded_objections: discarded,
    holds: blockingCount({ verdicts, objections }) === 0,
    ...(input.grounding === "none"
      ? { note: "No evidence was captured, so no claim could be checked against a located quote." }
      : {}),
  };
}

export function skippedRound(round: number, claimsFound: number, note: string,
                             objections: Objection[] = []): ValidationRound {
  return {
    round, sweep: "skipped", critics: "skipped", claims_found: claimsFound, claims_checked: 0,
    verdicts: [], objections, discarded_objections: 0,
    holds: blockingCount({ verdicts: [], objections }) === 0, note,
  };
}

/// Whether the answer stands is decided by the LAST judgement of it, not by the rounds it took to get
/// there: an objection the loop researched and settled is history, not a permanent mark.
export function summarizeValidation(rounds: ValidationRound[], spendUsd: number,
                                    admitted: Objection[]): Validation {
  const last = rounds[rounds.length - 1];
  const outstanding = last ? loopObjections(last) : [];
  return {
    status: rounds.length > 0 && rounds.every((r) => r.sweep === "run") ? "validated" : "unvalidated",
    holds: last ? last.holds : true,
    blocking: rounds.reduce((sum, r) => sum + blockingCount(r), 0),
    spend_usd: spendUsd,
    objections_admitted: admitted.length,
    objections_resolved: admitted.filter((o) => !outstanding.some((s) => s.statement === o.statement)).length,
    objections_outstanding: outstanding,
    unsupported_citations: last ? unsupportedCitations(last) : [],
    rounds,
  };
}

/// Which quotes the answer as it stands still leans on without being carried by them. Only the last round
/// counts: a claim an earlier round could not stand up and a later round rewrote is history, and badging
/// its quotes would be badging text nobody is reading.
export function unsupportedCitations(round: ValidationRound): string[] {
  return [...new Set(round.verdicts
    .filter((v) => v.verdict !== "supported")
    .flatMap((v) => v.citation_ids ?? []))];
}

/// What the loop has left to chase: the blocking objections the critics filed, plus the blocking verdicts
/// the sweep returned, each carrying the task that would settle it. A verdict is not an objection until
/// something can be done about it, and naming that task is the orchestrator's job, not the verifier's.
export function loopObjections(round: ValidationRound): Objection[] {
  return [...round.objections, ...sweepObjections(round)].filter((o) => o.severity === "blocking");
}

/// Each claim the sweep did not pass, read as what it is: an objection against the answer, carrying the
/// research that would settle it. The claim itself is left exactly as its author wrote it.
export function sweepObjections(round: ValidationRound): Objection[] {
  return round.verdicts
    .filter((v) => v.verdict !== "supported")
    .map((v): Objection => ({
      lens: "claim_sweep",
      statement: `the claim "${excerpt(v.claim)}" is ${v.verdict} by its own located quotes`
                 + (v.reason ? ` — ${v.reason}` : ""),
      severity: v.severity ?? "blocking",
      followup: `find a source that settles, one way or the other: ${excerpt(v.claim)}`,
    }));
}

/// One verdict per validator task, which is what the canvas draws beside the answer: what the task was,
/// whether anything stands against the answer because of it, and exactly what it filed. An objection the
/// deterministic layer filed with nobody asked gets its own verdict rather than being folded into a
/// validator's — nothing here judged it.
export function taskVerdicts(round: ValidationRound): TaskVerdict[] {
  const filed = [...round.objections, ...sweepObjections(round)];
  const extra = [...new Set(filed.map((o) => o.lens))].filter((lens) => !VALIDATOR_TASKS.includes(lens));
  return [...VALIDATOR_TASKS, ...extra].map((lens) => {
    const objections = filed.filter((o) => o.lens === lens);
    return {
      lens,
      title: taskTitle(lens),
      status: taskRan(round, lens) ? (objections.length === 0 ? "pass" : `objections(${objections.length})`)
                                   : "skipped",
      objections,
    };
  });
}

function taskRan(round: ValidationRound, lens: ObjectionLens): boolean {
  if (lens === "claim_sweep") return round.sweep === "run";
  if (CRITIC_LENSES.includes(lens as CriticLens)) return round.critics === "run";
  return true;
}

function taskTitle(lens: ObjectionLens): string {
  switch (lens) {
    case "claim_sweep": return "Claim sweep";
    case "coverage":    return "Coverage critic";
    case "conflicts":   return "Conflicts critic";
    case "sources":     return "Sources critic";
    default:            return "Structure";
  }
}

export function blockingCount(round: Pick<ValidationRound, "verdicts" | "objections">): number {
  const verdicts = round.verdicts.filter((v) => v.verdict !== "supported" && v.severity === "blocking").length;
  return verdicts + round.objections.filter((o) => o.severity === "blocking").length;
}

/// Every sentence of the answer that leans on a marker the evidence layer resolved. A sentence whose marker
/// never resolved is already flagged by that layer and has no located quote to judge it against, so it is
/// left alone rather than sent to a model that would have to guess.
export function claimUnits(result: string, citations: Citation[]): ClaimUnit[] {
  const located = new Map(citations.filter((c) => c.match !== "unresolved").map((c) => [c.id, c]));
  const units: ClaimUnit[] = [];
  for (const line of claimLines(result)) {
    for (const sentence of sentences(line)) {
      const ids = [...new Set(markerIds(sentence))];
      const cited = ids.map((id) => located.get(id)).filter((c): c is Citation => Boolean(c));
      const claim = stripMarkers(sentence);
      if (cited.length === 0 || !claim) continue;
      units.push({ id: `k${units.length + 1}`, claim, citations: cited });
    }
  }
  return units;
}

export function claimBatches(units: ClaimUnit[], size = CLAIM_BATCH_SIZE): ClaimUnit[][] {
  const batches: ClaimUnit[][] = [];
  for (let i = 0; i < units.length; i += size) batches.push(units.slice(i, i + size));
  return batches;
}

export function claimSweepPrompt(question: string, batch: ClaimUnit[]): string {
  let s = `The answer under review set out to answer: ${question}\n\n`;
  batch.forEach((unit, index) => {
    s += `CLAIM ${index + 1}: ${unit.claim}\n`;
    s += "Quotes located word-for-word in the stored sources for this claim:\n";
    for (const citation of unit.citations) {
      s += `- ${matchLabel(citation)}: "${flatten(citation.quote)}"\n`;
    }
    s += "\n";
  });
  return s;
}

export function criticPrompt(lens: CriticLens, input: ValidateInput): string {
  if (lens === "coverage") {
    return `The question asked: ${input.question}\n\nThe answer given:\n${answerBody(input.synthesisResult)}\n`;
  }
  if (lens === "conflicts") {
    let s = `The question asked: ${input.question}\n\n`;
    s += `Findings from ${input.research.length} independent angle(s) that never saw each other:\n\n`;
    for (const angle of input.research) {
      s += `===== ANGLE ${angle.angle_id} =====\n`;
      for (const finding of findingsOf(angle.result)) s += `- ${findingLine(finding)}\n`;
      s += "\n";
    }
    return s;
  }
  let s = `The question asked: ${input.question}\n\nThe answer's findings:\n`;
  for (const finding of findingsOf(input.synthesisResult)) s += `- ${findingLine(finding)}\n`;
  s += "\nDocuments the run actually captured:\n";
  for (const document of input.documents) {
    s += `- ${document.url} — ${document.title || "untitled"} (capture: ${document.capture})\n`;
  }
  return s;
}

export function parseClaimVerdicts(reply: string, batch: ClaimUnit[]):
  { verdicts: ClaimVerdict[]; unjudged: ClaimUnit[] } {
  const raw: any[] = parseFencedJson(reply)?.verdicts ?? [];
  const verdicts: ClaimVerdict[] = [];
  const judged = new Set<string>();
  for (const entry of raw) {
    const unit = matchUnit(entry, batch);
    const verdict = judgement(entry?.verdict);
    if (!unit || !verdict || judged.has(unit.id)) continue;
    judged.add(unit.id);
    verdicts.push({
      claim_id: unit.id,
      claim: unit.claim,
      verdict,
      ...(verdict === "supported"
            ? {}
            : { severity: severity(entry?.severity), citation_ids: unit.citations.map((c) => c.id) }),
      ...(verdict === "supported" || !entry?.reason ? {} : { reason: flatten(String(entry.reason)) }),
    });
  }
  return { verdicts, unjudged: batch.filter((unit) => !judged.has(unit.id)) };
}

export function parseObjections(reply: string, lens: ObjectionLens):
  { objections: Objection[]; discarded: number } {
  const raw: any[] = parseFencedJson(reply)?.objections ?? [];
  const objections: Objection[] = [];
  let discarded = 0;
  for (const entry of raw) {
    const statement = stripMarkers(String(entry?.statement ?? ""));
    const followup = stripMarkers(String(entry?.followup ?? ""));
    if (!statement || !isActionable(followup)) {
      discarded++;
      continue;
    }
    if (objections.length >= OBJECTIONS_PER_CRITIC) continue;
    objections.push({ lens, statement, severity: severity(entry?.severity), followup });
  }
  return { objections, discarded };
}

/// What the reader is told about the judgement, in the answer itself. A validator never edits the answer, so
/// this section stands beside it: the claims that failed, the objections that stand, and the tasks that
/// would settle them — or one line saying the answer was checked and held.
export function appendValidation(result: string, round: ValidationRound): string {
  const fence = result.lastIndexOf("```json");
  const body = (fence === -1 ? result : result.slice(0, fence)).trimEnd();
  const rest = fence === -1 ? "" : result.slice(fence);
  return `${body}\n\n${validationSection(round)}\n\n${rest}`.trimEnd() + "\n";
}

function validationSection(round: ValidationRound): string {
  const lines = ["## Validation", ""];
  if (round.sweep === "skipped" && round.critics === "skipped") {
    lines.push(`⚠️ ${round.note ?? "This answer was not validated."}`);
    return lines.join("\n");
  }
  if (round.sweep === "skipped") {
    lines.push(`⚠️ Unvalidated — ${round.note ?? "the claim sweep did not run."} The coverage, conflicts `
               + "and sources critics still ran.");
  }
  const failed = round.verdicts.filter((v) => v.verdict !== "supported");
  if (failed.length === 0 && round.objections.length === 0) {
    if (round.sweep === "run") {
      lines.push(`✓ Validated — ${round.claims_checked} claim(s) checked against their located quotes; the `
                 + "coverage, conflicts and sources critics filed nothing.");
    }
    return lines.join("\n");
  }
  if (lines.length > 2) lines.push("");
  lines.push("These were filed against the answer, not fixed in it — only further research settles them:", "");
  for (const verdict of failed) {
    lines.push(`- claim sweep · ${verdict.verdict} · ${verdict.severity} — “${excerpt(verdict.claim)}”`
               + (verdict.reason ? ` — ${verdict.reason}` : ""));
  }
  for (const objection of round.objections) {
    lines.push(`- ${objection.lens.replace("_", " ")} · ${objection.severity} — ${objection.statement} `
               + `→ ${objection.followup}`);
  }
  return lines.join("\n");
}

/// A writeup whose fenced summary will not parse cannot be grounded at all — no quote of it is checked and
/// no finding of it reaches the answer. Nothing a researcher could look up fixes that, so it is filed as a
/// visible defect of the run rather than as work for the loop.
export function unreadableSummaryObjection(angleId: string): Objection {
  return {
    lens: "structure",
    statement: `${angleId} returned no machine-readable summary, so none of its quotes could be grounded`,
    severity: "minor",
    followup: `run the ${angleId} angle again and have it report a fenced json summary`,
  };
}

/// A marker a rewrite dropped: the claim is still asserted, but the evidence it stood on is gone. That IS
/// researchable — a claim with no quote behind it needs a source — so it blocks until one is found.
export function orphanedMarkerObjection(claim: string, citationIds: string[]): Objection {
  return {
    lens: "claim_sweep",
    statement: `${claim} lost the evidence it was standing on (${citationIds.join(", ")})`,
    severity: "blocking",
    followup: `find a source that states, or refutes: ${excerpt(claim)}`,
  };
}

function unjudgedObjection(unjudged: ClaimUnit[]): Objection {
  return {
    lens: "claim_sweep",
    statement: `the claim verifier returned no verdict for ${unjudged.length} claim(s)`,
    severity: "minor",
    followup: `re-check these claims against their located quotes: ${
      unjudged.map((u) => excerpt(u.claim)).join(" · ")}`,
  };
}

function matchUnit(entry: any, batch: ClaimUnit[]): ClaimUnit | undefined {
  const claim = entry?.claim;
  if (typeof claim === "number") return batch[claim - 1];
  const text = flatten(String(claim ?? ""));
  return batch.find((unit) => unit.claim === text) ?? batch[Number(text) - 1];
}

function judgement(raw: unknown): ClaimJudgement | undefined {
  const value = String(raw ?? "").toLowerCase();
  return value === "supported" || value === "unsupported" || value === "misquoted" ? value : undefined;
}

/// An unclassified objection counts as blocking: a validator that failed to say how much a failure matters
/// has not said it does not matter.
function severity(raw: unknown): ObjectionSeverity {
  return String(raw ?? "").toLowerCase() === "minor" ? "minor" : "blocking";
}

/// A follow-up too vague to hand to a researcher cannot be resolved by one, and an objection that cannot be
/// resolved would sit on the answer forever.
function isActionable(followup: string): boolean {
  return followup.split(/\s+/).filter(Boolean).length >= ACTIONABLE_FOLLOWUP_WORDS;
}

function matchLabel(citation: Citation): string {
  return citation.match === "fuzzy" ? "close match in the stored source" : "exact match in the stored source";
}

function claimLines(result: string): string[] {
  return answerBody(result)
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !/^([#>|]|\[\^|```)/.test(line))
    .map((line) => line.replace(/^([-*+]|\d+\.)\s+/, ""));
}

/// The prose the answer actually asserts: no fenced summary, and none of the apparatus the run appends
/// after it (the citation check, the sources list with its footnote definitions, a prior validation pass).
export function answerBody(result: string): string {
  const fence = result.lastIndexOf("```json");
  const body = fence === -1 ? result : result.slice(0, fence);
  const appendix = body.search(/^##\s+(Sources|Citation check|Validation)\b/m);
  return appendix === -1 ? body : body.slice(0, appendix);
}

function sentences(line: string): string[] {
  const boundary = /[.!?](?:\s*\[\^[A-Za-z0-9_-]{1,32}\])*/g;
  const out: string[] = [];
  let start = 0;
  let hit: RegExpExecArray | null;
  while ((hit = boundary.exec(line))) {
    const end = hit.index + hit[0].length;
    const next = line[end];
    if (next !== undefined && !/\s/.test(next)) continue;
    out.push(line.slice(start, end));
    start = end;
  }
  out.push(line.slice(start));
  return out.map((s) => s.trim()).filter(Boolean);
}

function markerIds(text: string): string[] {
  return [...text.matchAll(/\[\^([A-Za-z0-9_-]{1,32})\]/g)].map((m) => m[1]!);
}

function stripMarkers(text: string): string {
  return flatten(text.replace(/\[\^[A-Za-z0-9_-]{1,32}\]/g, ""));
}

function flatten(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

function excerpt(claim: string): string {
  return claim.length > CLAIM_EXCERPT_CHARS ? claim.slice(0, CLAIM_EXCERPT_CHARS - 1) + "…" : claim;
}

function findingsOf(result: string): any[] {
  const findings = parseFencedJson(result)?.findings;
  return Array.isArray(findings) ? findings : [];
}

function findingLine(finding: any): string {
  const sources = Array.isArray(finding?.sources) ? finding.sources : [];
  return `${finding?.claim ?? ""} · ${finding?.confidence ?? "unverified"} · ${sources.join(", ")}`;
}

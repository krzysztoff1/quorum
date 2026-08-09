import { parseFencedJson } from "./agent.js";
import { normalizeSource } from "./evidence.js";
import { answerBody, loopObjections, type ValidationRound } from "./validate.js";

export interface ReconciliationRound {
  synthesis: string;
  validation?: ValidationRound;
}

export function divergedAcrossRounds(syntheses: string[]): boolean {
  if (syntheses.length < 2) return false;
  const summaries = syntheses.map((result) => parseFencedJson(result) ?? {});
  if (summaries.some((summary) => Array.isArray(summary.conflicts) && summary.conflicts.length > 0)) return true;
  const earlier = new Set(summaries.slice(0, -1).flatMap(claims));
  return claims(summaries.at(-1)).some((claim) => !earlier.has(claim));
}

export function reconciliationContext(question: string, rounds: ReconciliationRound[]): string {
  let s = `You are reconciling ${rounds.length} SEQUENTIAL rounds of research on the SAME question.\n`;
  s += "Your job is to produce one clean current answer.\n";
  s += "Use the best format for the material: a short narrative, bullets, or headings if they help.\n";
  s += "Each later round was run to correct or deepen the earlier ones, so where a later round corrected\n";
  s += "an earlier one, the corrected position is the standing answer and the superseded claim does not\n";
  s += "survive. Keep only the disagreements, gaps and objections still unresolved after the final round.\n";
  s += "Weight corroboration across rounds more heavily than mere recency. Keep every [^marker] on the\n";
  s += "claim it stands behind — a claim that loses its evidence is a claim nobody can check.\n\n";
  s += `Original question: ${question}\n\n`;
  rounds.forEach((round, index) => {
    const summary = parseFencedJson(round.synthesis) ?? {};
    s += `===== ROUND ${index + 1}: ${summary.headline ?? `Round ${index + 1}`} =====\n`;
    s += findingsSection(summary);
    const body = answerBody(round.synthesis).trim();
    s += `${body || "_no writeup_"}\n`;
    s += conflictsSection(index + 1, summary);
    s += gapsSection(index + 1, summary);
    s += objectionsSection(index + 1, round.validation);
    s += "\n";
  });
  return s;
}

function findingsSection(summary: any): string {
  const findings: any[] = Array.isArray(summary?.findings) ? summary.findings : [];
  if (findings.length === 0) return "";
  let s = "Findings (claim · confidence · sources):\n";
  for (const finding of findings) {
    const sources = Array.isArray(finding?.sources) ? finding.sources : [];
    s += `- ${finding?.claim ?? ""} · ${finding?.confidence ?? "unverified"} · ${sources.join(", ")}\n`;
  }
  return s + "\n";
}

function conflictsSection(round: number, summary: any): string {
  const conflicts: any[] = Array.isArray(summary?.conflicts) ? summary.conflicts : [];
  if (conflicts.length === 0) return "";
  let s = `Round ${round} unresolved conflicts:\n`;
  for (const conflict of conflicts) {
    const positions = Array.isArray(conflict?.positions) ? conflict.positions : [];
    s += `- ${conflict?.claim ?? ""}: ${positions.join(" / ")}\n`;
  }
  return s;
}

function gapsSection(round: number, summary: any): string {
  const gaps: any[] = Array.isArray(summary?.gaps) ? summary.gaps : [];
  if (gaps.length === 0) return "";
  let s = `Round ${round} open gaps:\n`;
  for (const gap of gaps) s += `- ${gap}\n`;
  return s;
}

function objectionsSection(round: number, validation?: ValidationRound): string {
  const standing = validation ? loopObjections(validation) : [];
  if (standing.length === 0) return "";
  let s = `Round ${round} objections still standing against that answer:\n`;
  for (const objection of standing) s += `- ${objection.lens}: ${objection.statement}\n`;
  return s;
}

function claims(summary: any): string[] {
  const findings: any[] = Array.isArray(summary?.findings) ? summary.findings : [];
  return findings.map((finding) => normalizeSource(String(finding?.claim ?? "")));
}

export function standsAgainstAnswer(round: ValidationRound): boolean {
  return round.objections.length > 0 || round.verdicts.some((verdict) => verdict.verdict !== "supported");
}

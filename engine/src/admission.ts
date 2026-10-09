export interface AdmissionLimits {
  maxDepth: number;
  maxInquiriesPerRun: number;
  dedupThreshold: number;
  freezeFraction: number;
}

export const DEFAULT_ADMISSION_LIMITS: AdmissionLimits = {
  maxDepth: 3,
  maxInquiriesPerRun: 12,
  dedupThreshold: 0.62,
  freezeFraction: 0.7,
};

export interface Followup {
  question: string;
  why: string;
  provoked_by: string;
  parent_id: string;
}

export interface AdmittedInquiry {
  inquiry_id: string;
  question_id: string;
  parent_id: string;
  question: string;
  why: string;
  provoked_by: string;
  depth: number;
  est_cost_usd: number;
}

export type Admission =
  | { verdict: "approved"; inquiry_id: string; est_cost_usd: number; inquiry: AdmittedInquiry }
  | { verdict: "rejected"; reason: string };

export interface AdmissionGateDeps {
  perTopicBudgetUsd: number;
  runBudgetUsd: number;
  synthesisReserveUsd: number;
  validationReserveUsd?: number;
  spentUsd: () => number;
  elapsedFraction: () => number;
  limits?: Partial<AdmissionLimits>;
}

interface KnownInquiry {
  question: string;
  depth: number;
}

export class AdmissionGate {
  private readonly limits: AdmissionLimits;
  private readonly inquiries = new Map<string, KnownInquiry>();
  private sequence = 0;

  constructor(private readonly deps: AdmissionGateDeps) {
    this.limits = { ...DEFAULT_ADMISSION_LIMITS, ...(deps.limits ?? {}) };
  }

  seed(id: string, question: string, depth: number): void {
    if (!this.inquiries.has(id)) this.inquiries.set(id, { question, depth });
  }

  inquiryCount(): number {
    return this.inquiries.size;
  }

  ceilingFor(depth: number): number {
    return this.deps.perTopicBudgetUsd / Math.pow(2, Math.max(0, depth - 1));
  }

  frozen(): boolean {
    return this.deps.elapsedFraction() >= this.limits.freezeFraction;
  }

  admit(followup: Followup): Admission {
    const reason = this.refusal(followup);
    if (reason) return { verdict: "rejected", reason };
    const parent = this.inquiries.get(followup.parent_id)!;
    const depth = parent.depth + 1;
    const sequence = ++this.sequence;
    const inquiry: AdmittedInquiry = {
      inquiry_id: `x${sequence}`,
      question_id: `q${sequence}`,
      parent_id: followup.parent_id,
      question: followup.question.trim(),
      why: followup.why.trim(),
      provoked_by: followup.provoked_by.trim(),
      depth,
      est_cost_usd: this.ceilingFor(depth),
    };
    this.inquiries.set(inquiry.inquiry_id, { question: inquiry.question, depth });
    return { verdict: "approved", inquiry_id: inquiry.inquiry_id, est_cost_usd: inquiry.est_cost_usd, inquiry };
  }

  private refusal(followup: Followup): string | undefined {
    if (!followup.question?.trim()) return "a follow-up must carry a question";

    const parent = this.inquiries.get(followup.parent_id);
    if (!parent) return `unknown parent inquiry ${followup.parent_id}`;
    if (this.frozen()) return "past the freeze, the run is winding down to its synthesis";

    const depth = parent.depth + 1;
    if (depth > this.limits.maxDepth) return `depth limit of ${this.limits.maxDepth} reached`;
    if (this.inquiries.size >= this.limits.maxInquiriesPerRun) {
      return `the run's cap of ${this.limits.maxInquiriesPerRun} inquiries is already committed`;
    }

    const duplicate = this.nearestQuestion(followup.question);
    if (duplicate) return `duplicate of a question already being asked: "${duplicate}"`;

    if (this.ceilingFor(depth) > this.headroomUsd()) {
      return "the remaining run budget cannot cover another inquiry and still reserve the synthesis "
             + "and the validation sweep";
    }
    return undefined;
  }

  private headroomUsd(): number {
    return this.deps.runBudgetUsd - this.deps.spentUsd() - this.deps.synthesisReserveUsd
           - (this.deps.validationReserveUsd ?? 0);
  }

  private nearestQuestion(question: string): string | undefined {
    const known = [...this.inquiries.values()].map((i) => i.question);
    return known.find((candidate) => questionSimilarity(candidate, question) >= this.limits.dedupThreshold);
  }
}

const FILLER = new Set([
  "a", "an", "and", "are", "as", "at", "be", "by", "did", "do", "does", "for", "from", "has", "have",
  "how", "in", "is", "it", "much", "of", "on", "or", "say", "that", "the", "their", "to", "was", "what",
  "when", "where", "which", "who", "why", "will", "with",
]);

function significantWords(text: string): Set<string> {
  const words = text
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .split(/\s+/)
    .filter((w) => w.length > 0 && !FILLER.has(w));
  return new Set(words);
}

export function questionSimilarity(a: string, b: string): number {
  const left = significantWords(a);
  const right = significantWords(b);
  if (left.size === 0 || right.size === 0) return 0;
  let shared = 0;
  for (const word of left) if (right.has(word)) shared += 1;
  return (2 * shared) / (left.size + right.size);
}

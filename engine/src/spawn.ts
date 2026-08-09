export type SpawnMode = "off" | "ask" | "auto";

export interface SpawnLimits {
  maxDepth: number;
  maxChildrenPerInquiry: number;
  maxInquiriesPerRun: number;
  dedupThreshold: number;
  spawnFreezeFraction: number;
}

export const DEFAULT_SPAWN_LIMITS: SpawnLimits = {
  maxDepth: 3,
  maxChildrenPerInquiry: 2,
  maxInquiriesPerRun: 12,
  dedupThreshold: 0.62,
  spawnFreezeFraction: 0.7,
};

export interface InquiryRequest {
  question: string;
  why: string;
  provoked_by: string;
  parent_id: string;
}

export interface PendingInquiry {
  inquiry_id: string;
  question_id: string;
  parent_id: string;
  question: string;
  why: string;
  provoked_by: string;
  depth: number;
  est_cost_usd: number;
}

export type SpawnVerdict =
  | { verdict: "pending"; inquiry_id: string; est_cost_usd: number; inquiry: PendingInquiry }
  | { verdict: "approved"; inquiry_id: string; est_cost_usd: number; inquiry: PendingInquiry }
  | { verdict: "rejected"; reason: string };

export interface SpawnGateDeps {
  perTopicBudgetUsd: number;
  runBudgetUsd: number;
  synthesisReserveUsd: number;
  spentUsd: () => number;
  elapsedFraction: () => number;
  limits?: Partial<SpawnLimits>;
  mode?: SpawnMode;
}

interface KnownInquiry {
  question: string;
  depth: number;
  children: number;
}

/// Everything that decides whether a question the run raised mid-flight becomes work. Kept apart from the
/// orchestrator because these are the limits the user set, and they should be readable in one place and
/// testable without running a model.
export class SpawnGate {
  private readonly limits: SpawnLimits;
  private readonly mode: SpawnMode;
  private readonly inquiries = new Map<string, KnownInquiry>();
  private readonly pending = new Map<string, PendingInquiry>();
  private sequence = 0;

  constructor(private readonly deps: SpawnGateDeps) {
    this.limits = { ...DEFAULT_SPAWN_LIMITS, ...(deps.limits ?? {}) };
    this.mode = deps.mode ?? "ask";
  }

  seed(id: string, question: string, depth: number): void {
    if (!this.inquiries.has(id)) this.inquiries.set(id, { question, depth, children: 0 });
  }

  inquiryCount(): number {
    return this.inquiries.size;
  }

  pendingCount(): number {
    return this.pending.size;
  }

  childCount(id: string): number {
    return this.inquiries.get(id)?.children ?? 0;
  }

  depthOf(id: string): number | undefined {
    return this.inquiries.get(id)?.depth;
  }

  /// A spawned question is narrower than a planned angle, so it gets a narrower ceiling. Halving per level
  /// is what keeps a deep chain affordable without a separate budget to administer.
  ceilingFor(depth: number): number {
    return this.deps.perTopicBudgetUsd / Math.pow(2, Math.max(0, depth - 1));
  }

  request(req: InquiryRequest): SpawnVerdict {
    const refusal = this.refuse(req);
    if (refusal) return { verdict: "rejected", reason: refusal };

    const parentDepth = this.inquiries.get(req.parent_id)!.depth;
    const depth = parentDepth + 1;
    const seq = ++this.sequence;
    const inquiry: PendingInquiry = {
      inquiry_id: `x${seq}`,
      question_id: `q${seq}`,
      parent_id: req.parent_id,
      question: req.question.trim(),
      why: req.why.trim(),
      provoked_by: req.provoked_by.trim(),
      depth,
      est_cost_usd: this.ceilingFor(depth),
    };
    this.pending.set(inquiry.inquiry_id, inquiry);
    if (this.mode === "auto") {
      this.approve(inquiry.inquiry_id);
      return { verdict: "approved", inquiry_id: inquiry.inquiry_id, est_cost_usd: inquiry.est_cost_usd, inquiry };
    }
    return { verdict: "pending", inquiry_id: inquiry.inquiry_id, est_cost_usd: inquiry.est_cost_usd, inquiry };
  }

  approve(id: string): PendingInquiry | undefined {
    const inquiry = this.pending.get(id);
    if (!inquiry) return undefined;
    this.pending.delete(id);
    this.inquiries.set(id, { question: inquiry.question, depth: inquiry.depth, children: 0 });
    const parent = this.inquiries.get(inquiry.parent_id);
    if (parent) parent.children += 1;
    return inquiry;
  }

  reject(id: string): PendingInquiry | undefined {
    const inquiry = this.pending.get(id);
    this.pending.delete(id);
    return inquiry;
  }

  /// Past the freeze, a question nobody ruled on is dropped rather than waited for — a run left unattended
  /// still has to reach its synthesis. These are drawn as expired, not as refused.
  expirePending(): PendingInquiry[] {
    const expired = [...this.pending.values()];
    this.pending.clear();
    return expired;
  }

  peekPending(): PendingInquiry[] {
    return [...this.pending.values()];
  }

  frozen(): boolean {
    return this.deps.elapsedFraction() >= this.limits.spawnFreezeFraction;
  }

  private refuse(req: InquiryRequest): string | undefined {
    if (this.mode === "off") return "spawning is off for this run";
    if (!req.provoked_by?.trim()) return "a spawn must name the source or finding that provoked it";
    if (!req.question?.trim()) return "a spawn must carry a question";

    const parent = this.inquiries.get(req.parent_id);
    if (!parent) return `unknown parent inquiry ${req.parent_id}`;
    if (this.frozen()) return "past the spawn freeze — the run is winding down to its synthesis";

    const depth = parent.depth + 1;
    if (depth > this.limits.maxDepth) return `depth limit of ${this.limits.maxDepth} reached`;
    if (parent.children + this.pendingChildrenOf(req.parent_id) >= this.limits.maxChildrenPerInquiry) {
      return `an inquiry may branch into at most ${this.limits.maxChildrenPerInquiry} children`;
    }
    if (this.committedCount() >= this.limits.maxInquiriesPerRun) {
      return `the run's cap of ${this.limits.maxInquiriesPerRun} inquiries is already committed`;
    }

    const duplicate = this.nearestQuestion(req.question);
    if (duplicate) return `duplicate of a question already being asked — "${duplicate}"`;

    if (this.ceilingFor(depth) > this.headroomUsd()) {
      return "the remaining run budget cannot cover another inquiry and still reserve the synthesis";
    }
    return undefined;
  }

  /// Actual spend, not reserved ceilings. Reservations commit the whole run budget before the first angle
  /// runs, so a gate reading them would refuse every spawn a run ever raised. Pending ceilings do count —
  /// the gate must never offer a spawn it could not fund if the user approved all of them.
  private headroomUsd(): number {
    const pendingCommitted = [...this.pending.values()].reduce((sum, p) => sum + p.est_cost_usd, 0);
    return this.deps.runBudgetUsd - this.deps.spentUsd() - this.deps.synthesisReserveUsd - pendingCommitted;
  }

  private committedCount(): number {
    return this.inquiries.size + this.pending.size;
  }

  private pendingChildrenOf(parentID: string): number {
    return [...this.pending.values()].filter((p) => p.parent_id === parentID).length;
  }

  private nearestQuestion(question: string): string | undefined {
    const known = [
      ...[...this.inquiries.values()].map((i) => i.question),
      ...[...this.pending.values()].map((p) => p.question),
    ];
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

/// Dice overlap over the words that carry meaning. Deliberately the same shape of comparison the evidence
/// grounding uses for quotes: cheap, deterministic, and impossible for a model to argue with.
export function questionSimilarity(a: string, b: string): number {
  const left = significantWords(a);
  const right = significantWords(b);
  if (left.size === 0 || right.size === 0) return 0;
  let shared = 0;
  for (const word of left) if (right.has(word)) shared += 1;
  return (2 * shared) / (left.size + right.size);
}

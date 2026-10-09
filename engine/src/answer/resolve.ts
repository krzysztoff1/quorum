import { CHART_TYPES, VISUAL_TYPES, type DatumConfidence, type Element, type ResolvedSpec, type Spec, type Tier, type Trace } from "./catalog.js";
import { datumUnits } from "./datums.js";
import { fallbackMarkdown } from "./markdown.js";
import { datumInQuotes, formatDatum } from "./numbers.js";
import { citeRefs, forEachDatum, isDatum, markers, pointer, type Path } from "./walk.js";

export interface ResolvableCitation {
  id: string;
  source_id: string;
  quote: string;
  match: string;
}

export interface SweepVerdict {
  claim_id: string;
  claim: string;
  verdict: "supported" | "unsupported" | "misquoted";
}

export interface ResolveInput {
  citations: ResolvableCitation[];
  sources: { id: string; source_type: string }[];
  grounding: "captured" | "none";
  verdicts?: SweepVerdict[];
}

export interface CheckIssue {
  element_id: string;
  rule: string;
  severity: "error" | "warn";
  detail: string;
}

export interface Resolution {
  spec: ResolvedSpec;
  display: Record<string, "chart" | "table">;
  fallback_md: Record<string, string>;
  issues: CheckIssue[];
  untraced: UntracedDatum[];
}

export interface UntracedDatum {
  element_id: string;
  label: string;
  value: string;
  cite: string[];
}

const TIER_ORDER: Tier[] = ["supported", "close", "unsupported", "unresolved"];
const TYPE_STRENGTH = ["primary", "academic", "news", "vendor", "seo"];

function verified(tier: Tier): boolean {
  return tier === "supported" || tier === "close";
}

export function citationTier(citation: ResolvableCitation | undefined, grounding: ResolveInput["grounding"]): Tier {
  if (!citation || citation.match === "unresolved" || grounding === "none") return "unresolved";
  return citation.match === "fuzzy" ? "close" : "supported";
}

export function datumConfidence(basis: string, tier: Tier, trace: Trace): DatumConfidence {
  if (!verified(tier)) return "unverified";
  if (basis === "reported" && trace === "untraced") return "unverified";
  if (basis === "estimate") return "low";
  if (basis === "derived" || tier === "close") return "medium";
  return "high";
}

export function resolveSpec(input: Spec, context: ResolveInput): Resolution {
  const spec = structuredClone(input) as Spec;
  const byId = new Map(context.citations.map((c) => [c.id, c]));
  const tierOf = (id: string) => citationTier(byId.get(id), context.grounding);
  const worst = (ids: string[]) => ids.map(tierOf).reduce<Tier>((w, t) => (TIER_ORDER.indexOf(t) > TIER_ORDER.indexOf(w) ? t : w), "supported");
  const locatedQuotes = (ids: string[]) => ids.map((id) => byId.get(id)).filter((c) => c && c.match !== "unresolved").map((c) => c!.quote);
  const sweptOut = sweptPointers(input, context);
  const issues: CheckIssue[] = [];
  const untraced: UntracedDatum[] = [];
  const parentOf = new Map<string, string>();
  for (const [key, element] of Object.entries(spec.elements)) for (const child of element.children ?? []) parentOf.set(child, key);

  for (const [key, element] of Object.entries(spec.elements)) {
    const props = element.props;
    forEachDatum(props, ["elements", key, "props"], (datum, path) => {
      const cite: string[] = datum.cite;
      const inQuote = datumInQuotes(datum as any, locatedQuotes(cite));
      const trace: Trace = inQuote ? "quoted" : datum.basis === "derived" && locatedQuotes(cite).length > 0 ? "derived" : "untraced";
      const tier: Tier = sweptOut.has(pointer(path)) ? "unsupported" : worst(cite);
      datum.trust = { tier, trace, confidence: datumConfidence(datum.basis, tier, trace) };
      if (datum.basis === "reported" && trace === "untraced" && locatedQuotes(cite).length > 0) {
        const label = datumLabel(element, path, datum);
        untraced.push({ element_id: key, label, value: formatDatum(datum as any), cite });
        issues.push({ element_id: key, rule: "number_not_in_quote", severity: "warn",
                      detail: `${label}: ${formatDatum(datum as any)} is not in ${cite.join(", ")}` });
      }
    });
    switch (element.type) {
      case "Claim":
        props.confidence = claimConfidence(props, tierOf, context.verdicts ?? []);
        break;
      case "BarCompare": {
        const distinct = (field: string) => new Set(props.bars.map((b: any) => b.value[field] ?? "")).size > 1;
        props.mixed_basis = { as_of: distinct("as_of"), scope: distinct("scope") };
        break;
      }
      case "ConflictSplit":
        for (const side of props.sides) side.tier_mix = tierMix(citeRefs(side, []).map((r) => r.id), tierOf);
        break;
      case "SourceMix": {
        const root = props.scope === "group" && parentOf.has(key) ? parentOf.get(key)! : spec.root;
        const ids = [...new Set(idsUnder(spec, root))];
        Object.assign(props, sourceMix(props.by, ids, byId, context));
        break;
      }
    }
  }

  const display: Record<string, "chart" | "table"> = {};
  for (const [key, element] of Object.entries(spec.elements)) {
    if (!VISUAL_TYPES.has(element.type) && element.type !== "SourceMix") continue;
    display[key] = displayOf(element);
  }
  return { spec: spec as unknown as ResolvedSpec, display, fallback_md: fallbackMarkdown(spec), issues, untraced };
}

function sweptPointers(spec: Spec, context: ResolveInput): Set<string> {
  const failed = new Set((context.verdicts ?? []).filter((v) => v.verdict !== "supported").map((v) => `${v.claim_id}\u0000${v.claim}`));
  if (failed.size === 0) return new Set();
  return new Set(datumUnits(spec, context.citations).filter((unit) => failed.has(`${unit.id}\u0000${unit.claim}`)).map((unit) => unit.pointer));
}

function claimConfidence(props: Record<string, any>, tierOf: (id: string) => Tier, verdicts: SweepVerdict[]): DatumConfidence {
  const ids = markers(props.text);
  if (!ids.some((id) => verified(tierOf(id)))) return "unverified";
  const sentences = new Set(verdicts.filter((v) => v.verdict !== "supported").map((v) => v.claim));
  if ([...sentences].some((sentence) => sentence && String(props.text).replace(/\[\^[^\]]+\]/g, "").includes(sentence.replace(/\s+/g, " ").trim()))) {
    return "low";
  }
  return props.confidence;
}

function tierMix(ids: string[], tierOf: (id: string) => Tier): Record<Tier, number> {
  const mix: Record<Tier, number> = { supported: 0, close: 0, unsupported: 0, unresolved: 0 };
  for (const id of new Set(ids)) mix[tierOf(id)] += 1;
  return mix;
}

function idsUnder(spec: Spec, key: string): string[] {
  const element = spec.elements[key];
  if (!element) return [];
  return [...citeRefs(element.props, []).map((r) => r.id), ...(element.children ?? []).flatMap((child) => idsUnder(spec, child))];
}

function sourceMix(by: string, ids: string[], byId: Map<string, ResolvableCitation>, context: ResolveInput) {
  if (by === "tier") {
    const mix = tierMix(ids, (id) => citationTier(byId.get(id), context.grounding));
    const counts = TIER_ORDER.map((key) => ({ key, n: mix[key] })).filter((c) => c.n > 0);
    return { counts, total: counts.reduce((sum, c) => sum + c.n, 0) };
  }
  const typeOf = new Map(context.sources.map((s) => [s.id, s.source_type]));
  const sources = new Map<string, string>();
  for (const id of ids) {
    const citation = byId.get(id);
    if (citation && citation.match !== "unresolved") sources.set(citation.source_id, typeOf.get(citation.source_id) ?? "vendor");
  }
  const counts = TYPE_STRENGTH.map((key) => ({ key, n: [...sources.values()].filter((t) => t === key).length })).filter((c) => c.n > 0);
  return { counts, total: sources.size };
}

function datumsOf(element: Element): Record<string, any>[] {
  const found: Record<string, any>[] = [];
  forEachDatum(element.props, [], (datum) => found.push(datum));
  return found;
}

function displayOf(element: Element): "chart" | "table" {
  if (element.type === "EvidenceTable") return "table";
  if (!CHART_TYPES.has(element.type)) return "chart";
  const datums = datumsOf(element);
  const unverified = datums.filter((d) => d.trust?.confidence === "unverified").length;
  return unverified * 2 > datums.length ? "table" : "chart";
}

function datumLabel(element: Element, path: Path, datum: Record<string, any>): string {
  const owner = path.slice(3, -1).reduce<any>((node, segment) => node?.[segment as any], element.props);
  if (owner && typeof owner === "object" && typeof owner.label === "string" && !isDatum(owner)) return owner.label;
  return datum.label ?? element.props.label ?? element.props.measure ?? element.type;
}

// resolveSpec: attach the ⚙ engine fields to a validated ModelSpec. The model never writes these.
//   Datum.trust {tier, numberInQuote, confidence} · Claim.confidence floor · BarCompare.mixedBasis
//   ConflictSplit.sides[].tierMix · SourceMix.counts · Timeline/DecisionMatrix/ArgumentMap item tiers
import type { Citation, El, Registry, SpecLike, TierT } from "./catalog";
import { datumInQuotes, yearInQuotes } from "./numbers";
import { citeRefs, forEachDatum, markers } from "./walk";

const ORDER: TierT[] = ["supported", "close", "unsupported", "unresolved"];
const verified = (t: TierT) => t === "supported" || t === "close";

/** Same ladder as `EvidenceIndex.tier(_:)` in QuorumCore: locate first, then the sweep's verdict, then match quality. */
export function citationTier(c: Citation | undefined, reg: Registry): TierT {
  if (!c || c.match === "unresolved" || reg.grounding === "none") return "unresolved";
  if (reg.unsupported_citations?.includes(c.id)) return "unsupported";
  return c.match === "fuzzy" ? "close" : "supported";
}

export function resolveSpec(spec: SpecLike, reg: Registry): SpecLike {
  const byId = new Map(reg.citations.map((c) => [c.id, c]));
  const tierOf = (id: string) => citationTier(byId.get(id), reg);
  const worst = (ids: string[]): TierT => ids.reduce<TierT>((w, id) => (ORDER.indexOf(tierOf(id)) > ORDER.indexOf(w) ? tierOf(id) : w), "supported");
  const quotes = (ids: string[]) => ids.map((id) => byId.get(id)?.quote).filter((q): q is string => !!q);
  const mix = (ids: string[]) => {
    const m = { supported: 0, close: 0, unsupported: 0, unresolved: 0 };
    for (const id of new Set(ids)) m[tierOf(id)]++;
    return m;
  };
  const kindOf = new Map((reg.documents ?? []).map((d) => [d.source_id, d.kind ?? "unknown"]));

  const out: SpecLike = structuredClone(spec);
  const parentOf = new Map<string, string>();
  for (const [k, el] of Object.entries(out.elements)) for (const c of el.children ?? []) parentOf.set(c, k);
  const idsUnder = (key: string): string[] => {
    const el = out.elements[key];
    if (!el) return [];
    return [...citeRefs(el.props, []).map((r) => r.id), ...(el.children ?? []).flatMap(idsUnder)];
  };

  for (const [key, el] of Object.entries(out.elements) as [string, El][]) {
    const p = el.props;
    forEachDatum(p, [], (d) => {
      const tier = worst(d.cite);
      const numberInQuote = datumInQuotes(d, quotes(d.cite));
      const confidence = !verified(tier) || (d.basis === "reported" && !numberInQuote) ? "unverified"
        : d.basis === "estimate" ? "low"
        : d.basis === "derived" || tier === "close" ? "medium" : "high";
      d.trust = { tier, numberInQuote, confidence };
    });
    switch (el.type) {
      case "Claim":
        if (!markers(p.text).some((id) => verified(tierOf(id)))) p.confidence = "unverified";
        break;
      case "BarCompare": {
        const distinct = (f: (b: any) => unknown) => new Set(p.bars.map(f)).size > 1;
        p.mixedBasis = { asOf: distinct((b) => b.value.asOf), scope: distinct((b) => b.value.scope) };
        break;
      }
      case "SmallMultiples":
        if (p.of === "BarCompare") for (const pn of p.panels) {
          const distinct = (f: (b: any) => unknown) => new Set(pn.props.bars.map(f)).size > 1;
          pn.props.mixedBasis = { asOf: distinct((b) => b.value.asOf), scope: distinct((b) => b.value.scope) };
        }
        break;
      case "ConflictSplit":
        for (const s of p.sides) s.tierMix = mix(citeRefs(s, []).map((r) => r.id));
        break;
      case "SourceMix": {
        const ids = [...new Set(Array.isArray(p.scope) ? p.scope
          : p.scope === "group" && parentOf.has(key) ? idsUnder(parentOf.get(key)!)
          : idsUnder(out.root))];
        if (p.by === "tier") p.counts = Object.entries(mix(ids)).map(([k, n]) => ({ key: k, n }));
        else {
          const sources = new Map<string, string>();
          for (const id of ids) { const c = byId.get(id); if (c) sources.set(c.source_id, kindOf.get(c.source_id) ?? "unknown"); }
          const n = new Map<string, number>();
          for (const k of sources.values()) n.set(k, (n.get(k) ?? 0) + 1);
          p.counts = [...n].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([k, v]) => ({ key: k, n: v }));
        }
        break;
      }
      case "Timeline":
        for (const e of p.events) {
          e.tier = worst(e.cite);
          if (p.axis === "date") { const y = yearInQuotes(e.at, quotes(e.cite)); if (y !== undefined) e.dateInQuote = y; }
        }
        break;
      case "DecisionMatrix":
        for (const c of p.cells) if (c.cite.length) c.tier = worst(c.cite);
        break;
      case "ArgumentMap":
        for (const n of p.nodes) n.tier = worst(n.cite);
        break;
    }
  }
  return out;
}

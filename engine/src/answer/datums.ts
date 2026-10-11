import { VISUAL_TYPES, type Spec } from "./catalog.js";
import { formatDatum } from "./numbers.js";
import { forEachDatum, isDatum, pointer, stripMarkers } from "./walk.js";

export interface DatumUnitCitation {
  id: string;
  source_id: string;
  quote: string;
  match: string;
}

export interface DatumUnit {
  id: string;
  claim: string;
  context: string;
  citations: DatumUnitCitation[];
  element_id: string;
  pointer: string;
}

export function readingOrder(spec: Spec): string[] {
  const seen = new Set<string>();
  const order: string[] = [];
  const walk = (key: string) => {
    if (seen.has(key) || !spec.elements[key]) return;
    seen.add(key);
    order.push(key);
    for (const child of spec.elements[key]!.children ?? []) walk(child);
  };
  walk(spec.root);
  return order;
}

export function datumUnits(spec: Spec, citations: DatumUnitCitation[]): DatumUnit[] {
  const located = new Map(citations.filter((c) => c.match !== "unresolved").map((c) => [c.id, c]));
  const units: DatumUnit[] = [];
  let index = 0;
  for (const key of readingOrder(spec)) {
    const element = spec.elements[key]!;
    if (!VISUAL_TYPES.has(element.type)) continue;
    const context = [element.props.measure ?? element.props.question ?? element.props.label, stripMarkers(String(element.props.caption ?? ""))]
      .filter((part) => typeof part === "string" && part.trim()).join(" — ");
    forEachDatum(element.props, ["elements", key, "props"], (datum, path) => {
      index += 1;
      const cited = (datum.cite as string[]).map((id) => located.get(id)).filter((c): c is DatumUnitCitation => Boolean(c));
      if (cited.length === 0) return;
      units.push({
        id: `d${index}`,
        claim: `${labelFor(element.props, path.slice(3), datum)}: ${formatDatum(datum as any)}${qualifier(datum)}`,
        context,
        citations: cited,
        element_id: key,
        pointer: pointer(path),
      });
    });
  }
  return units;
}

function labelFor(props: Record<string, any>, path: (string | number)[], datum: Record<string, any>): string {
  const owner = path.slice(0, -1).reduce<any>((node, segment) => node?.[segment as any], props);
  if (owner && typeof owner === "object" && !isDatum(owner) && typeof owner.label === "string") return owner.label;
  return datum.label ?? props.label ?? props.measure ?? "value";
}

function qualifier(datum: Record<string, any>): string {
  const parts = [datum.scope, datum.as_of].filter((p) => typeof p === "string" && p.trim());
  return parts.length > 0 ? ` (${parts.join(", ")})` : "";
}

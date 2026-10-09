import type { Element, Spec } from "../src/answer/catalog.js";
import type { KnownCitation } from "../src/answer/validate.js";

export const CITATIONS: KnownCitation[] = [
  { id: "a1c1", quote: "personalization lifts revenue 5 to 15 percent across retail", match: "exact" },
  { id: "a1c2", quote: "grocers see a lift of 1-2% of total sales", match: "exact" },
  { id: "a1c3", quote: "Instacart ads and other revenue topped $1 billion in 2025", match: "fuzzy" },
  { id: "a1c4", quote: "Uber's advertising business reached a $2 billion annual run rate", match: "exact" },
  { id: "a1c5", quote: "DoorDash has built advertising into a meaningful revenue line", match: "exact" },
  { id: "a1c6", quote: "the page could not be read", match: "unresolved" },
];

export function datum(cite: string, shape: Record<string, unknown>): Record<string, unknown> {
  return { unit: "pct", basis: "reported", cite: [cite], ...shape };
}

export function bar(label: string, cite: string, v: number, extra: Record<string, unknown> = {}) {
  return { label, value: { v, unit: "usd", scale: "B", basis: "reported", cite: [cite], as_of: "2025", ...extra } };
}

export function adsChart(bars = [bar("Uber", "a1c4", 2), bar("Instacart", "a1c3", 1), bar("DoorDash", "a1c5", 1)]): Element {
  return { type: "BarCompare", props: { measure: "Ad revenue", bars, caption: "All three report ad businesses[^a1c3][^a1c4]." } };
}

export function liftChart(): Element {
  return {
    type: "RangeCompare",
    props: {
      measure: "Revenue lift",
      rows: [
        { label: "Retail", value: datum("a1c1", { lo: 5, hi: 15 }) },
        { label: "Grocery", value: datum("a1c2", { lo: 1, hi: 2 }) },
      ],
      caption: "Grocery sits below retail[^a1c1][^a1c2].",
    },
  };
}

export function claim(text: string, confidence = "high"): Element {
  return { type: "Claim", props: { text, confidence } };
}

export function answer(groups: Record<string, Element[]>, extra: Record<string, Element> = {},
                       props: Record<string, unknown> = {}): Spec {
  const elements: Record<string, Element> = {
    answer: { type: "Answer", props: { lead: "Lift is small in grocery[^a1c2].", verdict: "leaning", ...props }, children: Object.keys(groups) },
    ...extra,
  };
  for (const [group, children] of Object.entries(groups)) {
    const keys = children.map((child, index) => {
      const key = `${group}_${index}`;
      elements[key] = child;
      return key;
    });
    elements[group] = { type: "Group", props: { title: `About ${group}` }, children: keys };
  }
  return { v: 1, root: "answer", elements };
}

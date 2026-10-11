import { z } from "zod";
import { SOURCE_TYPES } from "../sourceTypes.js";

export const CATALOG_VERSION = "qvs/1";
export const UNITS = ["pct", "pp", "usd", "eur", "gbp", "count", "ratio", "score", "days", "months", "years", "items", "other"] as const;
export const TIERS = ["supported", "close", "unsupported", "unresolved"] as const;
export const TRACES = ["quoted", "derived", "untraced"] as const;
export const DATUM_CONFIDENCE = ["high", "medium", "low", "unverified"] as const;
export const VERDICTS = ["settled", "leaning", "contested", "inconclusive"] as const;

export type Mode = "model" | "resolved";
export type Tier = (typeof TIERS)[number];
export type Trace = (typeof TRACES)[number];
export type DatumConfidence = (typeof DATUM_CONFIDENCE)[number];

export interface ComponentDef {
  props: z.ZodType;
  visual: boolean;
  children?: string;
  use: string;
  avoid: string;
}

const datumShape = {
  v: z.number().optional().describe("A point value. Either v, or both lo and hi."),
  lo: z.number().optional().describe("Range low."),
  hi: z.number().optional().describe("Range high."),
  unit: z.enum(UNITS).describe("pct: 69 means 69%. pp: percentage points. usd/eur/gbp take scale k/M/B. other: name it in suffix."),
  suffix: z.string().optional().describe("The unit as written for other: MJ, ms, GW, tokens."),
  scale: z.enum(["k", "M", "B"]).optional().describe("2.1 with scale B is 2.1 billion."),
  cmp: z.enum(["gt", "lt", "approx"]).optional().describe("The quote's own hedge: >$1B is gt, ~20% is approx."),
  basis: z.enum(["reported", "derived", "estimate"])
    .describe("reported: the number is in the cited quote. derived: computed, cite every input. estimate: the run's own judgement."),
  cite: z.array(z.string()).min(1).describe("At least one citation id from the verified quotes you were handed."),
  as_of: z.string().optional().describe("2024, 2026-Q1, 2025-10. Required in BarCompare."),
  scope: z.string().optional().describe("What the number covers: grocery, US shoppers, full year."),
  label: z.string().optional().describe("A short display label, at most 32 characters."),
};

export function datumShapeOk(datum: { v?: number; lo?: number; hi?: number }): boolean {
  const point = datum.v !== undefined;
  const range = datum.lo !== undefined && datum.hi !== undefined;
  if (point) return datum.lo === undefined && datum.hi === undefined;
  return range && datum.lo! <= datum.hi!;
}

function build(mode: Mode) {
  const resolved = mode === "resolved";
  const name = (id: string) => (resolved ? `QVS${id}` : `QVSModel${id}`);
  const onlyResolved = <T extends Record<string, z.ZodType>>(shape: T): T => (resolved ? shape : ({} as T));

  const Trust = z.strictObject({
    tier: z.enum(TIERS),
    trace: z.enum(TRACES),
    confidence: z.enum(DATUM_CONFIDENCE),
  }).meta({ id: "QVSTrust" });
  const TierMix = z.strictObject({
    supported: z.number().int(), close: z.number().int(), unsupported: z.number().int(), unresolved: z.number().int(),
  }).meta({ id: "QVSTierMix" });

  const Datum = z.strictObject({ ...datumShape, ...onlyResolved({ trust: Trust }) })
    .refine(datumShapeOk, { message: "a datum needs either v, or both lo and hi with lo ≤ hi", params: { code: "datum_shape" } })
    .meta({ id: name("Datum"), description: "A cited number. No prop anywhere takes a bare number." });
  const Rich = z.string().describe("Text with citation markers: Grocery lift is 1–2%[^a2c17].");
  const caption = z.string().describe("One cited sentence saying the one thing the visual shows.");
  const labelled = z.strictObject({ label: z.string(), value: Datum });

  const components: Record<string, ComponentDef> = {
    Answer: {
      visual: false, children: "Group keys, 1–4",
      use: "The root, exactly one: the one-sentence answer and its groups.",
      avoid: "Restating the question or the method.",
      props: z.strictObject({
        lead: Rich.describe("The direct answer in at most 40 words, cited."),
        verdict: z.enum(VERDICTS).optional().describe("How settled the answer is."),
      }),
    },
    Group: {
      visual: false, children: "Claim and visual keys, at most 6, at most 1 visual",
      use: "A section whose title states its conclusion.",
      avoid: "Topic labels such as Background or Overview.",
      props: z.strictObject({ title: z.string().describe("Sentence case, at most 8 words, says the conclusion.") }),
    },
    Claim: {
      visual: false,
      use: "One cited sentence. The default: prefer a Claim over any visual.",
      avoid: "A sentence with no marker.",
      props: z.strictObject({
        text: Rich.describe("One sentence with at least one marker."),
        confidence: resolved ? z.enum(DATUM_CONFIDENCE) : z.enum(["high", "medium", "low"]),
        reason: z.string().optional().describe("At most 6 words: 3 sources, 2 primary."),
      }),
    },
    Stat: {
      visual: true,
      use: "One notable number that is a claim's evidence: a share, a threshold, a record.",
      avoid: "A number that only makes sense next to others (BarCompare), or a row of Stats.",
      props: z.strictObject({
        value: Datum,
        label: z.string().describe("What it counts, at most 8 words."),
        of: Datum.optional().describe("For a share: 80% of 50 listings."),
        context: Datum.optional().describe("A comparison number: vs 25% at Walmart+."),
        caption,
      }),
    },
    RangeCompare: {
      visual: true,
      use: "How big? when sources give different numbers or scopes for one measure, points mixed with ranges.",
      avoid: "Rows that measure different things, or a single estimate (Stat).",
      props: z.strictObject({
        measure: z.string().describe("Revenue lift from personalization"),
        rows: z.array(z.strictObject({ label: z.string(), value: Datum, group: z.string().optional() }))
          .describe("2–8 rows, one unit."),
        reference: labelled.optional().describe("A vertical rule, such as a benchmark."),
        axis: z.strictObject({ min: z.number().optional(), max: z.number().optional() }).optional(),
        caption,
      }),
    },
    BarCompare: {
      visual: true,
      use: "Rank or size peers on one measure.",
      avoid: "Time series, or a measure that is really different metrics (run rate vs full year).",
      props: z.strictObject({
        measure: z.string(),
        bars: z.array(labelled).describe("3–8 bars, one unit, as_of on every bar; fill scope honestly."),
        sort: z.enum(["desc", "asc", "given"]).optional(),
        caption,
        ...onlyResolved({ mixed_basis: z.strictObject({ as_of: z.boolean(), scope: z.boolean() }) }),
      }),
    },
    ConflictSplit: {
      visual: true,
      use: "An open disagreement the run could not settle: 2–3 positions side by side.",
      avoid: "False balance: a settled objection is a Claim.",
      props: z.strictObject({
        question: z.string().describe("The disputed point, as a question."),
        sides: z.array(z.strictObject({
          label: z.string(),
          headline: z.union([Datum, z.string()]).describe("The side's figure (a datum) or a short phrase."),
          summary: Rich,
          source_type: z.enum(SOURCE_TYPES).describe("What kind of source backs this side."),
          ...onlyResolved({ tier_mix: TierMix }),
        })).describe("2–3 sides."),
        leaning: z.strictObject({ side: z.number().int().describe("0-based side index"), why: Rich }).optional()
          .describe("Only if the run actually leans."),
        settle: z.string().optional().describe("What evidence would settle it."),
        caption,
      }),
    },
    SourceMix: {
      visual: false,
      use: "Where the evidence comes from. You place it; the engine counts. At most once.",
      avoid: "Writing any count yourself.",
      props: z.strictObject({
        scope: z.enum(["answer", "group"]),
        by: z.enum(["type", "tier"]).describe("type: primary, vendor, seo, academic, news. tier: how well quotes verified."),
        caption: Rich.optional(),
        ...onlyResolved({
          counts: z.array(z.strictObject({ key: z.string(), n: z.number().int() })),
          total: z.number().int(),
        }),
      }),
    },
    EvidenceTable: {
      visual: true,
      use: "Comparable data that is not chartable: mixed units, too few rows.",
      avoid: "Qualitative pros and cons.",
      props: z.strictObject({
        columns: z.array(z.strictObject({ key: z.string(), label: z.string(), align: z.enum(["start", "end"]).optional() }))
          .describe("At most 6."),
        rows: z.array(z.record(z.string(), z.union([Datum, z.string()]))).describe("At most 12; each cell a datum or cited text."),
        caption,
      }),
    },
  };

  const elementSchemas: Record<string, z.ZodObject> = {};
  for (const [type, component] of Object.entries(components)) {
    elementSchemas[type] = z.strictObject({
      type: z.literal(type),
      props: component.props,
      ...(component.children ? { children: z.array(z.string()) } : {}),
    });
  }
  const Element = z.discriminatedUnion("type", Object.values(elementSchemas) as [z.ZodObject, ...z.ZodObject[]])
    .meta({ id: name("Element") });
  const Spec = z.strictObject({
    v: z.literal(1),
    root: z.string(),
    elements: z.record(z.string(), Element),
  }).meta({ id: name("Spec") });

  return { Datum, components, elementSchemas, Element, Spec };
}

export const modelCatalog = build("model");
export const resolvedCatalog = build("resolved");
export const ResolvedSpecSchema = resolvedCatalog.Spec;
export const COMPONENT_TYPES = Object.keys(modelCatalog.components);
export const VISUAL_TYPES = new Set(COMPONENT_TYPES.filter((type) => modelCatalog.components[type]!.visual));
export const CHART_TYPES = new Set(["RangeCompare", "BarCompare"]);
export const PROSE_TYPES = new Set(["Answer", "Group", "Claim"]);

export interface Element {
  type: string;
  props: Record<string, any>;
  children?: string[];
}

export interface Spec {
  v: number;
  root: string;
  elements: Record<string, Element>;
}

export type ResolvedSpec = z.infer<typeof ResolvedSpecSchema>;

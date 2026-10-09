// QVS v1 catalog: Zod is the single source of truth for the spec SHAPE (types, enums, required keys,
// strictness). Counts, cross-references and citation existence are semantic checks in validate.ts, so
// they get named issue codes and can be auto-repaired (a Zod `.min(3)` failure can't be downgraded to a Stat).
// Two variants are built from one factory: ModelSpec (what the model writes) and ResolvedSpec (+ ⚙ engine fields).
import { z } from "zod";

// ---------- shared leaf types (identical in both modes) ----------
export const CiteId = z.string().regex(/^[A-Za-z][A-Za-z0-9_-]{0,31}$/)
  .meta({ id: "CiteId", description: "A citation id from this run's resolved citations, e.g. \"a2c4\"." });
export const Rich = z.string()
  .meta({ id: "Rich", description: "Text with citation markers in the notes' syntax: \"Grocery lift is 1–2%[^a2c17].\"" });
export const Unit = z.enum(["pct", "pp", "usd", "count", "ratio", "score", "days", "months", "items"])
  .meta({ id: "Unit", description: "pct = percent (69 means 69%); pp = percentage points; usd with scale k/M/B." });
export const SourceKind = z.enum(["primary-research", "filing", "company-reported", "press", "vendor", "seo", "academic", "regulator", "data-panel"])
  .meta({ id: "SourceKind", description: "What kind of source backs a position." });
export const Tier = z.enum(["supported", "close", "unsupported", "unresolved"])
  .meta({ id: "Tier", description: "⚙ Citation tier (CitationTier in the app). Worst across cite[]." });
export const Trust = z.strictObject({
  tier: Tier,
  numberInQuote: z.boolean().describe("The value (or lo and hi) appears in a cited quote after unit normalisation."),
  confidence: z.enum(["high", "medium", "low", "unverified"]),
}).meta({ id: "Trust", description: "⚙ Engine-attached provenance of one datum. The model never writes this." });
export const TierMix = z.strictObject({ supported: z.int(), close: z.int(), unsupported: z.int(), unresolved: z.int() })
  .meta({ id: "TierMix", description: "⚙ Counts of citation tiers." });

const datumShape = {
  v: z.number().optional().describe("Point value. Either v, or both lo and hi."),
  lo: z.number().optional().describe("Range low."),
  hi: z.number().optional().describe("Range high."),
  unit: Unit,
  scale: z.enum(["k", "M", "B"]).optional().describe("For usd/count: 2.1 + \"B\" → $2.1B."),
  cmp: z.enum(["gt", "lt", "approx"]).optional().describe("The quote's own hedging: \">$1B\" → gt, \"~20%\" → approx."),
  basis: z.enum(["reported", "derived", "estimate"]).describe("reported = the number is in the quote; derived = computed (cite every input); estimate = the run's judgement, drawn hatched."),
  cite: z.array(CiteId).min(1).describe("≥1 citation id. Required."),
  asOf: z.string().optional().describe("\"2024\", \"2026-Q1\", \"2025-10\". Required in BarCompare."),
  scope: z.string().optional().describe("\"grocery\", \"US online grocery shoppers\"."),
  label: z.string().optional().describe("Short display label, ≤ 32 chars."),
};
// Not representable in JSON Schema as a Zod refine — emit-schema.ts re-adds it as `oneOf` via `override`.
export const datumShapeOk = (d: { v?: number; lo?: number; hi?: number }) => {
  const [V, L, H] = [d.v !== undefined, d.lo !== undefined, d.hi !== undefined];
  return (V && !L && !H) || (!V && L && H && d.lo! <= d.hi!);
};
const datumCheck = { message: "Datum needs either v, or both lo and hi (lo ≤ hi)", params: { code: "datum_shape" } };

export type Mode = "model" | "resolved";
export type ComponentDef = { props: z.ZodType; description: string; visual: boolean; children?: string };

function build(mode: Mode) {
  const R = mode === "resolved";
  const id = (n: string) => (R ? `${n}Resolved` : n);
  const ifR = <T extends Record<string, z.ZodType>>(shape: T) => (R ? shape : ({} as T));

  const Datum = z.strictObject({ ...datumShape, ...ifR({ trust: Trust }) })
    .refine(datumShapeOk, datumCheck)
    .meta({ id: id("Datum"), description: "A cited number. There is no bare-number prop anywhere in the catalog." });
  const caption = Rich.describe("One cited sentence: the one thing the picture shows. Also the a11y label and markdown fallback.");
  const labelled = z.strictObject({ label: z.string(), value: Datum });

  const RangeCompare = z.strictObject({
    measure: z.string().describe("\"Revenue lift from personalization\""),
    rows: z.array(z.strictObject({ label: z.string(), value: Datum, group: z.string().optional() })).describe("2–8 rows; a row may be a point or a range. Same measure, same unit."),
    reference: labelled.optional().describe("A vertical rule, e.g. the benchmark."),
    axis: z.strictObject({ min: z.number().optional(), max: z.number().optional(), log: z.boolean().optional() }).optional(),
    caption,
  });
  const BarCompare = z.strictObject({
    measure: z.string(),
    bars: z.array(labelled).describe("3–8 bars, one unit, asOf on every bar. Fill scope honestly (run rate vs full year)."),
    sort: z.enum(["desc", "asc", "given"]).optional().describe("default desc"),
    caption,
    ...ifR({ mixedBasis: z.strictObject({ asOf: z.boolean(), scope: z.boolean() }).describe("⚙ bars differ in asOf/scope → amber 'not like-for-like' note") }),
  });
  const TrendLine = z.strictObject({
    measure: z.string(),
    x: z.strictObject({ kind: z.enum(["time", "ordinal"]), label: z.string() }),
    series: z.array(z.strictObject({
      label: z.string(),
      points: z.array(z.strictObject({ x: z.union([z.string(), z.number()]), y: Datum })).describe("≥3 cited points; never interpolate."),
    })).describe("1–4 series, one unit."),
    reference: labelled.optional().describe("Horizontal rule."),
    caption,
  });
  const panel = <T extends z.ZodObject>(p: T) => z.array(z.strictObject({ title: z.string(), props: p.omit({ caption: true }) }));
  const SmallMultiples = z.discriminatedUnion("of", [
    z.strictObject({ of: z.literal("TrendLine"), panels: panel(TrendLine).describe("2–6 panels, shared scale"), caption }),
    z.strictObject({ of: z.literal("BarCompare"), panels: panel(BarCompare).describe("2–6 panels, shared scale"), caption }),
    z.strictObject({ of: z.literal("RangeCompare"), panels: panel(RangeCompare).describe("2–6 panels, shared scale"), caption }),
  ]);

  const components: Record<string, ComponentDef> = {
    Answer: {
      visual: false, children: "Group[] (1–4)",
      description: "Root, exactly one. The one-sentence answer plus 1–4 groups.",
      props: z.strictObject({
        lead: Rich.describe("The one-sentence answer, ≤ 40 words, cited."),
        verdict: z.enum(["settled", "leaning", "contested", "inconclusive"]).optional().describe("Drives the header mark."),
      }),
    },
    Group: {
      visual: false, children: "(Claim | visual)[] (≤ 6, ≤ 2 visuals)",
      description: "A section whose title states its conclusion.",
      props: z.strictObject({ title: z.string().describe("Sentence case, ≤ 8 words, says the conclusion.") }),
    },
    Claim: {
      visual: false,
      description: "One cited sentence. The default: prefer a Claim over any picture.",
      props: z.strictObject({
        text: Rich.describe("One sentence with ≥ 1 marker."),
        confidence: (R ? z.enum(["high", "medium", "low", "unverified"]).describe("⚙ floored to unverified when no cited quote resolves")
          : z.enum(["high", "medium", "low"])),
        reason: z.string().optional().describe("≤ 6 words, e.g. \"3 sources, 2 primary\"."),
      }),
    },
    Stat: {
      visual: true,
      description: "One notable number that is a claim's evidence (a share, threshold, record). Not for a number that only makes sense next to others (BarCompare), and never ≥ 3 Stats in a row.",
      props: z.strictObject({
        value: Datum.describe("The number."),
        label: z.string().describe("What it counts, ≤ 8 words."),
        of: Datum.optional().describe("For a share: \"80% of 50 listings\". Turns on the share meter."),
        context: Datum.optional().describe("A comparison number (\"vs 25% Walmart+\")."),
        caption,
      }),
    },
    RangeCompare: {
      visual: true, props: RangeCompare,
      description: "\"How big?\" when sources give different numbers or scopes, points mixed with ranges. The main ROI picture. Not when rows measure different things, not for one estimate (Stat).",
    },
    BarCompare: {
      visual: true, props: BarCompare,
      description: "Rank or size peers on ONE measure. Not for time (TrendLine), not when the 'same measure' is really different metrics.",
    },
    TrendLine: {
      visual: true, props: TrendLine,
      description: "A curve the sources report point by point (retention, cost over years). No interpolation, one unit.",
    },
    SmallMultiples: {
      visual: true, props: SmallMultiples,
      description: "Rare. The same small chart per entity when one chart would need > 4 series.",
    },
    ConflictSplit: {
      visual: true,
      description: "Every open conflict the run reports: 2–3 positions side by side. Not for false balance: a resolved objection is a Claim.",
      props: z.strictObject({
        question: z.string().describe("The disputed point as a question."),
        sides: z.array(z.strictObject({
          label: z.string(),
          headline: z.union([Datum, z.string()]).describe("The side's headline figure (Datum) or a short phrase."),
          summary: Rich,
          sourceKind: SourceKind,
          ...ifR({ tierMix: TierMix }),
        })).describe("2–3 sides."),
        leaning: z.strictObject({ side: z.int().describe("0-based index into sides"), why: Rich }).optional().describe("Only if the run actually leans; omitted = open."),
        settle: z.string().optional().describe("What evidence would resolve it."),
        caption,
      }),
    },
    SourceMix: {
      visual: false,
      description: "Where the evidence comes from. You only place it; the engine fills the counts. At most once per answer.",
      props: z.strictObject({
        scope: z.union([z.literal("answer"), z.literal("group"), z.array(CiteId)]).describe("What to count."),
        by: z.enum(["kind", "tier"]).describe("Source kind, or verification tier."),
        caption: Rich.optional(),
        ...ifR({ counts: z.array(z.strictObject({ key: z.string(), n: z.int() })).describe("⚙ by=kind: distinct sources per kind; by=tier: citations per tier.") }),
      }),
    },
    EvidenceTable: {
      visual: true,
      description: "Comparable but not chartable data (mixed units, ≤ 2 rows per kind); the downgrade target. Not for qualitative pros/cons.",
      props: z.strictObject({
        columns: z.array(z.strictObject({ key: z.string(), label: z.string(), align: z.enum(["start", "end"]).optional() })).describe("≤ 6"),
        rows: z.array(z.record(z.string(), z.union([Datum, Rich]))).describe("≤ 12; each cell a Datum or Rich text, keyed by column key."),
        caption,
      }),
    },
    Timeline: {
      visual: true,
      description: "Dated or ordered events when order/spacing is the argument. Not for < 3 events or unsourced dates (the year must be in the quote).",
      props: z.strictObject({
        axis: z.enum(["date", "ordinal"]).describe("ordinal = a sequence without trustworthy dates."),
        events: z.array(z.strictObject({
          at: z.string().describe("\"2022-03\" or an ordinal label."),
          title: z.string(),
          detail: Rich.optional(),
          kind: z.string().optional().describe("A key from kinds."),
          cite: z.array(CiteId).min(1),
          ...ifR({ tier: Tier, dateInQuote: z.boolean().optional().describe("⚙ axis=date only: the year is in a cited quote") }),
        })).describe("3–12 events."),
        kinds: z.array(z.strictObject({ key: z.string(), label: z.string() })).optional().describe("≤ 4 kinds."),
        caption,
      }),
    },
    DecisionMatrix: {
      visual: true,
      description: "\"Which approach?\" when the run compared options. Ratings are ordinal, never fake scores; every non-null cell is cited.",
      props: z.strictObject({
        options: z.array(z.strictObject({ key: z.string(), label: z.string() })).describe("2–6 rows."),
        criteria: z.array(z.strictObject({ key: z.string(), label: z.string(), better: z.enum(["high", "low"]).optional() })).describe("2–6 columns."),
        cells: z.array(z.strictObject({
          option: z.string(), criterion: z.string(),
          rating: z.int().min(-2).max(2).nullable().describe("-2..2 = how well the option does; null = the run found nothing (never 0)."),
          note: z.string().optional(),
          cite: z.array(CiteId).describe("Required (≥1) when rating is not null."),
          ...ifR({ tier: Tier.optional() }),
        })),
        recommend: z.strictObject({ option: z.string(), why: Rich }).optional(),
        caption,
      }),
    },
    Quadrant: {
      visual: true,
      description: "Only when both coordinates of every point are cited measurements. Never a framework with made-up dots; estimate-basis points are rejected.",
      props: z.strictObject({
        x: z.strictObject({ label: z.string(), split: z.union([Datum, z.number()]) }),
        y: z.strictObject({ label: z.string(), split: z.union([Datum, z.number()]) }),
        regions: z.tuple([z.string(), z.string(), z.string(), z.string()]).describe("Top-left, top-right, bottom-left, bottom-right."),
        points: z.array(z.strictObject({ label: z.string(), x: Datum, y: Datum })).describe("4–20"),
        caption,
      }),
    },
    ArgumentMap: {
      visual: true,
      description: "In a contested answer: whether the thesis survives the contradicting evidence. Not decoration in a settled answer.",
      props: z.strictObject({
        thesis: Rich,
        nodes: z.array(z.strictObject({
          id: z.string(), text: z.string(),
          stance: z.enum(["supports", "contradicts", "qualifies"]),
          cite: z.array(CiteId).min(1),
          parent: z.string().optional().describe("id of another node; omitted = attaches to the thesis."),
          ...ifR({ tier: Tier }),
        })).describe("3–9 nodes."),
        caption,
      }),
    },
  };

  const elementSchemas: Record<string, z.ZodObject> = {};
  for (const [type, c] of Object.entries(components)) {
    elementSchemas[type] = z.strictObject({
      type: z.literal(type),
      props: c.props,
      ...(c.children ? { children: z.array(z.string()).describe(c.children) } : {}),
    });
  }
  const Element = z.discriminatedUnion("type", Object.values(elementSchemas) as [z.ZodObject, ...z.ZodObject[]])
    .meta({ id: id("Element") });
  const Spec = z.strictObject({
    v: z.literal(1),
    root: z.string().describe("Key of the Answer element."),
    elements: z.record(z.string(), Element),
  }).meta({ id: R ? "QVSResolvedSpec" : "QVSModelSpec", description: `QVS v1 ${mode} spec: a flat map of elements; parents list children by key.` });

  return { Datum, components, elementSchemas, Element, Spec };
}

export const model = build("model");
export const resolved = build("resolved");
export const ModelSpec = model.Spec;
export const ResolvedSpec = resolved.Spec;
export const COMPONENT_TYPES = Object.keys(model.components);
export const VISUAL_TYPES = new Set(COMPONENT_TYPES.filter((t) => model.components[t]!.visual));

export type ModelSpecT = z.infer<typeof ModelSpec>;
export type ResolvedSpecT = z.infer<typeof ResolvedSpec>;
export type DatumT = z.infer<typeof model.Datum> & { trust?: z.infer<typeof Trust> };
export type TierT = z.infer<typeof Tier>;
/** Loose element shape used by the walkers (validate/resolve/repair operate on parsed or raw JSON). */
export type El = { type: string; props: Record<string, any>; children?: string[] };
export type SpecLike = { v: number; root: string; elements: Record<string, El> };

// ---------- citation registry (PROTOCOL v2 resolved citations + documents) ----------
export type Citation = { id: string; source_id: string; quote: string; match: "exact" | "normalized" | "fuzzy" | "unresolved"; start?: number; end?: number; page?: number };
export type Registry = {
  grounding?: "captured" | "none";
  citations: Citation[];
  unsupported_citations?: string[];
  documents?: { source_id: string; url?: string; title?: string; kind?: string }[];
};

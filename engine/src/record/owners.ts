import { VISUAL_TYPES } from "../answer/catalog.js";
import { markedSentences } from "../validate.js";
import type { RunRecord } from "./schema.js";

export function sentenceOwners(spec: NonNullable<RunRecord["answer"]>["spec"]): Map<string, string> {
  const owners = new Map<string, string>();
  for (const [key, element] of Object.entries(spec.elements) as [string, any][]) {
    const text = element.type === "Answer" ? element.props.lead
      : element.type === "Claim" ? element.props.text
      : VISUAL_TYPES.has(element.type) || element.type === "SourceMix" ? element.props.caption : undefined;
    if (typeof text !== "string") continue;
    for (const { claim } of markedSentences(text)) if (!owners.has(claim)) owners.set(claim, key);
  }
  return owners;
}

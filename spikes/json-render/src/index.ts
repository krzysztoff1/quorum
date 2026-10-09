// Engine-facing surface of the spike (what would move into engine/src/viz/).
export * from "./catalog";
export { validateSpec, parseElement, type Issue } from "./validate";
export { resolveSpec, citationTier } from "./resolve";
export { SpecStream, compileJsonl, show } from "./stream";
export { repairSpec, buildRepairPrompt } from "./repair";
export { catalogPrompt } from "./prompt";

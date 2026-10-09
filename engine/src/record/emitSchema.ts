import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { questionJsonSchema, runRecordJsonSchema } from "./schema.js";
import { swiftTypes } from "./swiftTypes.js";

const REPO = fileURLToPath(new URL("../../../", import.meta.url));

export interface Artifact {
  path: string;
  content: string;
}

export function generatedArtifacts(): Artifact[] {
  const run = runRecordJsonSchema();
  const question = questionJsonSchema();
  return [
    { path: join(REPO, "schema", "run.schema.json"), content: JSON.stringify(run, null, 2) + "\n" },
    { path: join(REPO, "schema", "question.schema.json"), content: JSON.stringify(question, null, 2) + "\n" },
    { path: join(REPO, "Sources", "QuorumCore", "RunRecord.generated.swift"), content: swiftTypes([run, question]) },
  ];
}

if (import.meta.main) {
  for (const artifact of generatedArtifacts()) {
    mkdirSync(dirname(artifact.path), { recursive: true });
    writeFileSync(artifact.path, artifact.content);
    process.stdout.write(`wrote ${artifact.path}\n`);
  }
}

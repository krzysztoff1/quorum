import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const FIXTURES_DIR = fileURLToPath(new URL("../fixtures/", import.meta.url));

export interface FixtureOptions {
  dir?: string;
  update?: boolean;
}

export function updatingFixtures(): boolean {
  return process.env.UPDATE_FIXTURES === "1";
}

export function matchFixture(name: string, actual: string, options: FixtureOptions = {}): void {
  const path = join(options.dir ?? FIXTURES_DIR, name);
  if (options.update ?? updatingFixtures()) {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, actual);
    return;
  }
  const expected = existsSync(path) ? readFileSync(path, "utf8") : undefined;
  if (expected === actual) return;
  throw new Error(describeDrift(name, expected, actual));
}

function describeDrift(name: string, expected: string | undefined, actual: string): string {
  const remedy = "Review the difference, then re-record deliberately with UPDATE_FIXTURES=1 (bun run fixtures:update).";
  if (expected === undefined) return `Fixture ${name} has never been recorded. ${remedy}`;
  const left = expected.split("\n");
  const right = actual.split("\n");
  const line = left.findIndex((text, index) => text !== right[index]);
  const at = line === -1 ? Math.min(left.length, right.length) : line;
  return `Fixture ${name} differs from the recording, first at line ${at + 1}. ${remedy}`;
}

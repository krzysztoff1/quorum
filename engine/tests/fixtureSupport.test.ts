import { describe, it, expect } from "vitest";
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { matchFixture } from "./fixtureSupport.js";

function directory(): string {
  return mkdtempSync(join(tmpdir(), "fixture-support-"));
}

describe("matchFixture", () => {
  it("passes when the recording equals the stored fixture", () => {
    const dir = directory();
    writeFileSync(join(dir, "run.ndjson"), "a\nb\n");
    expect(() => matchFixture("run.ndjson", "a\nb\n", { dir, update: false })).not.toThrow();
  });

  it("fails, leaving the stored fixture untouched, when the recording differs", () => {
    const dir = directory();
    writeFileSync(join(dir, "run.ndjson"), "old\n");
    expect(() => matchFixture("run.ndjson", "new\n", { dir, update: false })).toThrow(/UPDATE_FIXTURES=1/);
    expect(readFileSync(join(dir, "run.ndjson"), "utf8")).toBe("old\n");
  });

  it("fails for a fixture that was never recorded instead of silently creating it", () => {
    const dir = directory();
    expect(() => matchFixture("run.ndjson", "new\n", { dir, update: false })).toThrow(/UPDATE_FIXTURES=1/);
    expect(existsSync(join(dir, "run.ndjson"))).toBe(false);
  });

  it("rewrites the fixture only when told to update", () => {
    const dir = directory();
    writeFileSync(join(dir, "run.ndjson"), "old\n");
    matchFixture("run.ndjson", "new\n", { dir, update: true });
    expect(readFileSync(join(dir, "run.ndjson"), "utf8")).toBe("new\n");
  });

  it("names the fixture and the first differing line in its failure", () => {
    const dir = directory();
    writeFileSync(join(dir, "run.ndjson"), "same\nold\n");
    expect(() => matchFixture("run.ndjson", "same\nnew\n", { dir, update: false })).toThrow(/run\.ndjson.*line 2/s);
  });
});

import { describe, it, expect } from "vitest";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "../src/args.js";
import { runReplay } from "../src/replay.js";

const FIXTURES = fileURLToPath(new URL("../fixtures/", import.meta.url));
const ENTRY = fileURLToPath(new URL("../src/index.ts", import.meta.url));
const MOCK_RUN = join(FIXTURES, "mock-run.ndjson");

function scratch(): string {
  return mkdtempSync(join(tmpdir(), "quorum-replay-"));
}

function fixtureWith(lines: string[], sources: Record<string, string> = {}): string {
  const dir = scratch();
  const path = join(dir, "tiny.ndjson");
  writeFileSync(path, lines.join("\n") + "\n");
  if (Object.keys(sources).length > 0) {
    const sourcesDir = join(dir, "tiny.sources");
    mkdirSync(sourcesDir);
    for (const [name, body] of Object.entries(sources)) writeFileSync(join(sourcesDir, name), body);
  }
  return path;
}

const noSleep = async () => {};

describe("parseArgs for replay", () => {
  it("reads the fixture and the pacing off the run command", () => {
    const args = parseArgs(["run", "--replay", "fixtures/mock-run.ndjson", "--replay-delay-ms", "25"]);
    expect(args.command).toBe("run");
    expect(args.replay).toBe("fixtures/mock-run.ndjson");
    expect(args.replayDelayMs).toBe(25);
  });

  it("is a plain run when no fixture is named", () => {
    expect(parseArgs(["run"]).replay).toBeUndefined();
  });
});

describe("runReplay", () => {
  it("emits every recorded line, in order", async () => {
    const path = fixtureWith(['{"type":"phase","phase":"planning"}', '{"type":"phase","phase":"done"}']);
    const lines: string[] = [];
    await runReplay({ fixturePath: path, delayMs: 0, sink: (l) => lines.push(l), sleep: noSleep });
    expect(lines).toEqual(['{"type":"phase","phase":"planning"}\n', '{"type":"phase","phase":"done"}\n']);
  });

  it("waits between lines so the app can watch the run move", async () => {
    const path = fixtureWith(['{"type":"a"}', '{"type":"b"}', '{"type":"c"}']);
    const waits: number[] = [];
    await runReplay({ fixturePath: path, delayMs: 140, sink: () => {}, sleep: async (ms) => { waits.push(ms); } });
    expect(waits).toEqual([140, 140, 140]);
  });

  it("copies the recorded source snapshots into the run's evidence directory without overwriting", async () => {
    const path = fixtureWith(['{"type":"phase","phase":"done"}'], { "s1.md": "recorded", "s2.md": "recorded" });
    const evidenceDir = join(scratch(), "evidence");
    mkdirSync(join(evidenceDir, "sources"), { recursive: true });
    writeFileSync(join(evidenceDir, "sources", "s1.md"), "already captured");
    await runReplay({ fixturePath: path, evidenceDir, delayMs: 0, sink: () => {}, sleep: noSleep });
    expect(readdirSync(join(evidenceDir, "sources")).sort()).toEqual(["s1.md", "s2.md"]);
    expect(readFileSync(join(evidenceDir, "sources", "s1.md"), "utf8")).toBe("already captured");
    expect(readFileSync(join(evidenceDir, "sources", "s2.md"), "utf8")).toBe("recorded");
  });

  it("writes no evidence when the run has no evidence directory, or the fixture has no snapshots", async () => {
    const withSources = fixtureWith(['{"type":"phase","phase":"done"}'], { "s1.md": "recorded" });
    await runReplay({ fixturePath: withSources, delayMs: 0, sink: () => {}, sleep: noSleep });
    const bare = fixtureWith(['{"type":"phase","phase":"done"}']);
    const evidenceDir = join(scratch(), "evidence");
    await runReplay({ fixturePath: bare, evidenceDir, delayMs: 0, sink: () => {}, sleep: noSleep });
    expect(existsSync(join(evidenceDir, "sources"))).toBe(false);
  });

  it("stops emitting once the run is aborted", async () => {
    const path = fixtureWith(['{"type":"a"}', '{"type":"b"}', '{"type":"c"}']);
    const controller = new AbortController();
    const lines: string[] = [];
    await runReplay({
      fixturePath: path, delayMs: 1, signal: controller.signal,
      sink: (l) => { lines.push(l); controller.abort(); }, sleep: noSleep,
    });
    expect(lines).toHaveLength(1);
  });

  it("refuses a fixture that is not there instead of replaying nothing", async () => {
    await expect(runReplay({ fixturePath: join(scratch(), "missing.ndjson"), delayMs: 0, sink: () => {}, sleep: noSleep }))
      .rejects.toThrow(/replay fixture/i);
  });
});

describe("quorum-engine run --replay, end to end", () => {
  it("streams the recorded run on stdout and lays its sources into the evidence directory", () => {
    const evidenceDir = join(scratch(), "evidence");
    const config = JSON.stringify({ question: "ignored by a replay", evidenceDir });
    const result = spawnSync("bun", [ENTRY, "run", "--replay", MOCK_RUN, "--replay-delay-ms", "0"],
      { input: config + "\n", encoding: "utf8", timeout: 30_000 });

    expect(result.status).toBe(0);
    const recorded = readFileSync(MOCK_RUN, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
    const replayed = result.stdout.split("\n").filter(Boolean).map((l) => JSON.parse(l));
    expect(replayed).toEqual(recorded);
    expect(replayed[0]).toMatchObject({ type: "run_start", protocol_version: 5 });
    expect(replayed.at(-1).type).toBe("run_result");
    expect(readdirSync(join(evidenceDir, "sources")).length).toBeGreaterThan(0);
  });

  it("exits on its own while the app still holds stdin open", async () => {
    const child = spawn("bun", [ENTRY, "run", "--replay", MOCK_RUN, "--replay-delay-ms", "0"], { stdio: ["pipe", "ignore", "ignore"] });
    child.stdin.write(JSON.stringify({ question: "q" }) + "\n");
    const exited = await new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => { child.kill(); resolve(false); }, 5_000);
      child.on("exit", () => { clearTimeout(timer); resolve(true); });
    });
    expect(exited).toBe(true);
  });

  it("fails loudly with a missing fixture", () => {
    const result = spawnSync("bun", [ENTRY, "run", "--replay", "/no/such/fixture.ndjson", "--replay-delay-ms", "0"],
      { input: JSON.stringify({ question: "q" }) + "\n", encoding: "utf8", timeout: 30_000 });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toMatch(/replay fixture/i);
  });
});

describe("runReplay into a brain folder", () => {
  it("writes the record a live run would, and names the run directory on run_start", async () => {
    const brainDir = scratch();
    const lines: string[] = [];
    let ids = 0;
    await runReplay({
      fixturePath: MOCK_RUN, delayMs: 0, sink: (l) => lines.push(l), sleep: noSleep,
      brainDir, question: "Does prompt caching pay for a chat product?",
      now: () => Date.parse("2026-10-09T10:00:00.000Z"), newId: () => ["QREPLAY", "RREPLAY"][ids++]!,
    });
    const start = JSON.parse(lines[0]!);
    const runDir = join(brainDir, "questions", "QREPLAY", "runs", "RREPLAY");
    expect(start).toMatchObject({ type: "run_start", run_id: "RREPLAY", question_id: "QREPLAY", run_dir: runDir });
    const record = JSON.parse(readFileSync(join(runDir, "run.json"), "utf8"));
    expect(record).toMatchObject({ id: "RREPLAY", status: "inconclusive", answer: { task_id: "reconciliation" } });
    expect(record.checks.map((c: { id: string }) => c.id)).toContain("stats");
    expect(readdirSync(join(runDir, "evidence", "sources")).length).toBeGreaterThan(0);
    expect(existsSync(join(runDir, "events.ndjson"))).toBe(true);
    expect(readdirSync(join(brainDir, "answers"))).toHaveLength(1);
  });
});

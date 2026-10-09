import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { checkRunDir, E2E_BUILD, engineBinary, runEngine, serveFixtureSite, type EngineRun, type FixtureSite } from "./harness.js";

let binary: string;
let site: FixtureSite;
let happy: EngineRun;

beforeAll(async () => {
  binary = engineBinary();
  site = await serveFixtureSite();
  happy = await runEngine({ binary, baseUrl: site.baseUrl });
});

afterAll(async () => {
  await site.close();
});

const result = () => happy.events.at(-1);
const ofType = (type: string) => happy.events.filter((e) => e.type === type);

describe("the compiled engine, a scripted claude CLI and a local web, end to end", () => {
  it("plans, researches, grounds, validates and finishes complete with a clean exit", () => {
    expect(happy.exitCode, happy.stderr).toBe(0);
    expect(result()).toMatchObject({ type: "run_result", status: "complete", grounding: "captured" });
    expect(ofType("plan")[0].angles).toHaveLength(2);
    expect(ofType("phase").map((p) => p.phase)).toEqual(
      expect.arrayContaining(["planning", "researching", "synthesizing", "grounding", "validating", "done"]),
    );
  });

  it("stamps the run with the build that was compiled into the binary", () => {
    expect(happy.events[0]).toMatchObject({ type: "run_start", build: E2E_BUILD });
  });

  it("captures the pages the angles read as snapshots on disk, over the engine's own fetch", () => {
    const documents = result().documents.filter((d: any) => d.snapshot_path);
    expect(documents.length).toBeGreaterThanOrEqual(2);
    const obligations = documents.find((d: any) => d.url.endsWith("/ai-act-obligations.html"));
    const snapshot = readFileSync(join(happy.runDir, "evidence", obligations.snapshot_path), "utf8");
    expect(snapshot).toContain("technical documentation of the model");
    expect(snapshot).not.toContain("Cookie settings");
    expect(obligations.source_type).toBeDefined();
  });

  it("records the blocked page as a capture failure instead of dropping it", () => {
    expect(result().capture_failures).toEqual(
      expect.arrayContaining([expect.objectContaining({ stage: "fetch", kind: "blocked" })]),
    );
    expect(ofType("capture_failure").length).toBeGreaterThanOrEqual(1);
  });

  it("verifies every quote the answer cites against a snapshot, none left unresolved", () => {
    const synthesis = result().topics.find((t: any) => t.role === "synthesis");
    expect(synthesis.citations.length).toBeGreaterThanOrEqual(2);
    expect(synthesis.citations.map((c: any) => c.match).sort()).toEqual(["exact", "normalized"]);
    expect(synthesis.result).toMatch(/\[\^a1c1\]/);
    expect(synthesis.result).toMatch(/\[\^a2c1\]/);
  });

  it("sweeps the claims against located quotes and runs the critics", () => {
    const validation = result().validation;
    expect(validation.status).toBe("validated");
    expect(validation.rounds[0].claims_checked).toBeGreaterThanOrEqual(2);
    expect(validation.rounds[0].verdicts.every((v: any) => v.verdict === "supported")).toBe(true);
    expect(validation.rounds[0]).toMatchObject({ sweep: "run", critics: "run" });
    expect(validation.spend_usd).toBeGreaterThan(0);
  });

  it("evaluates its own checks and passes them", () => {
    expect(result().checks.failed, JSON.stringify(result().checks.results)).toBe(0);
    expect(result().checks.ok).toBe(true);
  });

  it("keeps events.ndjson that quorum-engine check audits to the same verdict", () => {
    expect(existsSync(join(happy.runDir, "events.ndjson"))).toBe(true);
    const audit = checkRunDir(binary, happy.runDir);
    expect(audit.exitCode, audit.stdout).toBe(0);
    expect(audit.json.ok).toBe(true);
    expect(audit.json.run).toMatchObject({ build: E2E_BUILD, status: "complete", grounding: "captured" });
    expect(audit.json.run.snapshots).toBeGreaterThanOrEqual(2);
  });

  it("reports a snapshot edited after the run as a failed check", () => {
    const documents = result().documents.filter((d: any) => d.snapshot_path);
    appendFileSync(join(happy.runDir, "evidence", documents[0].snapshot_path), " edited afterwards");
    const audit = checkRunDir(binary, happy.runDir);
    expect(audit.exitCode).toBe(1);
    expect(audit.stdout).toMatch(/FAIL\s+snapshots/);
  });
});

describe("a Claude CLI that is not logged in", () => {
  let refused: EngineRun;
  beforeAll(async () => {
    refused = await runEngine({ binary, baseUrl: site.baseUrl, scenario: "logged-out" });
  });

  it("ends the run refused with its own exit code, naming the fix, having spent nothing", () => {
    const final = refused.events.at(-1);
    expect(refused.exitCode).toBe(3);
    expect(final).toMatchObject({ type: "run_result", status: "inconclusive", total_cost_usd: 0 });
    expect(final.refusal).toMatchObject({ kind: "not_logged_in" });
    expect(final.refusal.reason).toContain("/login");
    expect(refused.events.filter((e) => e.type === "topic_result")).toHaveLength(0);
  });

  it("passes its own checks: a refused run is consistent, only incomplete", () => {
    expect(refused.events.at(-1).checks.ok).toBe(true);
  });
});

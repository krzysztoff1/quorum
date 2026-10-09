import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { RunRecordSchema } from "../src/record/schema.js";
import {
  checkRunDir, e2eEnv, engineBinary, engineJson, engineJsonAsync, isAlive, processGroupOf, readEvents, readRecord, serveFixtureSite,
  startAttachedRun, startDetachedRun, waitFor, type FixtureSite,
} from "./harness.js";

let binary: string;
let site: FixtureSite;

beforeAll(async () => {
  binary = engineBinary();
  site = await serveFixtureSite();
});

afterAll(async () => {
  await site.close();
});

const finished = (status: string) => status !== "running";

describe("quorum-engine run --detach", () => {
  it("returns run.created in moments and leaves the run going in its own session, which outlives the caller", async () => {
    const started = await startDetachedRun({ binary, baseUrl: site.baseUrl, delayMs: 700 });

    expect(started.exitCode, started.stderr).toBe(0);
    expect(started.created).toMatchObject({ type: "run.created", protocol_version: 5, dir: started.runDir });
    expect(started.created.question_id).toMatch(/^[0-9A-Z]{26}$/);
    expect(started.runDir).toBe(join(started.brainDir, "questions", started.created.question_id, "runs", started.created.run_id));

    expect(isAlive(started.pid), "the engine outlived the process that started it").toBe(true);
    expect(processGroupOf(started.pid), "it leads its own process group, so cancel reaches the CLI children").toBe(started.pid);
    expect(readRecord(started.runDir)).toMatchObject({ status: "running", pipeline: { pid: started.pid, protocol: 5 } });

    const record = await waitFor("the detached run to finish", () => {
      const current = readRecord(started.runDir);
      return current && finished(current.status) ? current : undefined;
    });
    expect(record.status).toBe("complete");
    expect(RunRecordSchema.safeParse(record).success).toBe(true);
  });

  it("can be re-attached from the record and events.ndjson alone, as a relaunched app does", async () => {
    const started = await startDetachedRun({ binary, baseUrl: site.baseUrl, delayMs: 1200 });

    const listed = engineJson(binary, ["list", "--store", started.brainDir]);
    expect(listed.json).toMatchObject({ type: "run", run_id: started.created.run_id, status: "running", pid: started.pid });

    await waitFor("a progress event in the log", () => readEvents(started.runDir).some((e) => e.type === "run.progress"));
    const seenWhileRunning = readEvents(started.runDir);
    expect(seenWhileRunning[0]).toMatchObject({ type: "run_start", pid: started.pid, protocol_version: 5 });
    expect(seenWhileRunning.at(-1)?.type).not.toBe("run_result");

    await waitFor("the run to finish", () => readEvents(started.runDir).some((e) => e.type === "run_result"));
    const events = readEvents(started.runDir);
    expect(events.at(-1)).toMatchObject({ type: "run_result", status: "complete" });
    expect(events.filter((e) => e.type === "run.progress").at(-1)).toMatchObject({ stage: "answer", stage_index: 5, stage_count: 5 });
    expect(events.some((e) => e.type === "heartbeat" && e.pid === started.pid), "a heartbeat lands in the log every five seconds").toBe(true);

    const after = engineJson(binary, ["list", "--store", started.brainDir]);
    expect(after.json).toMatchObject({ run_id: started.created.run_id, status: "complete" });
    const audit = checkRunDir(binary, started.runDir);
    expect(audit.exitCode, audit.stdout).toBe(0);
  }, 90_000);

  it("is cancelled through the process group: the run winds down to halted and nothing it spawned survives", async () => {
    const started = await startDetachedRun({ binary, baseUrl: site.baseUrl, delayMs: 20_000 });
    await waitFor("the run to be researching", () => readEvents(started.runDir).some((e) => e.type === "phase" && e.phase === "planning"));

    const cancelled = engineJson(binary, ["cancel", started.created.run_id, "--store", started.brainDir]);
    expect(cancelled.exitCode).toBe(0);
    expect(cancelled.json).toEqual({ ok: true, run_id: started.created.run_id, signalled: "group" });

    const record = await waitFor("the cancelled run to wind down", () => {
      const current = readRecord(started.runDir);
      return current && finished(current.status) ? current : undefined;
    }, 30_000);
    expect(record.status).toBe("halted");
    await waitFor("the engine to exit", () => !isAlive(started.pid), 15_000);
    expect(() => process.kill(-started.pid, 0), "no process of the run's group is left").toThrow();
  }, 90_000);

  it("is cancelled when it runs attached to its caller, where the engine leads no group of its own", async () => {
    const attached = startAttachedRun({ binary, baseUrl: site.baseUrl, delayMs: 20_000 });
    const start = await attached.firstEvent;
    expect(start).toMatchObject({ type: "run_start", protocol_version: 5 });

    const cancelled = engineJson(binary, ["cancel", start.run_id, "--store", attached.brainDir]);
    expect(cancelled.json).toEqual({ ok: true, run_id: start.run_id, signalled: "process" });

    const ended = await attached.done;
    expect(ended.exitCode).toBe(0);
    expect(attached.events.at(-1)).toMatchObject({ type: "run_result", status: "halted" });
    expect(readRecord(start.run_dir).status).toBe("halted");
  }, 90_000);

  it("replays a recorded run detached, under the ids and the pid its parent reported", async () => {
    const fixture = join(fileURLToPath(new URL("../fixtures/", import.meta.url)), "mock-run.ndjson");
    const started = await startDetachedRun({ binary, baseUrl: site.baseUrl, replay: fixture });
    expect(started.exitCode, started.stderr).toBe(0);

    const record = await waitFor("the replay to finish", () => {
      const current = readRecord(started.runDir);
      return current && finished(current.status) ? current : undefined;
    });

    expect(record).toMatchObject({ id: started.created.run_id, question_id: started.created.question_id });
    expect(record.pipeline.pid).toBe(started.pid);
    expect(engineJson(binary, ["list", "--store", started.brainDir]).json).toMatchObject({ run_id: started.created.run_id });
  }, 90_000);

  it("refuses to cancel a run that already finished", async () => {
    const started = await startDetachedRun({ binary, baseUrl: site.baseUrl });
    await waitFor("the run to finish", () => {
      const current = readRecord(started.runDir);
      return current && finished(current.status) ? current : undefined;
    });

    const refused = engineJson(binary, ["cancel", started.created.run_id, "--store", started.brainDir]);

    expect(refused.exitCode).toBe(1);
    expect(refused.json).toMatchObject({ ok: false, error: expect.stringContaining("already finished as complete") });
  }, 90_000);

  it("reports a run whose engine was killed as crashed once its heartbeat is stale, and records it", async () => {
    const started = await startDetachedRun({ binary, baseUrl: site.baseUrl, delayMs: 20_000 });
    await waitFor("the run to be live", () => readRecord(started.runDir)?.pipeline?.pid);
    process.kill(-started.pid, "SIGKILL");
    await waitFor("the engine to die", () => !isAlive(started.pid), 10_000);

    const recent = engineJson(binary, ["list", "--store", started.brainDir]);
    expect(recent.json.status, "a fresh heartbeat is not yet a crash").toBe("running");

    const record = readRecord(started.runDir);
    writeFileSync(join(started.runDir, "run.json"), JSON.stringify({
      ...record, pipeline: { ...record.pipeline, heartbeat_at: new Date(Date.now() - 120_000).toISOString() },
    }));

    const listed = engineJson(binary, ["list", "--store", started.brainDir]);
    expect(listed.json).toMatchObject({ run_id: started.created.run_id, status: "crashed" });
    expect(readRecord(started.runDir)).toMatchObject({ status: "crashed", status_note: expect.stringContaining("stopped without finishing") });
  }, 90_000);
});

describe("quorum-engine doctor, scope and migrate", () => {
  it("doctor passes against a scripted CLI that is signed in, naming each check", async () => {
    const store = mkdtempSync(join(tmpdir(), "quorum-e2e-doctor-"));
    const env = e2eEnv("happy", site.baseUrl, { QUORUM_DOCTOR_FETCH_URL: `${site.baseUrl}/ai-act-obligations.html` });

    const report = await engineJsonAsync(binary, ["doctor", "--json", "--store", store], env);

    expect(report.exitCode, report.stdout).toBe(0);
    expect(report.json.checks.map((c: any) => [c.id, c.ok])).toEqual([
      ["claude_cli", true], ["claude_login", true], ["fetch", true], ["store", true], ["migrate", true], ["rate_limit", true],
    ]);
  });

  it("doctor fails, naming the fix, when the CLI is signed out", async () => {
    const store = mkdtempSync(join(tmpdir(), "quorum-e2e-doctor-"));
    const env = e2eEnv("logged-out", site.baseUrl, { QUORUM_DOCTOR_FETCH_URL: `${site.baseUrl}/ai-act-obligations.html` });

    const report = await engineJsonAsync(binary, ["doctor", "--json", "--store", store], env);

    expect(report.exitCode).toBe(1);
    expect(report.json.checks.find((c: any) => c.id === "claude_login")).toMatchObject({ ok: false, fix: expect.stringContaining("sign in") });
  });

  it("scope hands back a brief for the question", () => {
    const scoped = engineJson(binary, ["scope"], { question: "Is Bun faster than Node?" });

    expect(scoped.json).toEqual({
      needs_scoping: false,
      brief: { question: "Is Bun faster than Node?", language: "en", title: "Is Bun faster than Node" },
    });
  });

  it("migrate leaves a current store alone and reports it", () => {
    const store = mkdtempSync(join(tmpdir(), "quorum-e2e-migrate-"));
    mkdirSync(join(store, "questions"), { recursive: true });

    const report = engineJson(binary, ["migrate", "--store", store]);

    expect(report.exitCode).toBe(0);
    expect(report.json).toEqual({ scanned: 0, current: 0, upgraded: [], unknown: [], unreadable: [] });
  });
});

import { describe, expect, it } from "vitest";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startDetached, type DetachDeps } from "../src/detach.js";
import { PROTOCOL_VERSION } from "../src/emitter.js";

interface FakeChild extends EventEmitter {
  pid: number;
  stdin: PassThrough;
  unref: () => void;
}

function harness(onSpawn: (child: FakeChild, command: string, args: string[], options: any, runDir: string) => void) {
  const store = mkdtempSync(join(tmpdir(), "quorum-detach-"));
  const spawned: Array<{ command: string; args: string[]; options: any }> = [];
  const stdinChunks: string[] = [];
  let unrefs = 0;
  const deps: DetachDeps = {
    spawn: ((command: string, args: string[], options: any) => {
      const child = Object.assign(new EventEmitter(), {
        pid: 31337, stdin: new PassThrough(), unref: () => { unrefs += 1; },
      }) as FakeChild;
      child.stdin.on("data", (chunk) => stdinChunks.push(String(chunk)));
      spawned.push({ command, args, options });
      onSpawn(child, command, args, options, join(store, "questions", "QID", "runs", "RID"));
      return child as any;
    }) as any,
    self: (args) => ({ command: "/bin/quorum-engine", args }),
    newId: (() => { const ids = ["QID", "RID"]; return () => ids.shift()!; })(),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, Math.min(ms, 5))),
    now: (() => { let t = 0; return () => (t += 10); })(),
    timeoutMs: 2000,
  };
  return { store, deps, spawned, stdin: () => stdinChunks.join(""), unrefs: () => unrefs };
}

const config = { question: "What is up?", angleCount: 1 } as any;

describe("run --detach", () => {
  it("starts the engine in its own session, hands it the config with the ids it allocated, and reports the run once its record exists", async () => {
    const h = harness((child, _c, _a, _o, runDir) => {
      setTimeout(() => {
        writeFileSync(join(runDir, "run.json"), JSON.stringify({ pipeline: { pid: 31337 } }));
      }, 20);
    });

    const result = await startDetached(config, h.store, {}, h.deps);

    expect(result).toEqual({
      ok: true,
      created: {
        type: "run.created", protocol_version: PROTOCOL_VERSION, question_id: "QID", run_id: "RID",
        dir: join(h.store, "questions", "QID", "runs", "RID"), pid: 31337,
      },
    });
    expect(h.spawned[0]!.command).toBe("/bin/quorum-engine");
    expect(h.spawned[0]!.args).toEqual(["run", "--store", h.store]);
    expect(h.spawned[0]!.options).toMatchObject({ detached: true });
    expect(h.spawned[0]!.options.stdio[0]).toBe("pipe");
    expect(h.spawned[0]!.options.stdio[1]).toBe("ignore");
    expect(JSON.parse(h.stdin())).toMatchObject({ question: "What is up?", angleCount: 1, brainDir: h.store, questionId: "QID", runId: "RID" });
    expect(h.unrefs()).toBe(1);
  });

  it("hands the child any extra arguments, so a replay can be detached like a real run", async () => {
    const h = harness((_child, _c, _a, _o, runDir) => {
      setTimeout(() => writeFileSync(join(runDir, "run.json"), "{}"), 10);
    });

    await startDetached(config, h.store, {}, h.deps, ["--replay", "/fixtures/mock-run.ndjson", "--replay-delay-ms", "5"]);

    expect(h.spawned[0]!.args).toEqual(["run", "--store", h.store, "--replay", "/fixtures/mock-run.ndjson", "--replay-delay-ms", "5"]);
  });

  it("keeps the child's stderr in the run directory, so a crash on the way up leaves something to read", async () => {
    const h = harness((_child, _c, _a, _o, runDir) => {
      setTimeout(() => writeFileSync(join(runDir, "run.json"), "{}"), 10);
    });

    await startDetached(config, h.store, {}, h.deps);

    expect(typeof h.spawned[0]!.options.stdio[2]).toBe("number");
    expect(existsSync(join(h.store, "questions", "QID", "runs", "RID", "engine.stderr.log"))).toBe(true);
  });

  it("reports the child's stderr when it dies before it ever wrote a record", async () => {
    const h = harness((child, _c, _a, _o, runDir) => {
      setTimeout(() => {
        writeFileSync(join(runDir, "engine.stderr.log"), "error: the config was nonsense\n");
        child.emit("exit", 1, null);
      }, 10);
    });

    const result = await startDetached(config, h.store, {}, h.deps);

    expect(result).toMatchObject({ ok: false, error: expect.stringContaining("the config was nonsense") });
    expect(h.unrefs()).toBe(0);
  });

  it("gives up with a clear error when no record appears in time", async () => {
    const h = harness(() => {});
    h.deps.timeoutMs = 50;

    const result = await startDetached(config, h.store, {}, h.deps);

    expect(result).toMatchObject({ ok: false, error: expect.stringMatching(/did not start/i) });
  });
});

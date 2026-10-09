import { describe, expect, it } from "vitest";
import { keepAwake } from "../src/awake.js";

function fakeSpawn() {
  const calls: Array<{ command: string; args: string[]; options: any }> = [];
  let unrefs = 0;
  const spawn = ((command: string, args: string[], options: any) => {
    calls.push({ command, args, options });
    return { unref: () => { unrefs += 1; }, on: () => {} };
  }) as any;
  return { spawn, calls, unrefs: () => unrefs };
}

describe("keeping the Mac awake for a detached run", () => {
  it("asks caffeinate to hold the machine awake for exactly as long as the engine lives", () => {
    const fake = fakeSpawn();

    keepAwake(4242, { platform: "darwin", spawn: fake.spawn });

    expect(fake.calls).toEqual([{ command: "caffeinate", args: ["-i", "-w", "4242"], options: { stdio: "ignore", detached: true } }]);
    expect(fake.unrefs()).toBe(1);
  });

  it("does nothing where there is no caffeinate", () => {
    const fake = fakeSpawn();

    keepAwake(4242, { platform: "linux", spawn: fake.spawn });

    expect(fake.calls).toEqual([]);
  });

  it("carries on when caffeinate cannot be started", () => {
    const throwing = (() => { throw new Error("ENOENT"); }) as any;

    expect(() => keepAwake(4242, { platform: "darwin", spawn: throwing })).not.toThrow();
  });
});

import { describe, it, expect } from "vitest";
import { parseArgs } from "../src/args.js";

describe("parseArgs", () => {
  it("treats a command it does not know as unknown", () => {
    expect(parseArgs(["-p", "research fusion"]).command).toBe("unknown");
  });

  it("detects the mcp-serve subcommand", () => {
    expect(parseArgs(["mcp-serve"]).command).toBe("mcp-serve");
  });

  it("detects the check subcommand with the run directory it audits", () => {
    const parsed = parseArgs(["check", "/runs/2026-10-09", "--json"]);
    expect(parsed.command).toBe("check");
    expect(parsed.runDir).toBe("/runs/2026-10-09");
    expect(parsed.json).toBe(true);
  });

  it("prints check results as text unless asked for json", () => {
    expect(parseArgs(["check", "/runs/x"]).json).toBeFalsy();
  });

  it("detects the export subcommand with the run directory it exports", () => {
    const parsed = parseArgs(["export", "--md", "/brain/questions/q/runs/r", "--out", "/tmp/a.md"]);
    expect(parsed.command).toBe("export");
    expect(parsed.runDir).toBe("/brain/questions/q/runs/r");
    expect(parsed.markdown).toBe(true);
    expect(parsed.out).toBe("/tmp/a.md");
  });

  it("detects the version subcommand the app handshakes with", () => {
    expect(parseArgs(["version"]).command).toBe("version");
  });

  it("ignores unrecognized flags gracefully, keeping known ones", () => {
    const a = parseArgs(["run", "--output-format", "stream-json", "--verbose", "--store", "/brain"]);
    expect(a.command).toBe("run");
    expect(a.store).toBe("/brain");
  });

  it("degrades an invalid replay delay to undefined rather than NaN", () => {
    expect(parseArgs(["run", "--replay-delay-ms", "abc"]).replayDelayMs).toBeUndefined();
  });

  it("supports --flag=value form", () => {
    expect(parseArgs(["run", "--store=/brain"]).store).toBe("/brain");
  });

  it("detects the v5 commands that need no arguments", () => {
    expect(parseArgs(["doctor"]).command).toBe("doctor");
    expect(parseArgs(["doctor", "--json"]).json).toBe(true);
    expect(parseArgs(["scope"]).command).toBe("scope");
  });

  it("takes the store a command works on from --store, in either spelling", () => {
    expect(parseArgs(["list", "--store", "/brain"])).toMatchObject({ command: "list", store: "/brain" });
    expect(parseArgs(["migrate", "--store=/brain"])).toMatchObject({ command: "migrate", store: "/brain" });
    expect(parseArgs(["run", "--store", "/brain", "--detach"])).toMatchObject({ command: "run", store: "/brain", detach: true });
  });

  it("runs attached unless --detach is given", () => {
    expect(parseArgs(["run"]).detach).toBeFalsy();
  });

  it("names the run a cancel is for", () => {
    expect(parseArgs(["cancel", "01RUN", "--store", "/brain"])).toMatchObject({ command: "cancel", runId: "01RUN", store: "/brain" });
    expect(parseArgs(["cancel", "--store", "/brain", "01RUN"]).runId).toBe("01RUN");
  });
});

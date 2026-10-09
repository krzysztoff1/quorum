import { describe, it, expect } from "vitest";
import { parseArgs } from "../src/args.js";

describe("parseArgs", () => {
  it("parses the flag subset Quorum passes", () => {
    const a = parseArgs([
      "-p", "research fusion",
      "--model", "deepseek/deepseek-chat",
      "--effort", "high",
      "--max-budget-usd", "0.25",
      "--max-turns", "6",
      "--tools", "web_search,web_fetch",
      "--append-system-prompt", "be terse",
    ]);
    expect(a.command).toBe("research");
    expect(a.prompt).toBe("research fusion");
    expect(a.model).toBe("deepseek/deepseek-chat");
    expect(a.effort).toBe("high");
    expect(a.maxBudgetUsd).toBe(0.25);
    expect(a.maxTurns).toBe(6);
    expect(a.tools).toEqual(["web_search", "web_fetch"]);
    expect(a.appendSystemPrompt).toBe("be terse");
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
    const a = parseArgs([
      "--output-format", "stream-json",
      "--verbose",
      "--include-partial-messages",
      "--permission-mode", "dontAsk",
      "--allowedTools", "WebSearch WebFetch",
      "-p", "topic",
      "--add-dir", "/some/path",
      "--model", "anthropic/claude-haiku-4-5",
    ]);
    expect(a.prompt).toBe("topic");
    expect(a.model).toBe("anthropic/claude-haiku-4-5");
    expect(a.effort).toBeUndefined();
  });

  it("degrades invalid numeric flags to undefined rather than NaN", () => {
    const a = parseArgs(["--max-budget-usd", "abc", "--max-turns", "xyz", "-p", "t"]);
    expect(a.maxBudgetUsd).toBeUndefined();
    expect(a.maxTurns).toBeUndefined();
  });

  it("supports --flag=value form", () => {
    const a = parseArgs(["--model=openrouter/x", "-p", "t"]);
    expect(a.model).toBe("openrouter/x");
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

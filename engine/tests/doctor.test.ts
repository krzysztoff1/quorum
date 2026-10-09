import { describe, expect, it } from "vitest";
import { formatDoctor, runDoctor, type DoctorDeps } from "../src/doctor.js";
import { ClaudeNotFoundError } from "../src/errors.js";

function deps(overrides: Partial<DoctorDeps> = {}): DoctorDeps {
  return {
    storeDir: "/store",
    resolveClaude: () => "/usr/local/bin/claude",
    runClaude: async (_bin, args) =>
      args[0] === "--version"
        ? { status: 0, stdout: "2.1.295 (Claude Code)\n" }
        : { status: 0, stdout: JSON.stringify({ loggedIn: true, authMethod: "claude.ai" }) },
    probeFetch: async () => ({ ok: true, detail: "example.com answered 200" }),
    probeStore: () => undefined,
    pendingMigrations: () => 0,
    ...overrides,
  };
}

const byId = (report: Awaited<ReturnType<typeof runDoctor>>, id: string) => report.checks.find((c) => c.id === id)!;

describe("quorum-engine doctor", () => {
  it("passes when the CLI is found and logged in, the web answers, the store is writable and nothing needs migrating", async () => {
    const report = await runDoctor(deps());

    expect(report.ok).toBe(true);
    expect(report.checks.map((c) => c.id)).toEqual(["claude_cli", "claude_login", "fetch", "store", "migrate", "rate_limit"]);
    expect(byId(report, "claude_cli")).toMatchObject({ ok: true, detail: expect.stringContaining("2.1.295"), fix: null });
  });

  it("names the fix when the claude CLI is missing, and does not claim to know the login", async () => {
    const report = await runDoctor(deps({ resolveClaude: () => { throw new ClaudeNotFoundError(); } }));

    expect(report.ok).toBe(false);
    expect(byId(report, "claude_cli")).toMatchObject({ ok: false, fix: expect.stringMatching(/install/i) });
    expect(byId(report, "claude_login")).toMatchObject({ ok: false, detail: expect.stringMatching(/not checked/i) });
  });

  it("fails the login check, with the fix, when the CLI is not signed in", async () => {
    const report = await runDoctor(deps({
      runClaude: async (_bin, args) =>
        args[0] === "--version" ? { status: 0, stdout: "2.1.295\n" } : { status: 1, stdout: JSON.stringify({ loggedIn: false }) },
    }));

    expect(byId(report, "claude_login")).toMatchObject({ ok: false, fix: expect.stringMatching(/claude/) });
    expect(report.ok).toBe(false);
  });

  it("does not fail the whole report on a login it could not confirm", async () => {
    const report = await runDoctor(deps({
      runClaude: async (_bin, args) => (args[0] === "--version" ? { status: 0, stdout: "2.1.295\n" } : { status: 0, stdout: "garbled" }),
    }));

    expect(byId(report, "claude_login")).toMatchObject({ ok: true, detail: expect.stringMatching(/could not be confirmed/i) });
  });

  it("fails fetch when the web cannot be reached, because no run can read a source then", async () => {
    const report = await runDoctor(deps({ probeFetch: async () => ({ ok: false, detail: "ENOTFOUND example.com" }) }));

    expect(byId(report, "fetch")).toMatchObject({ ok: false, detail: "ENOTFOUND example.com", fix: expect.stringMatching(/network/i) });
  });

  it("fails the store check with the path and the reason when it is not writable", async () => {
    const report = await runDoctor(deps({ probeStore: () => "EACCES: permission denied" }));

    expect(byId(report, "store")).toMatchObject({ ok: false, detail: expect.stringContaining("/store"), fix: expect.stringMatching(/folder/i) });
  });

  it("fails migrate while records are waiting for an upgrade, and tells the user which command", async () => {
    const report = await runDoctor(deps({ pendingMigrations: () => 3 }));

    expect(byId(report, "migrate")).toMatchObject({ ok: false, detail: "3 records need migrating", fix: "quorum-engine migrate --store /store" });
  });

  it("is honest that the rate-limit window is not tracked yet, without failing on it", async () => {
    expect(byId(await runDoctor(deps()), "rate_limit")).toMatchObject({ ok: true, detail: expect.stringMatching(/not tracked/i) });
  });

  it("prints one line per check, with the fix under a failing one", async () => {
    const text = formatDoctor(await runDoctor(deps({ probeStore: () => "EACCES" })));

    expect(text).toMatch(/^ok +claude_cli/m);
    expect(text).toMatch(/^FAIL store/m);
    expect(text).toMatch(/^ {6}fix: /m);
  });
});

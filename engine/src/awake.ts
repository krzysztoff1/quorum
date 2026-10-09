import { spawn as nodeSpawn } from "node:child_process";

export interface AwakeDeps {
  platform: NodeJS.Platform;
  spawn: typeof nodeSpawn;
}

export function keepAwake(pid: number, deps: AwakeDeps = { platform: process.platform, spawn: nodeSpawn }): void {
  if (deps.platform !== "darwin") return;
  try {
    const child = deps.spawn("caffeinate", ["-i", "-w", String(pid)], { stdio: "ignore", detached: true });
    child.on("error", () => {});
    child.unref();
  } catch {
    return;
  }
}

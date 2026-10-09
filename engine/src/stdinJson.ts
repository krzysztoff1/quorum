import type { Readable } from "node:stream";

export function readJsonFrom<T = unknown>(input: Readable): Promise<T> {
  return new Promise((resolve, reject) => {
    let buffer = "";
    let settled = false;
    const settle = (finish: () => void) => {
      if (settled) return;
      settled = true;
      finish();
    };
    input.setEncoding("utf8");
    input.on("data", (chunk: string) => {
      buffer += chunk;
      try {
        const value = JSON.parse(buffer) as T;
        settle(() => resolve(value));
      } catch {
        return;
      }
    });
    input.on("end", () => {
      settle(() => {
        if (!buffer.trim()) return reject(new Error("stdin closed before a JSON value arrived"));
        reject(new Error("stdin is not valid JSON"));
      });
    });
    input.on("error", (error) => settle(() => reject(error)));
  });
}

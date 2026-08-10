import type { ControlStream, RunControl } from "./run.js";

/// The longest leading prefix of `buffer` that is one complete JSON value, and whatever followed it. The
/// run's config arrives first on stdin and the approval lines follow on the same pipe, so the boundary has
/// to be found by structure rather than by assuming the config occupies exactly one line.
export function takeLeadingJson(buffer: string): { value: unknown; rest: string } | undefined {
  let depth = 0;
  let inString = false;
  let escaped = false;
  let started = false;

  for (let i = 0; i < buffer.length; i++) {
    const c = buffer[i]!;
    if (escaped) {
      escaped = false;
      continue;
    }
    if (inString) {
      if (c === "\\") escaped = true;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') {
      inString = true;
      continue;
    }
    if (c === "{" || c === "[") {
      depth += 1;
      started = true;
    } else if (c === "}" || c === "]") {
      depth -= 1;
      if (started && depth === 0) {
        const head = buffer.slice(0, i + 1);
        try {
          return { value: JSON.parse(head), rest: buffer.slice(i + 1) };
        } catch {
          return undefined;
        }
      }
    }
  }
  return undefined;
}

export function parseControlLine(line: string): RunControl | undefined {
  const trimmed = line.trim();
  if (!trimmed) return undefined;
  try {
    const parsed = JSON.parse(trimmed) as { type?: string; id?: string; verdict?: string };
    if (!parsed.id) return undefined;
    if (parsed.type === "prune" || parsed.type === "retry") return { type: parsed.type, id: parsed.id };
    if (parsed.type !== undefined && parsed.type !== "approve") return undefined;
    if (parsed.verdict !== "approved" && parsed.verdict !== "rejected") return undefined;
    return { type: "approve", id: parsed.id, verdict: parsed.verdict };
  } catch {
    return undefined;
  }
}

/// with nothing once the wait is up — the run must never block on a person who walked away.
export class ControlQueue implements ControlStream {
  private readonly waiting: RunControl[] = [];
  private readonly takers: Array<(a: RunControl | undefined) => void> = [];
  private closed = false;

  push(control: RunControl): void {
    const taker = this.takers.shift();
    if (taker) taker(control);
    else this.waiting.push(control);
  }

  close(): void {
    this.closed = true;
    while (this.takers.length > 0) this.takers.shift()!(undefined);
  }

  take(timeoutMs: number): Promise<RunControl | undefined> {
    const ready = this.waiting.shift();
    if (ready) return Promise.resolve(ready);
    if (this.closed) return Promise.resolve(undefined);
    return new Promise((resolve) => {
      let settled = false;
      const finish = (value: RunControl | undefined) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(value);
      };
      const timer = setTimeout(() => {
        const index = this.takers.indexOf(finish);
        if (index >= 0) this.takers.splice(index, 1);
        finish(undefined);
      }, timeoutMs);
      if (typeof timer.unref === "function") timer.unref();
      this.takers.push(finish);
    });
  }
}

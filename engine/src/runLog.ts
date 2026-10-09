import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import type { Sink } from "./emitter.js";

export const EVENTS_FILE = "events.ndjson";

export class RunLog {
  private readonly lines: any[] = [];

  constructor(private readonly runDir: string | undefined) {
    if (runDir) mkdirSync(runDir, { recursive: true });
  }

  tee(downstream: Sink): Sink {
    return (line) => {
      this.record(line);
      downstream(line);
    };
  }

  events(): any[] {
    return [...this.lines];
  }

  private record(line: string): void {
    if (this.runDir) appendFileSync(join(this.runDir, EVENTS_FILE), line);
    try {
      this.lines.push(JSON.parse(line));
    } catch {
      this.lines.push({ type: "unreadable" });
    }
  }
}

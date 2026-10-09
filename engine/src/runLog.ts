import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import type { Sink } from "./emitter.js";

export const EVENTS_FILE = "events.ndjson";
export const TRANSCRIPTS_DIR = "transcripts";

const TRANSCRIPT_NAME = /^[A-Za-z0-9_.-]{1,64}$/;

export class RunLog {
  private readonly lines: any[] = [];
  private transcriptsReady = false;

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
    let event: any;
    try {
      event = JSON.parse(line);
    } catch {
      event = { type: "unreadable" };
    }
    this.lines.push(event);
    if (!this.runDir) return;
    appendFileSync(join(this.runDir, EVENTS_FILE), line);
    const task = event?.angle_id;
    if (typeof task === "string" && TRANSCRIPT_NAME.test(task)) this.appendTranscript(task, line);
  }

  private appendTranscript(task: string, line: string): void {
    const dir = join(this.runDir!, TRANSCRIPTS_DIR);
    if (!this.transcriptsReady) {
      mkdirSync(dir, { recursive: true });
      this.transcriptsReady = true;
    }
    appendFileSync(join(dir, `${task}.ndjson`), line);
  }
}

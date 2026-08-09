import { describe, it, expect } from "vitest";
import { takeLeadingJson, parseApprovalLine, ApprovalQueue } from "../src/approvals.js";

describe("splitting the config from the verdicts that follow it", () => {
  it("takes the config object and leaves the rest of the pipe alone", () => {
    const split = takeLeadingJson('{"question":"why"}\n{"id":"x1","verdict":"approved"}\n');

    expect(split?.value).toEqual({ question: "why" });
    expect(split?.rest).toBe('\n{"id":"x1","verdict":"approved"}\n');
  });

  it("finds the boundary even when the config spans several lines", () => {
    const split = takeLeadingJson('{\n  "question": "why",\n  "rounds": 2\n}\nmore');

    expect(split?.value).toEqual({ question: "why", rounds: 2 });
    expect(split?.rest).toBe("\nmore");
  });

  it("is not fooled by braces inside a string", () => {
    const split = takeLeadingJson('{"question":"what about {this}?"}rest');

    expect(split?.value).toEqual({ question: "what about {this}?" });
    expect(split?.rest).toBe("rest");
  });

  it("waits rather than guessing when the object has not fully arrived", () => {
    expect(takeLeadingJson('{"question":"wh')).toBeUndefined();
  });
});

describe("approval lines", () => {
  it("reads a verdict", () => {
    expect(parseApprovalLine('{"type":"approve","id":"x1","verdict":"approved"}'))
      .toEqual({ id: "x1", verdict: "approved" });
  });

  it("accepts a line with no type, so the app need not repeat itself", () => {
    expect(parseApprovalLine('{"id":"x2","verdict":"rejected"}')).toEqual({ id: "x2", verdict: "rejected" });
  });

  it("ignores anything that is not a verdict", () => {
    expect(parseApprovalLine("")).toBeUndefined();
    expect(parseApprovalLine("not json")).toBeUndefined();
    expect(parseApprovalLine('{"id":"x1"}')).toBeUndefined();
    expect(parseApprovalLine('{"id":"x1","verdict":"maybe"}')).toBeUndefined();
    expect(parseApprovalLine('{"type":"other","id":"x1","verdict":"approved"}')).toBeUndefined();
  });
});

describe("the approval queue", () => {
  it("hands over a verdict that arrived before anyone asked", async () => {
    const q = new ApprovalQueue();
    q.push({ id: "x1", verdict: "approved" });

    expect(await q.take(1000)).toEqual({ id: "x1", verdict: "approved" });
  });

  it("hands over a verdict that arrives while the run is waiting", async () => {
    const q = new ApprovalQueue();
    const taken = q.take(1000);
    q.push({ id: "x1", verdict: "rejected" });

    expect(await taken).toEqual({ id: "x1", verdict: "rejected" });
  });

  it("gives up rather than blocking a run whose user walked away", async () => {
    expect(await new ApprovalQueue().take(5)).toBeUndefined();
  });

  it("releases everyone waiting when the channel closes", async () => {
    const q = new ApprovalQueue();
    const taken = q.take(10_000);
    q.close();

    expect(await taken).toBeUndefined();
    expect(await q.take(10_000)).toBeUndefined();
  });
});

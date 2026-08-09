import { describe, it, expect } from "vitest";
import { takeLeadingJson, parseControlLine, ControlQueue } from "../src/approvals.js";

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

describe("control lines", () => {
  it("reads a verdict", () => {
    expect(parseControlLine('{"type":"approve","id":"x1","verdict":"approved"}'))
      .toEqual({ type: "approve", id: "x1", verdict: "approved" });
  });

  it("accepts a line with no type, so the app need not repeat itself", () => {
    expect(parseControlLine('{"id":"x2","verdict":"rejected"}'))
      .toEqual({ type: "approve", id: "x2", verdict: "rejected" });
  });

  it("reads the two commands the canvas can give a running run", () => {
    expect(parseControlLine('{"type":"prune","id":"q1"}')).toEqual({ type: "prune", id: "q1" });
    expect(parseControlLine('{"type":"retry","id":"a1"}')).toEqual({ type: "retry", id: "a1" });
  });

  it("ignores anything that is not a control the run knows how to obey", () => {
    expect(parseControlLine("")).toBeUndefined();
    expect(parseControlLine("not json")).toBeUndefined();
    expect(parseControlLine('{"id":"x1"}')).toBeUndefined();
    expect(parseControlLine('{"id":"x1","verdict":"maybe"}')).toBeUndefined();
    expect(parseControlLine('{"type":"prune"}')).toBeUndefined();
    expect(parseControlLine('{"type":"other","id":"x1","verdict":"approved"}')).toBeUndefined();
  });
});

describe("the control queue", () => {
  it("hands over a verdict that arrived before anyone asked", async () => {
    const q = new ControlQueue();
    q.push({ type: "approve", id: "x1", verdict: "approved" });

    expect(await q.take(1000)).toEqual({ type: "approve", id: "x1", verdict: "approved" });
  });

  it("hands over a verdict that arrives while the run is waiting", async () => {
    const q = new ControlQueue();
    const taken = q.take(1000);
    q.push({ type: "approve", id: "x1", verdict: "rejected" });

    expect(await taken).toEqual({ type: "approve", id: "x1", verdict: "rejected" });
  });

  it("gives up rather than blocking a run whose user walked away", async () => {
    expect(await new ControlQueue().take(5)).toBeUndefined();
  });

  it("releases everyone waiting when the channel closes", async () => {
    const q = new ControlQueue();
    const taken = q.take(10_000);
    q.close();

    expect(await taken).toBeUndefined();
    expect(await q.take(10_000)).toBeUndefined();
  });
});

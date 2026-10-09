import { describe, it, expect } from "vitest";
import { PassThrough } from "node:stream";
import { readJsonFrom } from "../src/stdinJson.js";

describe("reading one JSON value from a stream", () => {
  it("resolves as soon as the value is complete, without waiting for the stream to end", async () => {
    const input = new PassThrough();
    const pending = readJsonFrom(input);
    input.write('{"question":"a');
    input.write('b"}\n');

    await expect(pending).resolves.toEqual({ question: "ab" });
  });

  it("resolves at the end of the stream when the value had no trailing newline", async () => {
    const input = new PassThrough();
    const pending = readJsonFrom(input);
    input.end('{"question":"q"}');

    await expect(pending).resolves.toEqual({ question: "q" });
  });

  it("rejects when the stream ends before a value arrived", async () => {
    const input = new PassThrough();
    const pending = readJsonFrom(input);
    input.end("");

    await expect(pending).rejects.toThrow(/stdin closed/);
  });

  it("rejects when what arrived is not JSON", async () => {
    const input = new PassThrough();
    const pending = readJsonFrom(input);
    input.end("not json");

    await expect(pending).rejects.toThrow(/not valid JSON/);
  });
});

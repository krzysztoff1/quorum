import { describe, expect, it } from "vitest";
import { hasFencedJson, parseFencedJson } from "../src/fence.js";
import { draftAnswer } from "../src/answer/index.js";
import { lastJsonFence } from "../src/fence.js";

describe("the trailing json summary is not confused with a jsonl block", () => {
  const spec = "```jsonl\n{\"op\":\"add\",\"path\":\"/v\",\"value\":1}\n```";

  it("finds no summary when only a jsonl fence is present", () => {
    expect(lastJsonFence(`Prose.\n\n${spec}`)).toBe(-1);
    expect(parseFencedJson(`Prose.\n\n${spec}`)).toBeUndefined();
    expect(hasFencedJson(`Prose.\n\n${spec}`)).toBe(false);
  });

  it("finds the json summary after a jsonl block", () => {
    const text = `Prose.\n\n${spec}\n\n\`\`\`json\n{"headline":"H"}\n\`\`\``;
    expect(parseFencedJson(text)).toEqual({ headline: "H" });
  });

  it("does not cut a prose answer at a jsonl fence", async () => {
    const draft = await draftAnswer("Lead sentence.\n\n```text\nnot a spec\n```\n\nSecond paragraph.", []);
    expect(draft.spec.elements.answer!.props.lead).toBe("Lead sentence.");
  });
});

describe("a slightly malformed json summary is repaired instead of lost", () => {
  const fencedText = (body: string) => `Prose.\n\n\`\`\`json\n${body}\n\`\`\``;

  it("drops a stray comma-string between array elements", () => {
    const body = '[{"title":"A","prompt":"pa"},"," {"title":"B","prompt":"pb"}]';
    expect(parseFencedJson(fencedText(body))).toEqual([{ title: "A", prompt: "pa" }, { title: "B", prompt: "pb" }]);
  });

  it("drops trailing and doubled commas", () => {
    expect(parseFencedJson(fencedText('{"a":[1,2,],"b":3,}'))).toEqual({ a: [1, 2], b: 3 });
    expect(parseFencedJson(fencedText('{"a":1,,"b":2}'))).toEqual({ a: 1, b: 2 });
  });

  it("adds the comma missing between two objects or two arrays", () => {
    expect(parseFencedJson(fencedText('[{"a":1}{"a":2}]'))).toEqual([{ a: 1 }, { a: 2 }]);
    expect(parseFencedJson(fencedText('[[1][2]]'))).toEqual([[1], [2]]);
  });

  it("leaves commas and brackets inside strings alone", () => {
    expect(parseFencedJson(fencedText('{"prompt":"a,, b ,}","n":1,}'))).toEqual({ prompt: "a,, b ,}", n: 1 });
  });

  it("still gives up on text that is not json at all", () => {
    expect(parseFencedJson(fencedText("{not json}"))).toBeUndefined();
    expect(parseFencedJson(fencedText('{"a":"unterminated'))).toBeUndefined();
  });
});

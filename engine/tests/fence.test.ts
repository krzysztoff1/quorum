import { describe, expect, it } from "vitest";
import { hasFencedJson, parseFencedJson } from "../src/agent.js";
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

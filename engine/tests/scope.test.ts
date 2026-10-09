import { describe, expect, it } from "vitest";
import { scopeQuestion } from "../src/scope.js";

describe("scope (the stub that M7 replaces)", () => {
  it("never asks anything: the brief is the question, its language and a title", () => {
    expect(scopeQuestion({ question: "  What do the EU AI Act's obligations require?\n" })).toEqual({
      needs_scoping: false,
      brief: { question: "What do the EU AI Act's obligations require?", language: "en", title: "What do the EU AI Act's obligations require" },
    });
  });

  it("reads the language off the question", () => {
    const scoped = scopeQuestion({ question: "Jakie wymagania RODO dotyczą danych o zdrowiu i diecie w aplikacjach?" });

    expect(scoped).toMatchObject({ needs_scoping: false, brief: { language: "pl" } });
  });

  it("answers a second call, with answers, the same way", () => {
    const scoped = scopeQuestion({ question: "Is Bun faster than Node?", answers: { speed: ["startup"] }, parent_run_id: "R1" });

    expect(scoped).toMatchObject({ needs_scoping: false, brief: { question: "Is Bun faster than Node?" } });
  });

  it("refuses an empty question rather than returning a brief nobody can run", () => {
    expect(() => scopeQuestion({ question: "   " })).toThrow(/question/);
  });
});

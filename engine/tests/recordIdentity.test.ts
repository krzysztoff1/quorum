import { describe, expect, it } from "vitest";
import { ulid } from "../src/record/ids.js";
import { titleFromQuestion, titleProblem } from "../src/record/title.js";
import { detectLanguage } from "../src/record/language.js";
import { openRecording } from "../src/record/store.js";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("ulid", () => {
  it("is 26 Crockford characters that sort by time", () => {
    const early = ulid(1_700_000_000_000, () => 0);
    const late = ulid(1_700_000_000_001, () => 0.999);
    expect(early).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(early < late).toBe(true);
  });

  it("encodes the time in its first ten characters", () => {
    expect(ulid(0, () => 0)).toBe("00000000000000000000000000");
    expect(ulid(1_700_000_000_000, () => 0).slice(0, 10)).toBe(ulid(1_700_000_000_000, () => 0.5).slice(0, 10));
  });
});

describe("titleFromQuestion", () => {
  it("is the question on one line with its trailing punctuation dropped", () => {
    expect(titleFromQuestion("  What do the EU AI Act's   obligations require?\n")).toBe("What do the EU AI Act's obligations require");
  });

  it("cuts a long question on a word boundary", () => {
    const title = titleFromQuestion("Jakie wymagania RODO dotyczą danych o zdrowiu i diecie w aplikacjach do zamawiania posiłków?");
    expect(title.length).toBeLessThanOrEqual(60);
    expect(title).toBe("Jakie wymagania RODO dotyczą danych o zdrowiu i diecie w");
  });
});

describe("titleProblem", () => {
  it("accepts a short topical title", () => {
    expect(titleProblem("EU AI Act obligations for GPAI models")).toBeUndefined();
  });

  it("rejects an empty title", () => {
    expect(titleProblem("  ")).toBe("the title is empty");
  });

  it("rejects a clarifier or an apology", () => {
    expect(titleProblem("Zanim zacznę deep research, chciałbym sprecyzować kilka rzeczy?")).toMatch(/question/);
    expect(titleProblem("I'm sorry, I can't help with that")).toMatch(/apolog/);
    expect(titleProblem("Could you clarify what you mean")).toMatch(/clarif/);
  });

  it("rejects a title spread over lines or too long", () => {
    expect(titleProblem("one\ntwo")).toMatch(/line/);
    expect(titleProblem("x".repeat(90))).toMatch(/long/);
  });
  it("never reads the user's own question as a clarifier", () => {
    expect(titleProblem("Can you compare Postgres and MySQL for OLTP", "question")).toBeUndefined();
    expect(titleProblem("Could you explain how MVCC works", "question")).toBeUndefined();
    expect(titleProblem("Could you clarify what you mean", "scope")).toMatch(/clarif/);
  });
});

describe("detectLanguage", () => {
  it("tells Polish from English", () => {
    expect(detectLanguage("Jakie wymagania RODO dotyczą danych o zdrowiu i diecie w aplikacjach?")).toBe("pl");
    expect(detectLanguage("What do the EU AI Act's obligations for general-purpose AI models require, and from when?")).toBe("en");
  });

  it("recognises German, French and Spanish", () => {
    expect(detectLanguage("Welche Pflichten haben Anbieter von KI-Modellen und ab wann gelten sie für die Anbieter?")).toBe("de");
    expect(detectLanguage("Quelles sont les obligations des fournisseurs de modèles et à partir de quand sont-elles dues?")).toBe("fr");
    expect(detectLanguage("¿Cuáles son las obligaciones de los proveedores de modelos y desde cuándo se aplican?")).toBe("es");
  });

  it("reads a short English question", () => {
    expect(detectLanguage("Has fusion reached scientific breakeven?")).toBe("en");
  });

  it("says und when it cannot tell", () => {
    expect(detectLanguage("GPT-4o 2025")).toBe("und");
  });
});

describe("openRecording ids", () => {
  const models = { planner: "m", research: "m", synthesis: "m", validator: "m" };

  it("uses the question and run ids a detaching parent allocated, so it can name the directory before the child starts", () => {
    const brainDir = mkdtempSync(join(tmpdir(), "quorum-ids-"));
    const recording = openRecording({
      question: "q", brainDir, ids: { questionId: "QID", runId: "RID" },
      models, limits: {}, now: () => 0,
    });

    expect(recording.startFields).toMatchObject({ question_id: "QID", run_id: "RID" });
    expect(recording.runDir).toBe(join(brainDir, "questions", "QID", "runs", "RID"));
  });
});

import { describe, expect, it } from "vitest";
import { settleMarkers } from "../src/markers.js";
import type { Citation } from "../src/evidence.js";

function citation(id: string): Citation {
  return { id, source_id: `s-${id}`, quote: `quote ${id}`, match: "exact", start: 0, end: 5 };
}

describe("settleMarkers", () => {
  it("strips a marker the writer never declared and reports it", () => {
    const settled = settleMarkers("Declared.[^a1c1] Invented.[^a1c17]", [], [citation("a1c1")]);
    expect(settled.writeup).toBe("Declared.[^a1c1] Invented.");
    expect(settled.stripped).toEqual(["a1c17"]);
  });

  it("drops the writer's own footnote definition of a stripped marker", () => {
    const settled = settleMarkers("Invented.[^a1c17]\n\n[^a1c17]: made up\n[^a1c1]: kept", [], [citation("a1c1")]);
    expect(settled.writeup).toBe("Invented.\n\n[^a1c1]: kept");
  });

  it("resolves a marker the run already verified elsewhere instead of stripping it", () => {
    const known = new Map([["a2c3", citation("a2c3")]]);
    const settled = settleMarkers("Reused.[^a2c3]", [], [], known);
    expect(settled.writeup).toBe("Reused.[^a2c3]");
    expect(settled.citations.map((c) => c.id)).toEqual(["a2c3"]);
    expect(settled.stripped).toEqual([]);
  });

  it("drops a finding's citation id that names nothing and reports it once", () => {
    const findings = [{ claim: "x", citations: ["a1c1", "a1c9"] }, { claim: "y", citations: ["a1c9"] }];
    const settled = settleMarkers("Body.[^a1c1]", findings, [citation("a1c1")]);
    expect(settled.findings.map((f) => f.citations)).toEqual([["a1c1"], []]);
    expect(settled.stripped).toEqual(["a1c9"]);
  });

  it("leaves a writeup whose markers all resolve untouched", () => {
    const settled = settleMarkers("A.[^c1] B.[^c2]", [{ claim: "A", citations: ["c1"] }], [citation("c1"), citation("c2")]);
    expect(settled.writeup).toBe("A.[^c1] B.[^c2]");
    expect(settled.stripped).toEqual([]);
  });
});

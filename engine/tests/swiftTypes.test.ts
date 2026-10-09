import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { swiftTypes } from "../src/record/swiftTypes.js";
import { generatedArtifacts } from "../src/record/emitSchema.js";

const SAMPLE = {
  title: "Sample",
  type: "object",
  properties: {
    schema: { type: "string", const: "s/1" },
    source_id: { type: "string" },
    cost_usd: { type: "number" },
    round: { type: "integer" },
    cited: { type: "boolean" },
    protocol: { type: "integer" },
    citation_ids: { type: "array", items: { type: "string" } },
    status: { type: "string", enum: ["running", "complete", "half_done"] },
    snapshot_path: { anyOf: [{ type: "string" }, { type: "null" }] },
    note: { type: "string" },
    child: { $ref: "#/$defs/Child" },
    inline: { type: "object", properties: { x: { type: "number" } }, required: ["x"] },
  },
  required: ["schema", "source_id", "cost_usd", "round", "cited", "protocol", "citation_ids", "status", "snapshot_path", "child", "inline"],
  $defs: {
    Child: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
  },
};

describe("swiftTypes", () => {
  const swift = swiftTypes([SAMPLE]);

  it("emits a Codable struct per object with camel-cased properties and their wire keys", () => {
    expect(swift).toContain("public struct Sample: Codable, Sendable, Equatable {");
    expect(swift).toContain("    public let sourceID: String\n");
    expect(swift).toContain("    public let costUSD: Double\n");
    expect(swift).toContain("    public let round: Int\n");
    expect(swift).toContain("    public let citationIDs: [String]\n");
    expect(swift).toContain('        case sourceID = "source_id"\n');
    expect(swift).toContain("        case schema\n");
  });

  it("backticks a property named after a Swift keyword", () => {
    expect(swift).toContain("    public let `protocol`: Int\n");
    expect(swift).toContain("        case `protocol`\n");
  });

  it("makes optional and nullable properties optional", () => {
    expect(swift).toContain("    public let snapshotPath: String?\n");
    expect(swift).toContain("    public let note: String?\n");
  });

  it("names referenced and inline objects", () => {
    expect(swift).toContain("    public let child: Child\n");
    expect(swift).toContain("public struct Child: Codable, Sendable, Equatable {");
    expect(swift).toContain("    public let inline: SampleInline\n");
    expect(swift).toContain("public struct SampleInline: Codable, Sendable, Equatable {");
  });

  it("decodes an enum value it does not know as unknown rather than throwing", () => {
    expect(swift).toContain("public enum SampleStatus: String, Codable, Sendable, Equatable, CaseIterable {");
    expect(swift).toContain('    case halfDone = "half_done"\n');
    expect(swift).toContain("    case unknown\n");
    expect(swift).toContain("        self = SampleStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown\n");
  });

  it("gives every struct a memberwise public initializer", () => {
    expect(swift).toContain("    public init(id: String) {\n        self.id = id\n    }\n");
  });
});

describe("generated artifacts", () => {
  it("are checked in exactly as the schema generates them", () => {
    for (const artifact of generatedArtifacts()) {
      expect(readFileSync(artifact.path, "utf8"), `${artifact.path} is stale: run bun run schema`).toBe(artifact.content);
    }
  });
});

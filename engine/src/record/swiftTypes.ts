type Schema = Record<string, any>;

const KEYWORDS = new Set([
  "associatedtype", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum",
  "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout",
  "internal", "is", "let", "nil", "open", "operator", "private", "protocol", "public", "repeat", "rethrows", "return",
  "self", "Self", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias",
  "var", "where", "while",
]);

const ACRONYMS: Record<string, string> = { id: "ID", ids: "IDs", usd: "USD", url: "URL" };

interface Declaration {
  name: string;
  source: string;
}

export function swiftTypes(roots: Schema[]): string {
  const emitter = new SwiftEmitter();
  for (const root of roots) emitter.root(root);
  return emitter.source();
}

class SwiftEmitter {
  private readonly declarations: Declaration[] = [];
  private readonly named = new Set<string>();

  root(schema: Schema): void {
    const name = String(schema.title);
    this.declare(name, () => this.struct(name, schema, schema.$defs ?? {}));
  }

  source(): string {
    return "import Foundation\n\n" + this.declarations.map((d) => d.source).join("\n\n") + "\n";
  }

  private declare(name: string, render: () => string): void {
    if (this.named.has(name)) return;
    this.named.add(name);
    const slot: Declaration = { name, source: "" };
    this.declarations.push(slot);
    slot.source = render();
  }

  private typeOf(schema: Schema, owner: string, property: string, defs: Schema): string {
    if (schema.$ref) {
      const name = String(schema.$ref).split("/").at(-1)!;
      this.declare(name, () => this.struct(name, defs[name], defs));
      return name;
    }
    if (Array.isArray(schema.anyOf)) {
      const present = schema.anyOf.filter((s: Schema) => s.type !== "null");
      return this.typeOf(present[0] ?? {}, owner, property, defs);
    }
    if (Array.isArray(schema.enum)) {
      const name = owner + pascal(property);
      this.declare(name, () => enumeration(name, schema.enum.map(String)));
      return name;
    }
    if (schema.type === "string") return "String";
    if (schema.type === "integer") return "Int";
    if (schema.type === "number") return "Double";
    if (schema.type === "boolean") return "Bool";
    if (schema.type === "array") return `[${this.typeOf(schema.items ?? {}, owner, singular(property), defs)}]`;
    if (schema.type === "object" && !schema.properties && schema.additionalProperties) {
      return `[String: ${this.typeOf(schema.additionalProperties, owner, property, defs)}]`;
    }
    if (schema.type === "object") {
      const name = owner + pascal(property);
      this.declare(name, () => this.struct(name, schema, defs));
      return name;
    }
    return "String";
  }

  private struct(name: string, schema: Schema, defs: Schema): string {
    const required = new Set<string>(schema.required ?? []);
    const fields = Object.entries<Schema>(schema.properties ?? {}).map(([wire, property]) => {
      const nullable = Array.isArray(property.anyOf) && property.anyOf.some((s: Schema) => s.type === "null");
      const optional = !required.has(wire) || nullable;
      return { wire, swift: camel(wire), type: this.typeOf(property, name, wire, defs) + (optional ? "?" : "") };
    });
    const lines = [`public struct ${name}: Codable, Sendable, Equatable {`];
    for (const field of fields) lines.push(`    public let ${escape(field.swift)}: ${field.type}`);
    lines.push("");
    const parameters = fields.map((f) => `${f.swift}: ${f.type}${f.type.endsWith("?") ? " = nil" : ""}`).join(", ");
    lines.push(`    public init(${parameters}) {`);
    for (const field of fields) lines.push(`        self.${field.swift} = ${escape(field.swift)}`);
    lines.push("    }");
    lines.push("");
    lines.push("    enum CodingKeys: String, CodingKey {");
    for (const field of fields) {
      lines.push(field.swift === field.wire ? `        case ${escape(field.swift)}` : `        case ${escape(field.swift)} = "${field.wire}"`);
    }
    lines.push("    }");
    lines.push("}");
    return lines.join("\n");
  }
}

function enumeration(name: string, values: string[]): string {
  const lines = [`public enum ${name}: String, Codable, Sendable, Equatable, CaseIterable {`];
  for (const value of values) {
    const swift = camel(value);
    lines.push(swift === value ? `    case ${escape(swift)}` : `    case ${escape(swift)} = "${value}"`);
  }
  if (!values.includes("unknown")) lines.push("    case unknown");
  lines.push("");
  lines.push("    public init(from decoder: Decoder) throws {");
  lines.push(`        self = ${name}(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown`);
  lines.push("    }");
  lines.push("}");
  return lines.join("\n");
}

function camel(wire: string): string {
  const [head, ...rest] = wire.split(/[_\-\s/]+/).filter(Boolean);
  return (head ?? "").toLowerCase() + rest.map((part) => ACRONYMS[part.toLowerCase()] ?? capitalize(part)).join("");
}

function pascal(wire: string): string {
  return wire.split(/[_\-\s/]+/).filter(Boolean).map((part) => ACRONYMS[part.toLowerCase()] ?? capitalize(part)).join("");
}

function capitalize(part: string): string {
  return part.charAt(0).toUpperCase() + part.slice(1);
}

function singular(property: string): string {
  return property.endsWith("s") ? property.slice(0, -1) : property;
}

function escape(name: string): string {
  return KEYWORDS.has(name) ? `\`${name}\`` : name;
}

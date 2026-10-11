import type { Element, Spec } from "./catalog.js";
import { parseElement, reporter, type Issue } from "./validate.js";

const ELEMENT = /^\/elements\/([^/]+)$/;
const CHILD = /^\/elements\/([^/]+)\/children\/-$/;
const ROW = /^\/elements\/([^/]+)\/props\/([A-Za-z_]+)\/-$/;
const SPEC_FENCE = /```(?:qvs|jsonl)[^\n]*\n([\s\S]*?)(?:```|$)/;

function unescapeKey(key: string): string {
  return key.replace(/~1/g, "/").replace(/~0/g, "~");
}

export class SpecStream {
  private buffer = "";
  private line = 0;
  private root?: string;
  private version?: number;
  private readonly elements: Record<string, Element> = {};
  readonly quarantined = new Map<string, { type?: string; raw: unknown; issues: Issue[] }>();
  readonly issues: Issue[] = [];
  private readonly report = reporter(this.issues);

  push(chunk: string): void {
    this.buffer += chunk;
    let newline: number;
    while ((newline = this.buffer.indexOf("\n")) >= 0) {
      const text = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      this.apply(text, false);
    }
  }

  end(): Spec {
    if (this.buffer.trim()) this.apply(this.buffer, true);
    this.buffer = "";
    return this.spec();
  }

  spec(): Spec {
    return { v: this.version ?? 1, root: this.root ?? "", elements: structuredClone(this.elements) };
  }

  private apply(text: string, last: boolean): void {
    this.line++;
    if (!text.trim()) return;
    let op: any;
    try {
      op = JSON.parse(text);
    } catch {
      this.report(["$line", this.line], "parse_error", last ? "the stream ended mid-line" : "the line is not JSON");
      return;
    }
    const reject = (message: string) => this.report(["$line", this.line], "patch_rejected", message);
    if (op?.op !== "add" || typeof op.path !== "string") return reject(`only add is allowed, got ${JSON.stringify(op?.op)}`);
    const { path, value } = op;
    if (path === "/v") {
      this.version = Number(value);
      return;
    }
    if (path === "/root") {
      if (this.root) return reject("the root is already set");
      this.root = String(value);
      return;
    }
    let match: RegExpMatchArray | null;
    if ((match = path.match(ELEMENT))) return this.addElement(unescapeKey(match[1]!), value, reject);
    if ((match = path.match(CHILD))) {
      const element = this.elements[unescapeKey(match[1]!)];
      if (!element?.children && this.appendToQuarantined(unescapeKey(match[1]!), path, value)) return;
      if (!element?.children) return reject(`no element with children at ${path}`);
      element.children.push(String(value));
      return;
    }
    if ((match = path.match(ROW)) && this.quarantined.has(unescapeKey(match[1]!))) {
      if (this.appendToQuarantined(unescapeKey(match[1]!), path, value)) return;
    }
    if ((match = path.match(ROW))) return this.addRow(unescapeKey(match[1]!), match[2]!, value, reject);
    reject(`${path} is not an add target`);
  }

  private addElement(key: string, value: unknown, reject: (message: string) => void): void {
    if (key in this.elements || this.quarantined.has(key)) return reject(`element "${key}" already exists`);
    const parsed = parseElement(key, value, "model");
    if (!parsed.element) {
      this.quarantined.set(key, { type: (value as any)?.type, raw: structuredClone(value), issues: parsed.issues });
      this.issues.push(...parsed.issues);
      return;
    }
    this.elements[key] = parsed.element;
  }

  private addRow(key: string, prop: string, value: unknown, reject: (message: string) => void): void {
    const element = this.elements[key];
    if (!element || !Array.isArray(element.props[prop])) return reject(`no array prop "${prop}" on "${key}"`);
    const candidate = structuredClone(element);
    candidate.props[prop].push(value);
    const parsed = parseElement(key, candidate, "model");
    if (!parsed.element) {
      this.issues.push(...parsed.issues);
      return;
    }
    this.elements[key] = parsed.element;
  }

  appendToQuarantined(key: string, path: string, value: unknown): boolean {
    const held = this.quarantined.get(key);
    const raw = held?.raw as any;
    if (!raw || typeof raw !== "object") return false;
    const child = CHILD.test(path);
    if (child) {
      raw.children = [...(Array.isArray(raw.children) ? raw.children : []), String(value)];
      return true;
    }
    const prop = path.match(ROW)?.[2];
    if (prop && raw.props && Array.isArray(raw.props[prop])) {
      raw.props[prop].push(value);
      return true;
    }
    return false;
  }
}

export function compileJsonl(text: string): { spec: Spec; issues: Issue[]; quarantined: SpecStream["quarantined"] } {
  const stream = new SpecStream();
  stream.push(text);
  const spec = stream.end();
  return { spec, issues: stream.issues, quarantined: stream.quarantined };
}

export function extractSpecBlock(reply: string): { jsonl: string; prose: string } | undefined {
  const match = SPEC_FENCE.exec(reply);
  if (!match) return undefined;
  return { jsonl: match[1]!, prose: reply.slice(0, match.index) + reply.slice(match.index + match[0].length) };
}

// SpecStream: JSONL patch compiler. The model streams one RFC 6902 `add` op per line; only four paths are allowed:
//   /v · /root · /elements/<key> (a COMPLETE element) · /elements/<key>/children/- and /elements/<key>/props/<arrayProp>/- (row appends)
// A line is applied only once its "\n" has arrived, so a half-received element is never rendered. Each element is
// Zod-parsed on arrival; a failure quarantines that key (renders a placeholder) and the stream carries on.
import type { El, Registry, SpecLike } from "./catalog";
import { issueSink, parseElement, type Issue } from "./validate";
import { citeRefs, elPath, ptr } from "./walk";

export type NodeStatus = "ready" | "pending" | "quarantined";
export type RenderNode = { key: string; status: NodeStatus; type?: string; children: RenderNode[] };

const ELEMENT = /^\/elements\/([^/]+)$/;
const CHILD = /^\/elements\/([^/]+)\/children\/-$/;
const ROW = /^\/elements\/([^/]+)\/props\/([A-Za-z]+)\/-$/;
const unescape = (s: string) => s.replace(/~1/g, "/").replace(/~0/g, "~");

export class SpecStream {
  private buf = "";
  private line = 0;
  root?: string;
  v?: number;
  readonly elements: Record<string, El> = {};
  readonly quarantined = new Map<string, { type?: string; issues: Issue[] }>();
  readonly issues: Issue[] = [];
  private add = issueSink(this.issues);
  constructor(private reg?: Registry) {}

  /** Feed any chunk of text. Returns the number of complete lines applied. */
  push(chunk: string): number {
    this.buf += chunk;
    let n = 0, nl: number;
    while ((nl = this.buf.indexOf("\n")) >= 0) {
      const text = this.buf.slice(0, nl);
      this.buf = this.buf.slice(nl + 1);
      this.applyLine(text);
      n++;
    }
    return n;
  }

  /** End of stream: a trailing line without "\n" is applied if it parses, otherwise it was truncated. */
  end(): SpecLike {
    if (this.buf.trim()) this.applyLine(this.buf, true);
    this.buf = "";
    return this.spec();
  }

  spec(): SpecLike {
    return { v: this.v ?? 1, root: this.root ?? "", elements: structuredClone(this.elements) };
  }

  private applyLine(text: string, last = false) {
    this.line++;
    if (!text.trim()) return;
    let op: any;
    try { op = JSON.parse(text); } catch {
      return this.add(["$line", this.line], "parse_error", last ? "stream ended mid-line (truncated JSON)" : "line is not valid JSON");
    }
    const rej = (msg: string) => this.add(["$line", this.line], "patch_rejected", msg);
    if (op?.op !== "add" || typeof op.path !== "string") return rej(`only {"op":"add"} is allowed, got ${JSON.stringify(op?.op)}`);
    const { path, value } = op;
    if (path === "/v") { this.v = value; return; }
    if (path === "/root") { if (this.root) return rej("root is already set"); this.root = String(value); return; }
    let m: RegExpMatchArray | null;
    if ((m = path.match(ELEMENT))) {
      const key = unescape(m[1]!);
      if (key in this.elements || this.quarantined.has(key)) return rej(`element "${key}" already exists (append-only)`);
      const r = parseElement(key, value, "model");
      if (!r.el) {
        this.quarantined.set(key, { type: value?.type, issues: r.issues });
        this.issues.push(...r.issues);
        return;
      }
      this.elements[key] = r.el;
      this.checkCites(key, r.el);
      return;
    }
    if ((m = path.match(CHILD))) {
      const el = this.elements[unescape(m[1]!)];
      if (!el?.children) return rej(`no element with children at ${path}`);
      el.children.push(String(value));
      return;
    }
    if ((m = path.match(ROW))) {
      const key = unescape(m[1]!);
      const el = this.elements[key];
      if (!el || !Array.isArray(el.props[m[2]!])) return rej(`no array prop at ${path}`);
      const candidate = structuredClone(el);
      candidate.props[m[2]!].push(value);
      const r = parseElement(key, candidate, "model"); // re-validate the element with the new row; reject only the row
      if (!r.el) { this.issues.push(...r.issues.map((i) => ({ ...i, message: `row rejected: ${i.message}` }))); return; }
      this.elements[key] = r.el;
      this.checkCites(key, r.el);
      return;
    }
    rej(`path ${path} is not an allowed add target`);
  }

  private checkCites(key: string, el: El) {
    if (!this.reg) return;
    const known = new Set(this.reg.citations.map((c) => c.id));
    const seen = new Set(this.issues.filter((i) => i.code === "cite_unknown").map((i) => i.path));
    for (const ref of citeRefs(el.props, elPath(key, "props")))
      if (!known.has(ref.id) && !seen.has(ptr(ref.path))) this.add(ref.path, "cite_unknown", `citation "${ref.id}" is not in this run's citations`, "warn");
  }

  /** The tree the renderer would draw right now. Unknown keys render as pending, bad ones as quarantined. */
  snapshot(): RenderNode | undefined {
    if (!this.root) return undefined;
    const seen = new Set<string>();
    const node = (key: string): RenderNode => {
      if (this.quarantined.has(key)) return { key, status: "quarantined", type: this.quarantined.get(key)!.type, children: [] };
      const el = this.elements[key];
      if (!el || seen.has(key)) return { key, status: "pending", children: [] };
      seen.add(key);
      return { key, status: "ready", type: el.type, children: (el.children ?? []).map(node) };
    };
    return node(this.root);
  }
}

/** Compact one-line rendering of a snapshot, for tests and the demo: Answer(Group(Claim, …roi, ✗split)) */
export function show(n?: RenderNode): string {
  if (!n) return "∅";
  if (n.status === "pending") return `…${n.key}`;
  if (n.status === "quarantined") return `✗${n.key}`;
  return n.children.length ? `${n.type}(${n.children.map(show).join(", ")})` : n.type!;
}

/** Non-streaming convenience: compile a whole JSONL text. */
export function compileJsonl(text: string, reg?: Registry) {
  const s = new SpecStream(reg);
  s.push(text);
  const spec = s.end();
  return { spec, issues: s.issues, quarantined: s.quarantined, stream: s };
}

/** Simulated model token stream: deterministic pseudo-random chunks of 7–40 chars. */
export function* chunkText(text: string, seed = 7): Generator<string> {
  let x = seed;
  const rnd = () => (x = (x * 1103515245 + 12345) % 2 ** 31) / 2 ** 31;
  for (let i = 0; i < text.length; ) { const n = 7 + Math.floor(rnd() * 34); yield text.slice(i, i + n); i += n; }
}

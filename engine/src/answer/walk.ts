export type Path = (string | number)[];

export const MARKER = /\[\^([A-Za-z0-9_-]{1,32})\]/g;

export function pointer(path: Path): string {
  return "/" + path.map((segment) => String(segment).replace(/~/g, "~0").replace(/\//g, "~1")).join("/");
}

export function segments(pointerText: string): string[] {
  return pointerText.split("/").slice(1).map((s) => s.replace(/~1/g, "/").replace(/~0/g, "~"));
}

export function elementPath(key: string, ...rest: Path): Path {
  return ["elements", key, ...rest];
}

export function elementKeyOf(pointerText: string): string | undefined {
  const [first, key] = segments(pointerText);
  return first === "elements" ? key : undefined;
}

export function markers(text: string): string[] {
  return [...text.matchAll(MARKER)].map((m) => m[1]!);
}

export function stripMarkers(text: string): string {
  return text.replace(MARKER, "").replace(/\s+([.,;:!?])/g, "$1").replace(/\s+/g, " ").trim();
}

export function isDatum(node: unknown): node is Record<string, any> {
  return !!node && typeof node === "object" && !Array.isArray(node) && "unit" in node && "basis" in node && "cite" in node;
}

export function visit(node: unknown, path: Path, fn: (node: any, path: Path) => void): void {
  fn(node, path);
  if (Array.isArray(node)) node.forEach((child, index) => visit(child, [...path, index], fn));
  else if (node && typeof node === "object") {
    for (const [key, child] of Object.entries(node)) visit(child, [...path, key], fn);
  }
}

export function forEachDatum(props: unknown, path: Path, fn: (datum: Record<string, any>, path: Path) => void): void {
  visit(props, path, (node, at) => {
    if (isDatum(node)) fn(node, at);
  });
}

export interface CiteRef {
  id: string;
  path: Path;
  inDatum: boolean;
}

export function citeRefs(props: unknown, path: Path): CiteRef[] {
  const refs: CiteRef[] = [];
  visit(props, path, (node, at) => {
    const last = at[at.length - 1];
    if (typeof node === "string") for (const id of markers(node)) refs.push({ id, path: at, inDatum: false });
    else if (Array.isArray(node) && last === "cite") {
      node.forEach((id, index) => typeof id === "string" && refs.push({ id, path: [...at, index], inDatum: true }));
    }
  });
  return refs;
}

export function valueAt(root: unknown, path: Path): any {
  return path.reduce<any>((node, key) => (node == null ? undefined : node[key as any]), root);
}

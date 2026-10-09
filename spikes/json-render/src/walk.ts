// Generic walkers over element props. They work on raw JSON, so validate/resolve/repair share them.
export type Path = (string | number)[];

export const ptr = (p: Path) => "/" + p.map((s) => String(s).replace(/~/g, "~0").replace(/\//g, "~1")).join("/");
export const elPath = (key: string, ...rest: Path): Path => ["elements", key, ...rest];

export const MARKER = /\[\^([^\]\s]+)\]/g;
export const markers = (s: string) => [...s.matchAll(MARKER)].map((m) => m[1]!);

export const isDatum = (x: any): boolean =>
  !!x && typeof x === "object" && !Array.isArray(x) && "unit" in x && "basis" in x && "cite" in x;

/** Visit every object/array node depth-first. */
export function visit(node: any, path: Path, fn: (node: any, path: Path) => void) {
  fn(node, path);
  if (Array.isArray(node)) node.forEach((x, i) => visit(x, [...path, i], fn));
  else if (node && typeof node === "object") for (const [k, v] of Object.entries(node)) visit(v, [...path, k], fn);
}

export function forEachDatum(props: any, path: Path, fn: (d: any, path: Path) => void) {
  visit(props, path, (n, p) => isDatum(n) && fn(n, p));
}

/** Every citation reference in props: `cite` arrays, Rich markers in any string, SourceMix id scopes. */
export function citeRefs(props: any, path: Path): { id: string; path: Path }[] {
  const out: { id: string; path: Path }[] = [];
  visit(props, path, (n, p) => {
    const last = p[p.length - 1];
    if (typeof n === "string") for (const id of markers(n)) out.push({ id, path: p });
    else if (Array.isArray(n) && (last === "cite" || last === "scope"))
      n.forEach((id, i) => typeof id === "string" && out.push({ id, path: [...p, i] }));
  });
  return out;
}

export function getAt(root: any, path: Path): any {
  return path.reduce((n, k) => (n == null ? undefined : n[k as any]), root);
}

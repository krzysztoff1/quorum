import type { Citation } from "./evidence.js";

const MARKER = /\[\^([A-Za-z0-9_-]{1,32})\]/g;

export interface SettledMarkers {
  writeup: string;
  findings: any[];
  citations: Citation[];
  stripped: string[];
}

export function settleMarkers(writeup: string, findings: any[], citations: Citation[],
                              known: Map<string, Citation> = new Map()): SettledMarkers {
  const settled = [...citations];
  const declared = new Set(settled.map((c) => c.id));
  const stripped: string[] = [];

  const settle = (id: string): boolean => {
    if (declared.has(id)) return true;
    const verified = known.get(id);
    if (verified) {
      settled.push({ ...verified, id });
      declared.add(id);
      return true;
    }
    if (!stripped.includes(id)) stripped.push(id);
    return false;
  };

  for (const id of new Set([...writeup.matchAll(MARKER)].map((m) => m[1]!))) settle(id);
  const dangling = new Set(stripped);
  const text = dangling.size === 0 ? writeup : writeup
    .split("\n")
    .filter((line) => !isDefinitionOf(line, dangling))
    .join("\n")
    .replace(MARKER, (marker, id: string) => (dangling.has(id) ? "" : marker));

  const kept = findings.map((finding) => {
    if (!Array.isArray(finding?.citations)) return finding;
    return { ...finding, citations: finding.citations.map(String).filter(settle) };
  });

  return { writeup: text, findings: kept, citations: settled, stripped };
}

function isDefinitionOf(line: string, ids: Set<string>): boolean {
  const definition = /^\[\^([A-Za-z0-9_-]{1,32})\]:/.exec(line.trim());
  return definition !== null && ids.has(definition[1]!);
}

import type { EvidenceStore, SourceDocument } from "./evidence.js";

export const FETCH_CHAR_CAP = 12000;

export function capturedRead(evidence: EvidenceStore, url: string): { document: SourceDocument; text: string } | undefined {
  const document = evidence.findByUrl(url);
  const text = document ? evidence.snapshotText(document.source_id) : undefined;
  return document && text !== undefined ? { document, text } : undefined;
}

export function readPage(document: SourceDocument, url: string, text: string, start: number) {
  const markdown = text.slice(start, start + FETCH_CHAR_CAP);
  const end = start + markdown.length;
  return {
    source_id: document.source_id,
    url,
    title: document.title,
    offset: start,
    total_chars: text.length,
    markdown,
    ...(end < text.length ? { next_offset: end } : {}),
  };
}

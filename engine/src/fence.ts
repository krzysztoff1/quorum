const JSON_FENCE = /```json(?![A-Za-z0-9])/g;

export function lastJsonFence(text: string): number {
  let last = -1;
  for (const match of text.matchAll(JSON_FENCE)) last = match.index;
  return last;
}

export function hasFencedJson(text: string): boolean {
  const open = lastJsonFence(text);
  return open !== -1 && text.indexOf("```", open + 7) !== -1;
}

export function parseFencedJson(text: string): any | undefined {
  const open = lastJsonFence(text);
  if (open === -1) return undefined;
  const close = text.indexOf("```", open + 7);
  if (close === -1) return undefined;
  try {
    return JSON.parse(text.slice(open + 7, close).trim());
  } catch {
    return undefined;
  }
}

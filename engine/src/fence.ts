const JSON_FENCE = /```json(?![A-Za-z0-9])/g;

export function lastJsonFence(text: string): number {
  let last = -1;
  for (const match of text.matchAll(JSON_FENCE)) last = match.index;
  return last;
}

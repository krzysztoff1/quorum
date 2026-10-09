import { parseFencedJson } from "./agent.js";
import type { PlannedAngle } from "./run.js";

interface RawAngle {
  title?: unknown;
  name?: unknown;
  angle?: unknown;
  prompt?: unknown;
  question?: unknown;
  description?: unknown;
}

const TITLE_FALLBACK_LENGTH = 60;

function firstText(...candidates: unknown[]): string {
  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.trim()) return candidate.trim();
  }
  return "";
}

function rawAnglesOf(parsed: unknown): RawAngle[] {
  if (Array.isArray(parsed)) return parsed;
  const wrapped = (parsed as { angles?: unknown } | undefined)?.angles;
  return Array.isArray(wrapped) ? wrapped : [];
}

export function parsePlannedAngles(text: string, count: number, nextAngleId: () => string): PlannedAngle[] {
  const angles: PlannedAngle[] = [];
  for (const raw of rawAnglesOf(parseFencedJson(text))) {
    if (angles.length >= Math.max(1, count)) break;
    if (!raw || typeof raw !== "object") continue;
    const prompt = firstText(raw.prompt, raw.question, raw.description);
    if (!prompt) continue;
    const title = firstText(raw.title, raw.name, raw.angle) || prompt.slice(0, TITLE_FALLBACK_LENGTH);
    angles.push({ angle_id: nextAngleId(), title, prompt });
  }
  return angles;
}

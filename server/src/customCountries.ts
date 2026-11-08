import { QUIZ_COUNTRIES } from "./quizCountries.ts";

const ALLOWED = new Set(QUIZ_COUNTRIES);
export const CUSTOM_MIN = 2;
export const CUSTOM_MAX = 250;

/** A custom race list: 2 to 250 known countries, no duplicates. */
export function normalizeCustomCountries(raw: unknown): string[] | null {
  if (!Array.isArray(raw)) return null;
  if (raw.length < CUSTOM_MIN || raw.length > CUSTOM_MAX) return null;
  const seen = new Set<string>();
  const out: string[] = [];
  for (const item of raw) {
    if (typeof item !== "string" || !ALLOWED.has(item) || seen.has(item)) return null;
    seen.add(item);
    out.push(item);
  }
  return out;
}

/** `countries|click|custom:A\u001fB` bests. The country list must be the allowlist, sorted. */
export function isCustomBestPlace(place: string): boolean {
  if (!place.startsWith("custom:")) return false;
  const names = place.slice("custom:".length).split("\u001f").filter((name) => name.length > 0);
  if (names.length < CUSTOM_MIN || names.length > CUSTOM_MAX) return false;
  const sorted = [...names].sort();
  if (sorted.some((name, index) => name !== names[index])) return false;
  return names.every((name) => ALLOWED.has(name));
}

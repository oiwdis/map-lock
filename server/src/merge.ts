export type JsonObject = Record<string, unknown>;

export interface SyncPayload {
  quizzes: JsonObject[];
  speedruns: JsonObject[];
  speedrunBests: Record<string, number>;
  countries: Record<string, JsonObject>;
}

const REGIONS = ["Africa", "Asia", "Europe", "North America", "South America", "world"] as const;

export function isRegion(value: string): boolean {
  return (REGIONS as readonly string[]).includes(value);
}

export function emptyPayload(): SyncPayload {
  return { quizzes: [], speedruns: [], speedrunBests: {}, countries: {} };
}

export function parsePayload(raw: unknown): SyncPayload {
  const body = (raw && typeof raw === "object") ? raw as JsonObject : {};
  return {
    quizzes: asObjects(body.quizzes).slice(0, 500),
    speedruns: asObjects(body.speedruns).slice(0, 500),
    speedrunBests: asBests(body.speedrunBests),
    countries: asCountryMap(body.countries),
  };
}

/** Union of history by id. Fastest positive time wins for each region. Country rows keep the higher counts. */
export function mergePayload(local: SyncPayload, remote: SyncPayload): SyncPayload {
  return {
    quizzes: unionById(local.quizzes, remote.quizzes),
    speedruns: unionById(local.speedruns, remote.speedruns),
    speedrunBests: mergeBests(local.speedrunBests, remote.speedrunBests),
    countries: mergeCountries(local.countries, remote.countries),
  };
}

function asObjects(value: unknown): JsonObject[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is JsonObject => !!item && typeof item === "object" && !Array.isArray(item));
}

function asBests(value: unknown): Record<string, number> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const out: Record<string, number> = {};
  for (const [key, raw] of Object.entries(value as JsonObject)) {
    if (!isRegion(key) || typeof raw !== "number" || !Number.isFinite(raw) || raw <= 0) continue;
    out[key] = raw;
  }
  return out;
}

function asCountryMap(value: unknown): Record<string, JsonObject> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const out: Record<string, JsonObject> = {};
  for (const [key, raw] of Object.entries(value as JsonObject)) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
    if (key.length === 0 || key.length > 80) continue;
    out[key] = raw as JsonObject;
  }
  return out;
}

function unionById(a: JsonObject[], b: JsonObject[]): JsonObject[] {
  const map = new Map<string, JsonObject>();
  for (const item of [...a, ...b]) {
    const id = typeof item.id === "string" && item.id.length > 0 ? item.id : "";
    if (!id || map.has(id)) continue;
    map.set(id, item);
  }
  return [...map.values()].sort((left, right) => dateOf(right) - dateOf(left)).slice(0, 500);
}

function dateOf(item: JsonObject): number {
  return typeof item.date === "number" && Number.isFinite(item.date) ? item.date : 0;
}

function mergeBests(a: Record<string, number>, b: Record<string, number>): Record<string, number> {
  const out: Record<string, number> = { ...a };
  for (const [key, value] of Object.entries(b)) {
    if (!isRegion(key) || !(value > 0)) continue;
    const previous = out[key];
    out[key] = previous === undefined ? value : Math.min(previous, value);
  }
  return out;
}

function mergeCountries(a: Record<string, JsonObject>, b: Record<string, JsonObject>): Record<string, JsonObject> {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  const out: Record<string, JsonObject> = {};
  for (const key of keys) {
    out[key] = mergeCountry(a[key], b[key]);
  }
  return out;
}

function mergeCountry(a: JsonObject | undefined, b: JsonObject | undefined): JsonObject {
  if (!a) return { ...(b ?? {}) };
  if (!b) return { ...a };
  const seen = Math.max(num(a.seen), num(b.seen));
  const correct = Math.max(num(a.correct), num(b.correct));
  const wrong = Math.max(num(a.wrong), num(b.wrong));
  const box = Math.max(num(a.box), num(b.box));
  const lastA = typeof a.lastSeen === "number" ? a.lastSeen : null;
  const lastB = typeof b.lastSeen === "number" ? b.lastSeen : null;
  const lastSeen = lastA === null ? lastB : lastB === null ? lastA : Math.max(lastA, lastB);
  return {
    ...a,
    ...b,
    seen,
    correct,
    wrong,
    box,
    lastSeen,
  };
}

function num(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

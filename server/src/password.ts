const ITERATIONS = 100_000;
const SALT_BYTES = 16;
const HASH_BYTES = 32;
const WINDOW_MS = 15 * 60 * 1000;
const MAX_FAILURES = 10;

/** Well-formed stand-in so a missing user still pays for one PBKDF2. */
const DUMMY_HASH = `100000$${ "00".repeat(SALT_BYTES) }$${ "11".repeat(HASH_BYTES) }`;

export async function hashPassword(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(SALT_BYTES));
  const hash = await pbkdf2(password, salt, ITERATIONS);
  return `${ITERATIONS}$${toHex(salt)}$${toHex(hash)}`;
}

/** True only when the stored iterations$salt$hash matches. Constant-time on the digest. */
export async function verifyPassword(password: string, stored: string | null): Promise<boolean> {
  const parsed = parseStored(stored ?? DUMMY_HASH);
  if (!parsed) {
    const dummy = parseStored(DUMMY_HASH);
    if (!dummy) return false;
    const actual = await pbkdf2(password, dummy.salt, dummy.iterations);
    timingSafeEqual(actual, dummy.hash);
    return false;
  }
  const actual = await pbkdf2(password, parsed.salt, parsed.iterations);
  const matches = timingSafeEqual(actual, parsed.hash);
  return stored != null && matches;
}

export async function loginIsLimited(db: D1Database, usernameLower: string, ip: string): Promise<boolean> {
  const since = Date.now() - WINDOW_MS;
  const nameCount = await failureCount(db, nameBucket(usernameLower), since);
  const ipCount = await failureCount(db, ipBucket(ip), since);
  return nameCount >= MAX_FAILURES || ipCount >= MAX_FAILURES;
}

export async function recordLoginFailure(db: D1Database, usernameLower: string, ip: string): Promise<void> {
  const now = Date.now();
  await db.prepare("DELETE FROM login_attempts WHERE created_at < ?").bind(now - WINDOW_MS).run();
  await db.batch([
    db.prepare("INSERT INTO login_attempts (bucket, created_at) VALUES (?, ?)").bind(nameBucket(usernameLower), now),
    db.prepare("INSERT INTO login_attempts (bucket, created_at) VALUES (?, ?)").bind(ipBucket(ip), now),
  ]);
}

export function clientIp(request: Request): string {
  const raw = request.headers.get("CF-Connecting-IP") ?? "unknown";
  return raw.slice(0, 80);
}

function nameBucket(usernameLower: string): string {
  return `name:${usernameLower.slice(0, 64)}`;
}

function ipBucket(ip: string): string {
  return `ip:${ip.slice(0, 80)}`;
}

async function failureCount(db: D1Database, bucket: string, since: number): Promise<number> {
  const row = await db.prepare(
    "SELECT COUNT(*) AS n FROM login_attempts WHERE bucket = ? AND created_at >= ?",
  ).bind(bucket, since).first<{ n: number }>();
  return row?.n ?? 0;
}

async function pbkdf2(password: string, salt: Uint8Array, iterations: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt, iterations },
    key,
    HASH_BYTES * 8,
  );
  return new Uint8Array(bits);
}

function parseStored(stored: string): { iterations: number; salt: Uint8Array; hash: Uint8Array } | null {
  const parts = stored.split("$");
  if (parts.length !== 3) return null;
  const iterations = Number(parts[0]);
  const salt = fromHex(parts[1]);
  const hash = fromHex(parts[2]);
  if (!Number.isInteger(iterations) || iterations < 1 || iterations > 2_000_000) return null;
  if (!salt || salt.length !== SALT_BYTES || !hash || hash.length !== HASH_BYTES) return null;
  return { iterations, salt, hash };
}

function timingSafeEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i += 1) diff |= left[i] ^ right[i];
  return diff === 0;
}

function toHex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function fromHex(value: string): Uint8Array | null {
  if (value.length % 2 !== 0 || !/^[0-9a-f]+$/i.test(value)) return null;
  const bytes = new Uint8Array(value.length / 2);
  for (let i = 0; i < bytes.length; i += 1) bytes[i] = Number.parseInt(value.slice(i * 2, i * 2 + 2), 16);
  return bytes;
}

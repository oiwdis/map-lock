const APPLE_KEYS = "https://appleid.apple.com/auth/keys";
const APPLE_ISS = "https://appleid.apple.com";

interface Jwk {
  kty: string;
  kid: string;
  use?: string;
  alg?: string;
  n?: string;
  e?: string;
}

interface AppleClaims {
  sub: string;
  nonce?: string;
}

let cachedKeys: { fetchedAt: number; keys: Jwk[] } | null = null;

export async function verifyAppleIdentityToken(token: string, audience: string, nonce: string | undefined): Promise<AppleClaims> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("malformed token");
  const [headerPart, payloadPart, sigPart] = parts;
  const header = decodeJson(headerPart) as { alg?: string; kid?: string };
  if (header.alg !== "RS256" || !header.kid) throw new Error("unsupported token");
  const payload = decodeJson(payloadPart) as {
    iss?: string;
    aud?: string | string[];
    exp?: number;
    sub?: string;
    nonce?: string;
  };
  if (payload.iss !== APPLE_ISS) throw new Error("bad issuer");
  const aud = payload.aud;
  const audiences = Array.isArray(aud) ? aud : aud ? [aud] : [];
  if (!audiences.includes(audience)) throw new Error("bad audience");
  if (typeof payload.exp !== "number" || payload.exp * 1000 <= Date.now()) throw new Error("expired");
  if (typeof payload.sub !== "string" || payload.sub.length === 0) throw new Error("missing sub");
  if (nonce !== undefined && payload.nonce !== nonce) throw new Error("bad nonce");

  const jwk = await appleKey(header.kid);
  const key = await crypto.subtle.importKey(
    "jwk",
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const data = new TextEncoder().encode(`${headerPart}.${payloadPart}`);
  const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, base64UrlToBytes(sigPart), data);
  if (!ok) throw new Error("bad signature");
  return { sub: payload.sub, nonce: payload.nonce };
}

async function appleKey(kid: string): Promise<Jwk> {
  const now = Date.now();
  if (!cachedKeys || now - cachedKeys.fetchedAt > 60 * 60 * 1000) {
    const response = await fetch(APPLE_KEYS);
    if (!response.ok) throw new Error("apple keys unavailable");
    const body = await response.json() as { keys?: Jwk[] };
    cachedKeys = { fetchedAt: now, keys: body.keys ?? [] };
  }
  const found = cachedKeys.keys.find((key) => key.kid === kid && key.kty === "RSA" && key.n && key.e);
  if (!found) throw new Error("unknown key");
  return found;
}

function decodeJson(part: string): unknown {
  const json = new TextDecoder().decode(base64UrlToBytes(part));
  return JSON.parse(json);
}

function base64UrlToBytes(part: string): Uint8Array {
  const padded = part.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((part.length + 3) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

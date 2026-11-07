const USERNAME_PATTERN = /^[A-Za-z0-9_]{3,20}$/;

/** Obvious blocked words. Matched after lowercasing and removing underscores and digits. */
const BLOCKED = [
  "fuck", "shit", "bitch", "cunt", "dick", "cock", "piss", "asshole",
  "bastard", "slut", "whore", "nigger", "nigga", "faggot", "fag", "retard",
  "rape", "nazi", "hitler",
];

const RESERVED = new Set([
  "admin", "administrator", "support", "maplock", "system", "moderator",
  "mod", "root", "null", "undefined", "friend", "friends",
]);

export type UsernameError = "length" | "characters" | "reserved" | "profanity";

export function usernameProblem(raw: string): UsernameError | null {
  const name = raw.trim();
  if (name.length < 3 || name.length > 20) return "length";
  if (!USERNAME_PATTERN.test(name)) return "characters";
  const folded = name.toLowerCase().replace(/[_0-9]/g, "");
  if (RESERVED.has(name.toLowerCase()) || RESERVED.has(folded)) return "reserved";
  if (BLOCKED.some((word) => folded.includes(word))) return "profanity";
  return null;
}

export function canonicalUsername(raw: string): string {
  return raw.trim();
}

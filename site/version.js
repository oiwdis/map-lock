// Latest Map Lock version for the site badge.
// The site worker inlines this file. Keep the two copies the same:
// site/build.mjs splices this source in above `export default`.

export const APPCAST_URL = "https://raw.githubusercontent.com/oiwdis/map-lock/main/appcast.xml";
export const RELEASE_URL = "https://api.github.com/repos/oiwdis/map-lock/releases/latest";
export const VERSION_RE = /^\d+\.\d+\.\d+$/;
// Last shipped appcast item. Used only when the feed, GitHub, and the cache all fail.
export const FALLBACK_VERSION = "1.3.3";
export const FRESH_TTL = 600;

export function versionFromAppcast(xml) {
  const match = String(xml).match(/<sparkle:shortVersionString>\s*([^<]+?)\s*<\/sparkle:shortVersionString>/);
  if (!match || !VERSION_RE.test(match[1])) return null;
  return match[1];
}

export function versionFromRelease(payload) {
  const tag = payload && payload.tag_name;
  if (typeof tag !== "string") return null;
  const version = tag.replace(/^v/, "");
  return VERSION_RE.test(version) ? version : null;
}

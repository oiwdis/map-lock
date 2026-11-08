// Splices site/version.js into the bundled site worker and points the
// homepage badge at the live version. Safe to run again.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const dir = path.dirname(fileURLToPath(import.meta.url));
const workerPath = path.join(dir, "map-lock-site.js");
let js = fs.readFileSync(workerPath, "utf8");

const oldBadge = "Version 1.1.1 for Mac";
const newBadge = 'Version <span id=\\"ml-version\\">1.3.3</span> for Mac';
if (js.includes(oldBadge)) js = js.replace(oldBadge, newBadge);
if (!js.includes('id=\\"ml-version\\"')) {
  throw new Error("homepage badge marker is missing");
}

const versionSource = fs.readFileSync(path.join(dir, "version.js"), "utf8")
  .replace(/^export /gm, "")
  .replace(/^\/\/.*\n/gm, "")
  .trim();

const runtime = `
const FRESH_KEY = "https://map-lock-site.cache/version/fresh";
const LAST_KEY = "https://map-lock-site.cache/version/last";
let memoryVersion = null;

async function readVersionCache(key) {
  try {
    const hit = await caches.default.match(key);
    if (!hit) return null;
    const text = (await hit.text()).trim();
    return VERSION_RE.test(text) ? text : null;
  } catch (e) {
    return null;
  }
}

async function writeVersionCache(key, value, ttl) {
  try {
    await caches.default.put(key, new Response(value, {
      headers: { "Cache-Control": "public, max-age=" + ttl, "Content-Type": "text/plain; charset=utf-8" },
    }));
  } catch (e) {}
}

async function fetchLatestVersion() {
  try {
    const res = await fetch(APPCAST_URL, {
      cf: { cacheTtl: FRESH_TTL, cacheEverything: true },
      headers: { "User-Agent": "map-lock-site", "Accept": "application/xml, text/xml, */*" },
      signal: AbortSignal.timeout(4000),
    });
    if (res.ok) {
      const version = versionFromAppcast(await res.text());
      if (version) return version;
    }
  } catch (e) {}
  try {
    const res = await fetch(RELEASE_URL, {
      cf: { cacheTtl: FRESH_TTL, cacheEverything: true },
      headers: { "User-Agent": "map-lock-site", "Accept": "application/vnd.github+json" },
      signal: AbortSignal.timeout(4000),
    });
    if (res.ok) {
      const version = versionFromRelease(await res.json());
      if (version) return version;
    }
  } catch (e) {}
  return null;
}

async function latestVersion(ctx) {
  const fresh = await readVersionCache(FRESH_KEY);
  if (fresh) return fresh;
  const version = await fetchLatestVersion();
  if (version) {
    memoryVersion = version;
    const write = Promise.all([
      writeVersionCache(FRESH_KEY, version, FRESH_TTL),
      writeVersionCache(LAST_KEY, version, 60 * 60 * 24 * 30),
    ]);
    if (ctx && ctx.waitUntil) ctx.waitUntil(write);
    else await write;
    return version;
  }
  if (memoryVersion) return memoryVersion;
  const last = await readVersionCache(LAST_KEY);
  if (last) {
    memoryVersion = last;
    return last;
  }
  return FALLBACK_VERSION;
}

class MacVersion {
  constructor(version) { this.version = version; }
  element(element) { element.setInnerContent(this.version); }
}

function page(html, version) {
  const response = H(html);
  if (!version) return response;
  return new HTMLRewriter().on("#ml-version", new MacVersion(version)).transform(response);
}
`;

const fetchFn = `export default{async fetch(req,env,ctx){const u=new URL(req.url);{const q=u.pathname;if(q.startsWith('/v1')||q.startsWith('/race/')||q==='/health')return env.API.fetch(req)}if(u.hostname.startsWith('get-map-lock.'))return Response.redirect('https://map-lock.elliot-7c9.workers.dev'+u.pathname+u.search,301);const p=u.pathname;if(p==='/w50.json'||p==='/demo/w50.json'){const buf=await gunzipB64(W50GZ);return new Response(buf,{headers:{'content-type':'application/json; charset=utf-8','cache-control':'public, max-age=86400','content-encoding':'identity'}})}const a=A[p];if(a){const bin=Uint8Array.from(atob(a[1]),c=>c.charCodeAt(0));return new Response(bin,{headers:{'content-type':a[0],'cache-control':'public, max-age=86400'}})}if(p==='/demo'||p==='/demo/'||p==='/demo/index.html')return H(DEMO);if(p==='/'||p==='/index.html'){const version=await latestVersion(ctx);return page(HTML,version)}return new Response('Not found',{status:404,headers:{'content-type':'text/plain'}})}};
`;

const marker = "const APPCAST_URL";
const exportAt = js.lastIndexOf("export default");
if (exportAt < 0) throw new Error("export default missing");
const head = js.slice(0, exportAt);
const withoutOld = (head.includes(marker) ? head.slice(0, head.indexOf(marker)) : head).replace(/\s+$/, "");
js = withoutOld + "\n" + versionSource + "\n" + runtime.trim() + "\n" + fetchFn.trim() + "\n";

if (!js.includes("env.API.fetch(req)")) throw new Error("API proxy was dropped");
if (js.includes("1.1.1")) throw new Error("old version badge remains");
if (!js.includes("Requires macOS 14 or later")) throw new Error("macOS requirement missing");
if (!js.includes("HTMLRewriter")) throw new Error("HTMLRewriter missing");

fs.writeFileSync(workerPath, js);
console.log("wrote", workerPath, js.length);

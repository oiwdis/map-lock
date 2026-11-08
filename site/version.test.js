import test from "node:test";
import assert from "node:assert/strict";
import { APPCAST_URL, versionFromAppcast, versionFromRelease } from "./version.js";

const appcast = `<?xml version="1.0"?>
<rss><channel>
  <item><sparkle:shortVersionString>9.9.9</sparkle:shortVersionString></item>
  <item><sparkle:shortVersionString>1.0.0</sparkle:shortVersionString></item>
</channel></rss>`;

test("appcast uses the first shortVersionString", () => {
  assert.equal(versionFromAppcast(appcast), "9.9.9");
});

test("appcast ignores a version that is not x.y.z", () => {
  assert.equal(versionFromAppcast(`<sparkle:shortVersionString>beta</sparkle:shortVersionString>`), null);
  assert.equal(versionFromAppcast(""), null);
});

test("live appcast's first item is a version", async () => {
  const xml = await fetch(APPCAST_URL).then((res) => res.text());
  const version = versionFromAppcast(xml);
  assert.match(version ?? "", /^\d+\.\d+\.\d+$/);
  assert.notEqual(version, "1.1.1");
});

test("GitHub release tag drops a leading v", () => {
  assert.equal(versionFromRelease({ tag_name: "v1.3.3" }), "1.3.3");
  assert.equal(versionFromRelease({ tag_name: "1.3.4" }), "1.3.4");
  assert.equal(versionFromRelease({ tag_name: "v1.3" }), null);
  assert.equal(versionFromRelease(null), null);
});

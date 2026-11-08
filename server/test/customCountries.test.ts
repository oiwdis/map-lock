import assert from "node:assert/strict";
import test from "node:test";
import { isCustomBestPlace, normalizeCustomCountries } from "../src/customCountries.ts";
import { QUIZ_COUNTRIES } from "../src/quizCountries.ts";

const [a, b, c] = QUIZ_COUNTRIES;

test("a custom list needs two known countries", () => {
  assert.equal(normalizeCustomCountries([a]), null);
  assert.deepEqual(normalizeCustomCountries([b, a]), [b, a]);
  assert.equal(normalizeCustomCountries([a, a]), null);
  assert.equal(normalizeCustomCountries(["Not A Country", b]), null);
});

test("a custom best key is the sorted country list", () => {
  const place = `custom:${[a, b].sort().join("\u001f")}`;
  assert.equal(isCustomBestPlace(place), true);
  const unsorted = [b, a].join("\u001f");
  const sorted = [a, b].slice().sort().join("\u001f");
  assert.equal(isCustomBestPlace(`custom:${unsorted}`), unsorted === sorted);
  assert.equal(isCustomBestPlace("custom:Nope"), false);
  assert.equal(c.length > 0, true);
});

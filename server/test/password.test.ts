import assert from "node:assert/strict";
import { test } from "node:test";
import { hashPassword, verifyPassword } from "../src/password.ts";

test("password hash is PBKDF2 iterations$salt$hash and checks in constant time", async () => {
  const stored = await hashPassword("correct horse");
  const [iterations, salt, hash] = stored.split("$");
  assert.equal(iterations, "100000");
  assert.equal(salt.length, 32);
  assert.equal(hash.length, 64);
  assert.equal(await verifyPassword("correct horse", stored), true);
  assert.equal(await verifyPassword("wrong horse", stored), false);
  assert.equal(await verifyPassword("correct horse", null), false);
  assert.equal(await verifyPassword("correct horse", "not-a-hash"), false);
});

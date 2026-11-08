import assert from "node:assert/strict";
import test from "node:test";
import { RACE_INVITE_TTL_MS, planInviteAccept, raceInviteIsPending } from "../src/invites.ts";

const now = 1_000_000_000_000;

test("a fresh invite to an open race can be joined", () => {
  const invite = { status: "pending", createdAt: now - 60_000 };
  assert.equal(raceInviteIsPending(invite, "open", now), true);
  assert.deepEqual(planInviteAccept(invite, "open", now), { action: "accept" });
});

test("an invite older than 10 minutes is not listed or joinable", () => {
  const invite = { status: "pending", createdAt: now - RACE_INVITE_TTL_MS };
  assert.equal(raceInviteIsPending(invite, "open", now), false);
  assert.deepEqual(planInviteAccept(invite, "open", now), { action: "unavailable" });
});

test("a cancelled or started race drops the invite", () => {
  const invite = { status: "pending", createdAt: now - 1_000 };
  assert.equal(raceInviteIsPending(invite, "cancelled", now), false);
  assert.equal(raceInviteIsPending(invite, "started", now), false);
  assert.deepEqual(planInviteAccept(invite, "cancelled", now), { action: "unavailable" });
});

test("accepted and declined invites are not pending", () => {
  assert.equal(raceInviteIsPending({ status: "accepted", createdAt: now }, "open", now), false);
  assert.equal(raceInviteIsPending({ status: "declined", createdAt: now }, "open", now), false);
});

test("a missing invite is not an expired race", () => {
  assert.deepEqual(planInviteAccept(null, "open", now), { action: "missing" });
});

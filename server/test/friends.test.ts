import assert from "node:assert/strict";
import test from "node:test";
import { planFriendRequest } from "../src/friends.ts";

test("a new pair creates a request", () => {
  assert.deepEqual(planFriendRequest(null, "b"), { action: "create" });
});

test("a pending request the other way is accepted", () => {
  assert.deepEqual(
    planFriendRequest({ id: "row", status: "pending", requester_id: "a" }, "b"),
    { action: "accept", id: "row" },
  );
});

test("sending the same request twice still waits", () => {
  assert.deepEqual(
    planFriendRequest({ id: "row", status: "pending", requester_id: "b" }, "b"),
    { action: "error", status: 409, error: "A request is already waiting" },
  );
});

test("friends stay friends", () => {
  assert.deepEqual(
    planFriendRequest({ id: "row", status: "accepted", requester_id: "a" }, "b"),
    { action: "error", status: 409, error: "You are already friends" },
  );
});

test("a declined request can be asked again", () => {
  assert.deepEqual(
    planFriendRequest({ id: "row", status: "declined", requester_id: "a" }, "b"),
    { action: "reopen", id: "row" },
  );
});

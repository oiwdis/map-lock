import assert from "node:assert/strict";
import test from "node:test";
import {
  applyRematchMessage,
  claimRematchCode,
  closeRematchFor,
  rematchIsReady,
  rematchTally,
  type RematchPlayer,
  type RematchVoteState,
} from "../src/rematch.ts";

function players(): RematchPlayer[] {
  return [
    { userId: "a", connected: true, left: false, wantsRematch: false },
    { userId: "b", connected: true, left: false, wantsRematch: false },
  ];
}

function state(list = players()): RematchVoteState {
  return { players: list, closed: false, rematchCode: null };
}

test("the count starts at zero and grows with each vote", () => {
  let next = state();
  assert.deepEqual(rematchTally(next.players), { votes: 0, total: 2 });
  next = applyRematchMessage(next, "a", "rematch");
  assert.equal(rematchTally(next.players).votes, 1);
  assert.equal(rematchIsReady(next.players, null, false), false);
  next = applyRematchMessage(next, "b", "rematch");
  assert.deepEqual(rematchTally(next.players), { votes: 2, total: 2 });
  assert.equal(rematchIsReady(next.players, null, false), true);
});

test("a player can take the vote back", () => {
  let next = applyRematchMessage(state(), "a", "rematch");
  next = applyRematchMessage(next, "a", "unrematch");
  assert.equal(next.players[0]?.wantsRematch, false);
  assert.equal(rematchIsReady(next.players, null, false), false);
});

test("a third player is part of the count", () => {
  const list = players();
  list.push({ userId: "c", connected: true, left: false, wantsRematch: false });
  let next = state(list);
  next = applyRematchMessage(next, "a", "rematch");
  next = applyRematchMessage(next, "b", "rematch");
  assert.deepEqual(rematchTally(next.players), { votes: 2, total: 3 });
  assert.equal(rematchIsReady(next.players, null, false), false);
  next = applyRematchMessage(next, "c", "rematch");
  assert.equal(rematchIsReady(next.players, null, false), true);
});

test("leaving closes the rematch and drops that vote", () => {
  let next = applyRematchMessage(state(), "a", "rematch");
  next = closeRematchFor(next, "b");
  assert.equal(next.closed, true);
  assert.equal(next.players[1]?.left, true);
  next = applyRematchMessage(next, "a", "rematch");
  assert.equal(rematchTally(next.players).votes, 1);
  assert.equal(rematchIsReady(next.players, null, next.closed), false);
});

test("two claims at the same moment keep one race code", () => {
  const first = claimRematchCode(null, "RACE1111");
  const second = claimRematchCode(first.code, "RACE2222");
  assert.equal(first.created, true);
  assert.equal(second.created, false);
  assert.equal(second.code, "RACE1111");
  assert.equal(rematchIsReady(players().map((player) => ({ ...player, wantsRematch: true })), second.code, false), false);
});

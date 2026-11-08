import assert from "node:assert/strict";
import test from "node:test";
import {
  FINISH_DISCONNECT_MS,
  FINISH_WAIT_MS,
  judgeTimes,
  lockFinish,
  nextAlarm,
  runnerHasLost,
  sameTime,
  stepRace,
  type RulePlayer,
  type RuleRace,
} from "../src/raceRules.ts";

function player(id: string, extra: Partial<RulePlayer> = {}): RulePlayer {
  return {
    userId: id,
    finished: false,
    forfeited: false,
    dnf: false,
    connected: true,
    disconnectedAt: null,
    misses: 0,
    skips: 0,
    found: 0,
    total: 10,
    raw: null,
    elapsed: null,
    finishedAt: null,
    ...extra,
  };
}

function race(players: RulePlayer[], extra: Partial<RuleRace> = {}): RuleRace {
  return {
    phase: "racing",
    startedAt: 1_000_000,
    firstFinishAt: null,
    decided: false,
    tie: false,
    winnerId: null,
    reason: null,
    players,
    ...extra,
  };
}

test("the same tenth of a second is a tie", () => {
  assert.equal(sameTime(83.44, 83.36), true);
  assert.equal(sameTime(83.44, 83.46), false);
  const a = player("a", { finished: true, elapsed: 83.44 });
  const b = player("b", { finished: true, elapsed: 83.36 });
  assert.deepEqual(judgeTimes(a, b), { winnerId: null, tie: true });
});

test("a faster locked time wins", () => {
  const a = player("a", { finished: true, elapsed: 70 });
  const b = player("b", { finished: true, elapsed: 74.2 });
  assert.deepEqual(judgeTimes(a, b), { winnerId: "a", tie: false });
});

test("the first finish does not end the race", () => {
  const a = player("a");
  const b = player("b");
  const state = race([a, b]);
  lockFinish(a, state.startedAt!, 1_000_000 + 80_000);
  state.firstFinishAt = 1_000_000 + 80_000;
  stepRace(state, 1_000_000 + 80_000);
  assert.equal(state.phase, "racing");
  assert.equal(state.decided, false);
  assert.equal(a.elapsed, 80);
});

test("the finisher wins once the other player's time is worse", () => {
  const a = player("a", { finished: true, elapsed: 80, raw: 80, finishedAt: 1_080_000 });
  const b = player("b", { misses: 0, skips: 0 });
  const state = race([a, b], { firstFinishAt: 1_080_000 });
  assert.equal(runnerHasLost(80.6, 80), true);
  stepRace(state, 1_000_000 + 80_600);
  assert.equal(state.phase, "racing");
  assert.equal(state.decided, true);
  assert.equal(state.winnerId, "a");
  assert.equal(state.tie, false);
});

test("both finishes close the race, and a tenth is a tie", () => {
  const a = player("a");
  const b = player("b");
  const state = race([a, b]);
  lockFinish(a, state.startedAt!, 1_083_440);
  lockFinish(b, state.startedAt!, 1_083_360);
  state.firstFinishAt = 1_083_440;
  stepRace(state, 1_083_360);
  assert.equal(state.phase, "finished");
  assert.equal(state.tie, true);
  assert.equal(state.winnerId, null);
  assert.equal(state.reason, "time");
});

test("five minutes after the first finish is a DNF", () => {
  const a = player("a", { finished: true, elapsed: 90, raw: 90 });
  const b = player("b", { found: 3 });
  const first = 2_000_000;
  const state = race([a, b], { firstFinishAt: first, startedAt: 1_000_000 });
  stepRace(state, first + FINISH_WAIT_MS);
  assert.equal(state.phase, "finished");
  assert.equal(b.dnf, true);
  assert.equal(state.winnerId, "a");
  assert.equal(state.reason, "dnf");
});

test("a disconnect of 60s after a finish is a DNF", () => {
  const a = player("a", { finished: true, elapsed: 50, raw: 50 });
  const b = player("b", { connected: false, disconnectedAt: 5_000_000 });
  const state = race([a, b], { firstFinishAt: 4_900_000, startedAt: 4_000_000 });
  stepRace(state, 5_000_000 + FINISH_DISCONNECT_MS);
  assert.equal(state.phase, "finished");
  assert.equal(b.dnf, true);
  assert.equal(state.winnerId, "a");
});

test("both disconnecting before anyone finishes ends with no winner", () => {
  const a = player("a", { connected: false, disconnectedAt: 3_000_000 });
  const b = player("b", { connected: false, disconnectedAt: 3_010_000 });
  const state = race([a, b], { startedAt: 1_000_000 });
  stepRace(state, 3_010_000 + 20_000);
  assert.equal(state.phase, "finished");
  assert.equal(state.winnerId, null);
  assert.equal(state.tie, false);
  assert.equal(state.reason, "disconnect");
});

test("a forfeit gives the other player the win", () => {
  const a = player("a", { forfeited: true, finished: true });
  const b = player("b", { found: 4 });
  const state = race([a, b]);
  stepRace(state, 1_050_000);
  assert.equal(state.phase, "finished");
  assert.equal(state.winnerId, "b");
  assert.equal(state.reason, "forfeit");
});

test("the next alarm waits for the moment the other player loses", () => {
  const a = player("a", { finished: true, elapsed: 10, raw: 10 });
  const b = player("b");
  const state = race([a, b], { firstFinishAt: 1_010_000, startedAt: 1_000_000 });
  const when = nextAlarm(state, 1_005_000);
  assert.ok(when != null && when > 1_005_000);
});

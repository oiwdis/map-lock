import assert from "node:assert/strict";
import test from "node:test";
import { mergePayload, parsePayload } from "../src/merge.ts";
import { usernameProblem } from "../src/username.ts";

test("username rules", () => {
  assert.equal(usernameProblem("ab"), "length");
  assert.equal(usernameProblem("a".repeat(21)), "length");
  assert.equal(usernameProblem("bad name"), "characters");
  assert.equal(usernameProblem("maplock"), "reserved");
  assert.equal(usernameProblem("xxfuckyy"), "profanity");
  assert.equal(usernameProblem("Ada_1"), null);
});

test("merge unions history and keeps the faster best", () => {
  const local = parsePayload({
    quizzes: [{ id: "q1", date: 10, score: 1 }],
    speedruns: [{ id: "s1", date: 5 }],
    speedrunBests: { Europe: 40, world: 100 },
    countries: { France: { seen: 2, correct: 1, wrong: 1, box: 1, lastSeen: 4 } },
  });
  const remote = parsePayload({
    quizzes: [{ id: "q1", date: 10 }, { id: "q2", date: 12 }],
    speedruns: [{ id: "s2", date: 9 }],
    speedrunBests: { Europe: 30, Asia: 15 },
    countries: { France: { seen: 3, correct: 3, wrong: 0, box: 2, lastSeen: 8 } },
  });
  const merged = mergePayload(local, remote);
  assert.deepEqual(merged.quizzes.map((item) => item.id), ["q2", "q1"]);
  assert.deepEqual(merged.speedruns.map((item) => item.id), ["s2", "s1"]);
  assert.equal(merged.speedrunBests.Europe, 30);
  assert.equal(merged.speedrunBests.Asia, 15);
  assert.equal(merged.speedrunBests.world, 100);
  assert.equal(merged.countries.France.seen, 3);
  assert.equal(merged.countries.France.correct, 3);
  assert.equal(merged.countries.France.wrong, 1);
  assert.equal(merged.countries.France.box, 2);
});

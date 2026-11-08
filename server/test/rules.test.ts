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
  assert.equal(merged.speedrunBests["countries|click|Europe"], 30);
  assert.equal(merged.speedrunBests["countries|click|Asia"], 15);
  assert.equal(merged.speedrunBests["countries|click|world"], 100);
  assert.equal(merged.countries.France.seen, 3);
  assert.equal(merged.countries.France.correct, 3);
  assert.equal(merged.countries.France.wrong, 1);
  assert.equal(merged.countries.France.box, 2);
});

test("a reset stamp drops older stats and ignores an older upload", () => {
  const wiped = parsePayload({ clearedAt: 50 });
  const older = parsePayload({
    quizzes: [{ id: "q1", date: 10 }],
    speedrunBests: { Europe: 20 },
    countries: { France: { seen: 4, correct: 1, wrong: 3, box: 1 } },
  });
  const kept = mergePayload(wiped, older);
  assert.equal(kept.clearedAt, 50);
  assert.deepEqual(kept.quizzes, []);
  assert.deepEqual(kept.speedrunBests, {});

  const again = parsePayload({
    clearedAt: 50,
    quizzes: [{ id: "q3", date: 60 }],
    speedrunBests: { Europe: 12 },
  });
  const after = mergePayload(wiped, again);
  assert.deepEqual(after.quizzes.map((item) => item.id), ["q3"]);
  assert.equal(after.speedrunBests["countries|click|Europe"], 12);

  const newerWipe = parsePayload({ clearedAt: 80 });
  const replaced = mergePayload(after, newerWipe);
  assert.equal(replaced.clearedAt, 80);
  assert.deepEqual(replaced.quizzes, []);
  assert.deepEqual(replaced.speedrunBests, {});
});

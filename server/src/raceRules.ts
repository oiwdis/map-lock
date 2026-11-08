export const MISS_PENALTY_S = 3;
export const SKIP_PENALTY_S = 10;
/** After the first finish, the other player has this long before a DNF. */
export const FINISH_WAIT_MS = 5 * 60 * 1000;
/** A disconnect during that wait. */
export const FINISH_DISCONNECT_MS = 60_000;
/** A disconnect while both are still racing. */
export const LIVE_DISCONNECT_MS = 20_000;
export const RACE_LIMIT_MS = 10 * 60 * 1000;

export type RaceReason = "time" | "forfeit" | "dnf" | "disconnect";

export interface RulePlayer {
  userId: string;
  finished: boolean;
  forfeited: boolean;
  dnf: boolean;
  connected: boolean;
  disconnectedAt: number | null;
  misses: number;
  skips: number;
  found: number;
  total: number;
  raw: number | null;
  elapsed: number | null;
  finishedAt: number | null;
}

export interface RuleRace {
  phase: "waiting" | "countdown" | "racing" | "finished" | "cancelled";
  startedAt: number | null;
  firstFinishAt: number | null;
  decided: boolean;
  tie: boolean;
  winnerId: string | null;
  reason: RaceReason | null;
  players: RulePlayer[];
}

export function withPenalties(raw: number, misses: number, skips: number): number {
  return Math.max(0, raw) + misses * MISS_PENALTY_S + skips * SKIP_PENALTY_S;
}

/** Tenth of a second, rounded, so 1:23.40 and 1:23.44 are the same time. */
export function tenth(seconds: number): number {
  return Math.round(seconds * 10);
}

export function sameTime(a: number, b: number): boolean {
  return tenth(a) === tenth(b);
}

export function runningElapsed(startedAt: number, now: number, misses: number, skips: number): number {
  const raw = Math.max(0, (now - startedAt) / 1000);
  return withPenalties(raw, misses, skips);
}

/** True when the player still going can no longer tie the locked time. */
export function runnerHasLost(running: number, locked: number): boolean {
  return tenth(running) > tenth(locked);
}

export function lockFinish(player: RulePlayer, startedAt: number, now: number): void {
  player.finished = true;
  player.finishedAt = now;
  player.raw = Math.max(0, (now - startedAt) / 1000);
  player.elapsed = withPenalties(player.raw, player.misses, player.skips);
}

function closeRace(state: RuleRace, reason: RaceReason): void {
  state.phase = "finished";
  state.reason = reason;
  state.decided = true;
}

function finisher(state: RuleRace): RulePlayer | undefined {
  return state.players.find((player) => player.finished && !player.forfeited && !player.dnf && player.elapsed != null);
}

/** Compare two locked times. Same tenth is a tie. */
export function judgeTimes(a: RulePlayer, b: RulePlayer): { winnerId: string | null; tie: boolean } {
  const ae = a.elapsed ?? Number.POSITIVE_INFINITY;
  const be = b.elapsed ?? Number.POSITIVE_INFINITY;
  if (sameTime(ae, be)) return { winnerId: null, tie: true };
  return { winnerId: ae < be ? a.userId : b.userId, tie: false };
}

/**
 * Move a live race forward. Call this on progress, forfeit, disconnect, and the alarm.
 * The first finisher does not end the race. The result locks when the other player
 * can no longer tie, both have finished, or the other player is a DNF.
 */
export function stepRace(state: RuleRace, now: number): void {
  if (state.phase !== "racing" && state.phase !== "countdown") return;
  if (state.phase === "countdown") return;

  resolveDisconnects(state, now);
  if (state.phase !== "racing") return;
  resolveWaitCap(state, now);
  if (state.phase !== "racing") return;
  resolveRaceLimit(state, now);
  if (state.phase !== "racing") return;
  resolveRunning(state, now);
  resolveBothFinished(state);
}

function resolveDisconnects(state: RuleRace, now: number): void {
  const players = state.players;
  if (players.length === 2 && players.every((player) => !player.connected && player.disconnectedAt)) {
    const later = Math.max(...players.map((player) => player.disconnectedAt ?? now));
    const wait = players.some((player) => player.finished && !player.dnf && !player.forfeited)
      ? FINISH_DISCONNECT_MS
      : LIVE_DISCONNECT_MS;
    if (now - later >= wait) {
      const done = finisher(state);
      for (const player of players) {
        if (!player.finished && !player.forfeited) player.dnf = true;
      }
      if (done) {
        state.winnerId = done.userId;
        state.tie = false;
        closeRace(state, "dnf");
      } else {
        state.winnerId = null;
        state.tie = false;
        closeRace(state, "disconnect");
      }
      return;
    }
  }

  const someoneFinished = players.some((player) => player.finished && !player.dnf && !player.forfeited);
  const limit = someoneFinished ? FINISH_DISCONNECT_MS : LIVE_DISCONNECT_MS;
  for (const player of players) {
    if (player.finished || player.forfeited || player.dnf || player.connected || !player.disconnectedAt) continue;
    if (now - player.disconnectedAt < limit) continue;
    if (someoneFinished) player.dnf = true;
    else {
      player.forfeited = true;
      player.finished = true;
    }
  }

  const forfeiter = players.find((player) => player.forfeited);
  if (forfeiter) {
    const other = players.find((player) => player.userId !== forfeiter.userId && !player.forfeited);
    state.winnerId = other?.userId ?? null;
    state.tie = false;
    closeRace(state, "forfeit");
    return;
  }

  const done = finisher(state);
  if (done && players.some((player) => player.dnf)) {
    state.winnerId = done.userId;
    state.tie = false;
    closeRace(state, "dnf");
  }
}

function resolveWaitCap(state: RuleRace, now: number): void {
  if (!state.firstFinishAt || now - state.firstFinishAt < FINISH_WAIT_MS) return;
  let marked = false;
  for (const player of state.players) {
    if (!player.finished && !player.forfeited && !player.dnf) {
      player.dnf = true;
      marked = true;
    }
  }
  if (!marked && !state.players.some((player) => player.dnf)) return;
  const done = finisher(state);
  state.winnerId = done?.userId ?? null;
  state.tie = false;
  closeRace(state, done ? "dnf" : "disconnect");
}

function resolveRaceLimit(state: RuleRace, now: number): void {
  if (!state.startedAt || now - state.startedAt < RACE_LIMIT_MS) return;
  if (state.players.some((player) => player.finished && !player.dnf && !player.forfeited)) return;
  const ranked = state.players.filter((player) => !player.forfeited)
    .sort((a, b) => b.found - a.found || a.misses - b.misses || a.skips - b.skips);
  state.winnerId = ranked[0]?.userId ?? null;
  state.tie = false;
  closeRace(state, "time");
}

function resolveRunning(state: RuleRace, now: number): void {
  if (!state.startedAt || state.decided) return;
  const done = state.players.filter((player) => player.finished && !player.forfeited && !player.dnf && player.elapsed != null);
  const going = state.players.filter((player) => !player.finished && !player.forfeited && !player.dnf);
  if (done.length !== 1 || going.length !== 1) return;
  const running = runningElapsed(state.startedAt, now, going[0].misses, going[0].skips);
  if (!runnerHasLost(running, done[0].elapsed ?? 0)) return;
  state.decided = true;
  state.winnerId = done[0].userId;
  state.tie = false;
  state.reason = "time";
}

function resolveBothFinished(state: RuleRace): void {
  const contenders = state.players.filter((player) => !player.forfeited && !player.dnf);
  if (contenders.length < 2 || contenders.some((player) => !player.finished || player.elapsed == null)) return;
  const judged = judgeTimes(contenders[0], contenders[1]);
  state.winnerId = judged.winnerId;
  state.tie = judged.tie;
  closeRace(state, "time");
}

/** When to wake the race next. Null means nothing to wait for. */
export function nextAlarm(state: RuleRace, now: number): number | null {
  if (state.phase !== "racing" || !state.startedAt) return null;
  let when = state.startedAt + RACE_LIMIT_MS;
  if (state.firstFinishAt) when = Math.min(when, state.firstFinishAt + FINISH_WAIT_MS);
  const someoneFinished = state.players.some((player) => player.finished && !player.dnf && !player.forfeited);
  const limit = someoneFinished ? FINISH_DISCONNECT_MS : LIVE_DISCONNECT_MS;
  for (const player of state.players) {
    if (player.finished || player.forfeited || player.dnf || player.connected || !player.disconnectedAt) continue;
    const at = player.disconnectedAt + limit;
    if (at > now && at < when) when = at;
  }
  if (state.players.length === 2 && state.players.every((player) => !player.connected && player.disconnectedAt)) {
    const later = Math.max(...state.players.map((player) => player.disconnectedAt ?? now));
    const at = later + limit;
    if (at > now && at < when) when = at;
  }
  const done = state.players.find((player) => player.finished && !player.forfeited && !player.dnf && player.elapsed != null);
  const going = state.players.find((player) => !player.finished && !player.forfeited && !player.dnf);
  if (done && going && !state.decided && done.elapsed != null) {
    const penalties = going.misses * MISS_PENALTY_S + going.skips * SKIP_PENALTY_S;
    const target = (tenth(done.elapsed) + 0.5) / 10;
    const rawNeeded = target - penalties;
    const at = state.startedAt + Math.max(0, rawNeeded) * 1000;
    if (at > now && at < when) when = at;
  }
  return when > now ? when : null;
}

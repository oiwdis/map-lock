/** Rematch votes on a finished race. The race row is the source of truth. */

export interface RematchPlayer {
  userId: string;
  connected: boolean;
  left: boolean;
  wantsRematch: boolean;
}

export interface RematchVoteState {
  players: RematchPlayer[];
  closed: boolean;
  rematchCode: string | null;
}

export function rematchTally(players: RematchPlayer[]): { votes: number; total: number } {
  return {
    votes: players.filter((player) => player.wantsRematch).length,
    total: players.length,
  };
}

/**
 * Everyone still on the results screen has voted, and no successor race exists yet.
 * A player who left or dropped out makes a rematch impossible.
 */
export function rematchIsReady(players: RematchPlayer[], rematchCode: string | null, closed: boolean): boolean {
  if (rematchCode || closed) return false;
  if (players.length < 2) return false;
  if (players.some((player) => player.left || !player.connected)) return false;
  return players.every((player) => player.wantsRematch);
}

/** Vote or take a vote back. Ignored once the rematch exists or someone has left. */
export function applyRematchMessage(
  state: RematchVoteState,
  userId: string,
  kind: "rematch" | "unrematch",
): RematchVoteState {
  if (state.closed || state.rematchCode) return state;
  const players = state.players.map((player) => {
    if (player.userId !== userId || player.left || !player.connected) return player;
    return { ...player, wantsRematch: kind === "rematch" };
  });
  return { ...state, players };
}

/** The results screen closed. Later votes cannot start a second lobby. */
export function closeRematchFor(state: RematchVoteState, userId: string): RematchVoteState {
  if (state.rematchCode) return state;
  let found = false;
  const players = state.players.map((player) => {
    if (player.userId !== userId) return player;
    found = true;
    return { ...player, left: true, connected: false, wantsRematch: false };
  });
  if (!found) return state;
  return { ...state, players, closed: true };
}

/**
 * The first claim wins. A second vote arriving at the same time keeps that code
 * instead of minting another race.
 */
export function claimRematchCode(existing: string | null, minted: string): { code: string; created: boolean } {
  if (existing) return { code: existing, created: false };
  return { code: minted, created: true };
}

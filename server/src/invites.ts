/** A race invite stays pending for this long, then it is too old to join from the notification. */
export const RACE_INVITE_TTL_MS = 10 * 60 * 1000;

export const RACE_UNAVAILABLE = "This race is no longer available";

export interface InviteClock {
  status: string;
  createdAt: number;
}

/** Pending, the race is still open, and the invite is not older than the time limit. */
export function raceInviteIsPending(invite: InviteClock, raceStatus: string, now: number): boolean {
  if (invite.status !== "pending") return false;
  if (raceStatus !== "open") return false;
  return now - invite.createdAt < RACE_INVITE_TTL_MS;
}

export type InviteAcceptPlan =
  | { action: "accept" }
  | { action: "missing" }
  | { action: "unavailable" };

/**
 * Whether the person who was invited can still join from that invite.
 * `unavailable` means the row exists but the race was cancelled, started, or the invite is too old.
 */
/**
 * An open race with no invite still waiting should close.
 * `declined` when someone said no and nobody else is still pending.
 * `expired` when the last pending invite ran out of time.
 * A race with no invites, or one that already started, stays as it is.
 */
export function planChallengeSettle(
  raceStatus: string,
  invites: { status: string; createdAt: number }[],
  now: number,
): "declined" | "expired" | null {
  if (raceStatus !== "open" || invites.length === 0) return null;
  const fresh = invites.some((invite) => invite.status === "pending" && now - invite.createdAt < RACE_INVITE_TTL_MS);
  if (fresh) return null;
  const expired = invites.some((invite) =>
    invite.status === "expired" || (invite.status === "pending" && now - invite.createdAt >= RACE_INVITE_TTL_MS)
  );
  const declined = invites.some((invite) => invite.status === "declined");
  if (expired) return "expired";
  if (declined) return "declined";
  return null;
}

export function planInviteAccept(
  invite: { status: string; createdAt: number } | null,
  raceStatus: string | null,
  now: number,
): InviteAcceptPlan {
  if (!invite) return { action: "missing" };
  if (raceInviteIsPending(invite, raceStatus ?? "", now)) return { action: "accept" };
  return { action: "unavailable" };
}

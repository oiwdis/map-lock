export interface ExistingFriendship {
  id: string;
  status: string;
  requester_id: string;
}

export type FriendRequestPlan =
  | { action: "create" }
  | { action: "accept"; id: string }
  | { action: "reopen"; id: string }
  | { action: "error"; status: number; error: string };

/// What to do when someone asks to be friends.
/// A pending request the other way is accepted, so both people don't sit waiting.
export function planFriendRequest(existing: ExistingFriendship | null, userId: string): FriendRequestPlan {
  if (!existing) return { action: "create" };
  if (existing.status === "accepted") {
    return { action: "error", status: 409, error: "You are already friends" };
  }
  if (existing.status === "pending") {
    if (existing.requester_id === userId) {
      return { action: "error", status: 409, error: "A request is already waiting" };
    }
    return { action: "accept", id: existing.id };
  }
  if (existing.status === "declined") return { action: "reopen", id: existing.id };
  return { action: "create" };
}

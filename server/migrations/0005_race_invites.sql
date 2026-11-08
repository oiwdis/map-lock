-- Race invites. The person who created an open race can ask a friend to join.
-- Not applied on production yet. Run this once there.
-- CREATE TABLE IF NOT EXISTS is safe to repeat, but do not change this file
-- after it has been applied. Add a new migration instead.

CREATE TABLE IF NOT EXISTS race_invites (
  id TEXT PRIMARY KEY,
  race_code TEXT NOT NULL REFERENCES races(code),
  from_user TEXT NOT NULL REFERENCES users(id),
  to_user TEXT NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'expired'))
);

CREATE INDEX IF NOT EXISTS race_invites_to ON race_invites(to_user, status, created_at);
CREATE INDEX IF NOT EXISTS race_invites_race ON race_invites(race_code, status);

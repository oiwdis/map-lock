-- One successor race per finished race. The unique index stops two rematch
-- votes from creating two lobbies.
-- Not applied on production yet. Run this once there.
-- SQLite has no ADD COLUMN IF NOT EXISTS, so a second run fails. Do not run it twice.
-- Do not run it on a database created from schema.sql after this column was added.

ALTER TABLE races ADD COLUMN rematch_of TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS races_rematch_of ON races(rematch_of);

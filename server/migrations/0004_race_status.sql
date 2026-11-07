-- Adds races.status so a creator can cancel a race before anyone joins.
-- Already applied on production. Do not run it again there.
-- SQLite has no ADD COLUMN IF NOT EXISTS, so a second run fails on the ALTER
-- and does not change rows that are already there.
-- New rows default to 'open'. Existing rows got 'open' from the column default.

ALTER TABLE races ADD COLUMN status TEXT NOT NULL DEFAULT 'open';

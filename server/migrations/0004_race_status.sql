-- Adds races.status so a creator can cancel a race before anyone joins.
-- SQLite has no ADD COLUMN IF NOT EXISTS. Apply this once on production.
-- A second run fails on the ALTER and does not change rows that are already there.
-- New rows default to 'open'. Existing rows get 'open' from the column default.

ALTER TABLE races ADD COLUMN status TEXT NOT NULL DEFAULT 'open';

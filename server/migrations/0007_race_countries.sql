-- Optional country list for a custom race. Null for continent and world races.
-- Not applied on production yet. Run this once there.
-- SQLite has no ADD COLUMN IF NOT EXISTS, so a second run fails. Do not run it twice.

ALTER TABLE races ADD COLUMN countries TEXT;

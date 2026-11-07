-- Already applied on production. Do not run it again there.
-- SQLite has no ADD COLUMN IF NOT EXISTS, so a second run fails.

ALTER TABLE races ADD COLUMN subject TEXT NOT NULL DEFAULT 'countries';
ALTER TABLE races ADD COLUMN style TEXT NOT NULL DEFAULT 'click';

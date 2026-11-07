-- Existing databases only. Run once, then deploy.
-- A brand-new database should use schema.sql instead. That file already
-- has a nullable apple_sub, password_hash, and login_attempts, so this
-- file would fail there on ADD COLUMN.
--
-- Adds password_hash (Apple users leave it null) and rebuilds users so
-- apple_sub can be null for username/password accounts. SQLite cannot
-- drop NOT NULL with ALTER COLUMN. Foreign keys are off only for that rebuild.

ALTER TABLE users ADD COLUMN password_hash TEXT;

PRAGMA foreign_keys = OFF;

CREATE TABLE users_next (
  id TEXT PRIMARY KEY,
  apple_sub TEXT UNIQUE,
  username TEXT UNIQUE,
  username_lower TEXT UNIQUE,
  password_hash TEXT,
  created_at INTEGER NOT NULL
);

INSERT INTO users_next (id, apple_sub, username, username_lower, password_hash, created_at)
SELECT id, apple_sub, username, username_lower, password_hash, created_at FROM users;

DROP TABLE users;
ALTER TABLE users_next RENAME TO users;

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS login_attempts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bucket TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS login_attempts_lookup ON login_attempts(bucket, created_at);

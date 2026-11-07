-- Baseline for databases created before password accounts.
-- A brand-new database can use schema.sql instead. Applying this file on a
-- database that already has these tables fails, on purpose.

CREATE TABLE users (
  id TEXT PRIMARY KEY,
  apple_sub TEXT NOT NULL UNIQUE,
  username TEXT UNIQUE,
  username_lower TEXT UNIQUE,
  created_at INTEGER NOT NULL
);

CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX sessions_user ON sessions(user_id);

CREATE TABLE friendships (
  id TEXT PRIMARY KEY,
  requester_id TEXT NOT NULL REFERENCES users(id),
  addressee_id TEXT NOT NULL REFERENCES users(id),
  status TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'declined')),
  created_at INTEGER NOT NULL,
  UNIQUE (requester_id, addressee_id)
);

CREATE INDEX friendships_addressee ON friendships(addressee_id, status);
CREATE INDEX friendships_requester ON friendships(requester_id, status);

CREATE TABLE stat_snapshots (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  payload TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE races (
  code TEXT PRIMARY KEY,
  host_id TEXT NOT NULL REFERENCES users(id),
  region TEXT NOT NULL,
  seed TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

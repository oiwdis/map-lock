-- Map Lock accounts. No email column: we never store one.

CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  apple_sub TEXT NOT NULL UNIQUE,
  username TEXT UNIQUE,
  username_lower TEXT UNIQUE,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);

-- Web Sign in with Apple: nonce for the authorize request, then a one-time app code.
CREATE TABLE IF NOT EXISTS apple_logins (
  state TEXT PRIMARY KEY,
  nonce TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS auth_codes (
  code_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  state TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS friendships (
  id TEXT PRIMARY KEY,
  requester_id TEXT NOT NULL REFERENCES users(id),
  addressee_id TEXT NOT NULL REFERENCES users(id),
  status TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'declined')),
  created_at INTEGER NOT NULL,
  UNIQUE (requester_id, addressee_id)
);

CREATE INDEX IF NOT EXISTS friendships_addressee ON friendships(addressee_id, status);
CREATE INDEX IF NOT EXISTS friendships_requester ON friendships(requester_id, status);

-- One merged stats document per user (quizzes, speedruns, bests, country stats).
CREATE TABLE IF NOT EXISTS stat_snapshots (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  payload TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

-- Race metadata. Live progress lives in the RaceRoom Durable Object.
CREATE TABLE IF NOT EXISTS races (
  code TEXT PRIMARY KEY,
  host_id TEXT NOT NULL REFERENCES users(id),
  region TEXT NOT NULL,
  subject TEXT NOT NULL DEFAULT 'countries',
  style TEXT NOT NULL DEFAULT 'click',
  seed TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

-- Map Lock accounts. No email column: we never store one.

CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  apple_sub TEXT UNIQUE,
  username TEXT UNIQUE,
  username_lower TEXT UNIQUE,
  password_hash TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);

-- Failed username/password logins. 10 per username and 10 per IP in 15 minutes.
CREATE TABLE IF NOT EXISTS login_attempts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bucket TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS login_attempts_lookup ON login_attempts(bucket, created_at);

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
-- subject and style are last so this matches ALTER TABLE in 0003.
CREATE TABLE IF NOT EXISTS races (
  code TEXT PRIMARY KEY,
  host_id TEXT NOT NULL REFERENCES users(id),
  region TEXT NOT NULL,
  seed TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  subject TEXT NOT NULL DEFAULT 'countries',
  style TEXT NOT NULL DEFAULT 'click',
  status TEXT NOT NULL DEFAULT 'open',
  countries TEXT,
  rematch_of TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS races_rematch_of ON races(rematch_of);

-- Asks a friend to join an open race. status is pending until they join, decline, or it expires.
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

-- Closed 1v1 races, so a player who left can still see the result.
CREATE TABLE IF NOT EXISTS race_results (
  code TEXT PRIMARY KEY,
  region TEXT NOT NULL,
  subject TEXT NOT NULL DEFAULT 'countries',
  style TEXT NOT NULL DEFAULT 'click',
  finished_at INTEGER NOT NULL,
  player_a TEXT NOT NULL,
  player_b TEXT NOT NULL,
  payload TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS race_results_a ON race_results(player_a, finished_at);
CREATE INDEX IF NOT EXISTS race_results_b ON race_results(player_b, finished_at);

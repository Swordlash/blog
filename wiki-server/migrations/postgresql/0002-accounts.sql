-- PostgreSQL's branch of migrations/0002-accounts.sql, which says what
-- these are; disabled is a BOOLEAN (0001 says why).

ALTER TABLE users ADD COLUMN password_hash TEXT;
ALTER TABLE users ADD COLUMN disabled BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE sessions (
  id_hash      TEXT PRIMARY KEY NOT NULL,
  user_id      TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at   TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  expires_at   TEXT NOT NULL
);

CREATE INDEX sessions_user ON sessions (user_id);

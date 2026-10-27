-- PostgreSQL's branch of migrations/0008-account-hygiene.sql, which says
-- what these are. A session made before this step gets its public id from
-- gen_random_uuid (built in since PostgreSQL 13), where SQLite's has
-- randomblob: 32 hex digits either way.

ALTER TABLE users ADD COLUMN email TEXT;
ALTER TABLE users ADD COLUMN email_verified_at TEXT;

ALTER TABLE sessions ADD COLUMN public_id TEXT;
ALTER TABLE sessions ADD COLUMN address TEXT NOT NULL DEFAULT '';
UPDATE sessions SET public_id = replace(gen_random_uuid()::text, '-', '') WHERE public_id IS NULL;
CREATE UNIQUE INDEX sessions_public_id ON sessions (public_id);

CREATE TABLE totp (
  user_id      TEXT PRIMARY KEY NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  secret       TEXT NOT NULL,
  created_at   TEXT NOT NULL,
  enabled_at   TEXT,
  last_counter BIGINT
);

CREATE TABLE recovery_codes (
  user_id   TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  code_hash TEXT NOT NULL,
  used_at   TEXT,
  PRIMARY KEY (user_id, code_hash)
);

CREATE TABLE reset_tokens (
  token_hash TEXT PRIMARY KEY NOT NULL,
  user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at    TEXT
);

CREATE INDEX reset_tokens_user ON reset_tokens (user_id);

CREATE TABLE email_verifications (
  token_hash TEXT PRIMARY KEY NOT NULL,
  user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  email      TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

CREATE INDEX email_verifications_user ON email_verifications (user_id);

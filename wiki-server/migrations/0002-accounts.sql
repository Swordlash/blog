-- Accounts and sessions (WP3.1 of docs/PLAN.md, decisions 8 and 20): a user
-- may have a password, kept as an argon2id hash in the PHC string format
-- ($argon2id$v=19$m=…,t=…,p=…$salt$hash, so that the parameters a hash was
-- made with travel with it), and may be disabled; whoever signs in has a
-- session.
--
-- A user without a password cannot sign in: those made before this step,
-- and those an imported wiki brings, until one is set. Neither column is
-- part of an export.

ALTER TABLE users ADD COLUMN password_hash TEXT;
ALTER TABLE users ADD COLUMN disabled INTEGER NOT NULL DEFAULT 0 CHECK (disabled IN (0, 1));

-- A session is known by the SHA-256 (in hex) of the random id its cookie
-- carries, never by the id itself, so that the database (or a backup of it)
-- signs nobody in. It ends when its user signs out, is disabled, is given a
-- new password or is deleted, and when it has not been used until
-- expires_at, which each use moves on (Wiki.Server.Accounts).
CREATE TABLE sessions (
  id_hash      TEXT PRIMARY KEY NOT NULL,
  user_id      TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at   TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  expires_at   TEXT NOT NULL
);

CREATE INDEX sessions_user ON sessions (user_id);

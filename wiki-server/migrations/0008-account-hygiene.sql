-- Account hygiene (WP4.11 of docs/PLAN.md): a user's sessions as they see
-- them, a second factor, an e-mail address that is checked before it is
-- trusted, and a password reset by mail.

-- A user's e-mail address, if they gave one, and when it was shown to be
-- theirs (by a link mailed to it): only a verified address receives a
-- password reset. Changing the address clears its verification. Neither is
-- part of an export, as a password's hash is not.
ALTER TABLE users ADD COLUMN email TEXT;
ALTER TABLE users ADD COLUMN email_verified_at TEXT;

-- What the account panel shows of a session: where it was last used from,
-- and an id of its own to end it by. The id is random and says nothing of
-- the cookie's (the session's key, id_hash, is never sent anywhere), so a
-- page that shows a user their sessions cannot sign anyone in. Sessions
-- made before this step get one now; their address is unknown until they
-- are next seen.
ALTER TABLE sessions ADD COLUMN public_id TEXT;
ALTER TABLE sessions ADD COLUMN address TEXT NOT NULL DEFAULT '';
UPDATE sessions SET public_id = lower(hex(randomblob(16))) WHERE public_id IS NULL;
CREATE UNIQUE INDEX sessions_public_id ON sessions (public_id);

-- A user's TOTP second factor (RFC 6238): the shared secret, in base32 as
-- authenticator applications take it, which the server needs in clear to
-- compute the codes (it is as sensitive as the database file, which holds
-- the mail server's password too). enabled_at is NULL while the user is
-- enrolling, until they confirm with a code; only an enabled one is asked
-- for at sign-in. last_counter is the time step of the last code accepted,
-- so that each code is accepted once.
CREATE TABLE totp (
  user_id      TEXT PRIMARY KEY NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  secret       TEXT NOT NULL,
  created_at   TEXT NOT NULL,
  enabled_at   TEXT,
  last_counter INTEGER
);

-- The recovery codes of a user's second factor, each usable once in place
-- of a code: their SHA-256 in hex (they are random and long, so a hash
-- without salt or cost is enough, as for a session's id). They are shown
-- once, when the second factor is turned on, and go with it.
CREATE TABLE recovery_codes (
  user_id   TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  code_hash TEXT NOT NULL,
  used_at   TEXT,
  PRIMARY KEY (user_id, code_hash)
);

-- A password reset's link, by the SHA-256 of the secret it carries, as an
-- invitation's: single use (used_at), until expires_at. Rows are kept for a
-- while after they are used or expire, so that the mails sent for an
-- account can be counted and limited.
CREATE TABLE reset_tokens (
  token_hash TEXT PRIMARY KEY NOT NULL,
  user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at    TEXT
);

CREATE INDEX reset_tokens_user ON reset_tokens (user_id);

-- The link that verifies an e-mail address, by the SHA-256 of its secret:
-- it verifies the address it was mailed to only while that is still the
-- user's address, once, until expires_at.
CREATE TABLE email_verifications (
  token_hash TEXT PRIMARY KEY NOT NULL,
  user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  email      TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

CREATE INDEX email_verifications_user ON email_verifications (user_id);

-- Whom the wiki lets in (WP3.5 of docs/PLAN.md): the wiki's own settings,
-- and the invitations of a closed wiki.
--
-- A setting is a row, by its name. A setting that has no row has its
-- default (Wiki.Api.Admin.defaultSettings), so that a wiki made before
-- there were settings goes on as it was, open:
--
--   access                      open | closed
--   new-accounts-create-spaces  0 | 1
CREATE TABLE settings (
  key   TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
);

-- An invitation is known by the SHA-256 (in hex) of the random secret its
-- link carries, never by the secret itself, as a session is: the database
-- (or a backup of it) lets nobody in. It is deleted when it is used, when
-- it is revoked, and when its address is invited again; one past
-- expires_at stays, unusable, until then, so that the administration sees
-- that it expired.
CREATE TABLE invitations (
  id         TEXT PRIMARY KEY NOT NULL,
  email      TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

CREATE INDEX invitations_email ON invitations (email COLLATE NOCASE);

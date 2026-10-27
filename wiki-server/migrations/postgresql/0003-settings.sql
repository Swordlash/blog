-- PostgreSQL's branch of migrations/0003-settings.sql, which says what
-- these are. An invitation's address is looked up without case: by
-- lower(email), where SQLite's index has COLLATE NOCASE.

CREATE TABLE settings (
  key   TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
);

CREATE TABLE invitations (
  id         TEXT PRIMARY KEY NOT NULL,
  email      TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

CREATE INDEX invitations_email ON invitations (lower(email));

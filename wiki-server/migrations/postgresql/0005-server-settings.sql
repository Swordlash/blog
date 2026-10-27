-- PostgreSQL's branch of migrations/0005-server-settings.sql, which says
-- what these are; the same table.

CREATE TABLE sign_in_providers (
  name      TEXT PRIMARY KEY NOT NULL,
  position  INTEGER NOT NULL,
  kind      TEXT NOT NULL,
  client_id TEXT NOT NULL,
  issuer    TEXT,
  secret    TEXT
);

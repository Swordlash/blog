-- PostgreSQL's branch of migrations/0004-identities.sql, which says what
-- an identity is; the same table.

CREATE TABLE identities (
  provider     TEXT NOT NULL,
  subject      TEXT NOT NULL,
  user_id      TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  email        TEXT,
  display_name TEXT,
  linked_at    TEXT NOT NULL,
  PRIMARY KEY (provider, subject)
);

CREATE UNIQUE INDEX identities_user ON identities (user_id, provider);

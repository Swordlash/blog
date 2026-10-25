-- Signing in with an account at a provider (WP3.6 of docs/PLAN.md): Google,
-- GitHub, Apple or any OpenID Connect provider the server's configuration
-- names, instead of a password or beside one.
--
-- An identity is a provider's account, by the provider's name in the
-- configuration and the subject the provider knows the account by (never
-- its e-mail address or its login there, which change), and the user it
-- signs in. A provider's account signs in one user at most; a user may have
-- one per provider. The e-mail address (if the provider said it had
-- verified it) and the name are what the provider said the last time the
-- user signed in with it, for the user and the administration to tell
-- their identities apart; nothing is decided by them. Deleting a user
-- deletes their identities. Like passwords, identities are no part of an
-- export.
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

-- The server's own settings (WP4.4 of docs/PLAN.md), set in the
-- administration's "Server" section and nowhere else: the wiki's public
-- address, the mail server invitations are sent through, and the providers
-- people sign in with. Until they are set the server has none of them: no
-- address, mails nothing (the administration shows an invitation's link),
-- and signs in with passwords only, as a server made before them did
-- without its options.
--
-- The address and the mail server are rows of the settings table
-- (migrations/0003-settings.sql), by key, absent when unset:
--
--   public-url      https://wiki.example.org/
--   mail-host       mail.example.org        (no mail without it)
--   mail-port       587
--   mail-security   tls | starttls | plain
--   mail-user       the account, if the server wants one
--   mail-password   its password
--   mail-from       Wiki <wiki@example.org>
--
-- The providers are rows of their own, in the order their buttons show.
-- A provider is known by its name, which is in its redirect URI and in
-- the identities signed in with it (migrations/0004-identities.sql); those
-- are not deleted with it, so that a provider removed and added again
-- under its name signs the same people in.
--
-- The mail account's password and the providers' client secrets are kept
-- in clear, since the server needs them so, beside the password and
-- session hashes this database holds already: it is as sensitive as its
-- file, which the data directory keeps to the operator. The API never
-- gives them back.
CREATE TABLE sign_in_providers (
  name      TEXT PRIMARY KEY NOT NULL,
  position  INTEGER NOT NULL,
  kind      TEXT NOT NULL,
  client_id TEXT NOT NULL,
  issuer    TEXT,
  secret    TEXT
);

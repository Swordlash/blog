-- The writing assistant's keys across devices (WP5.21 of docs/PLAN.md,
-- Wiki.Server.Vault): the vault a user's browser seals their settings in,
-- and the passkeys that unlock it on another device. The server cannot
-- open the vault: the key that does is wrapped once per passkey, with a
-- key only the passkey's authenticator can give the browser.

-- A user's passkeys, registered with the wiki as the relying party
-- (Wiki.Server.WebAuthn). credential_id is the credential's id in
-- base64url, as WebAuthn writes it; public_key the COSE key the
-- authenticator gave at registration, which checks the signature of each
-- use; algorithm its COSE algorithm (-7 ES256, -257 RS256); sign_count
-- the authenticator's counter at its last use (a synced passkey's stays
-- 0). wrapped_nonce and wrapped_key are the vault key wrapped for this
-- passkey (AES-GCM, base64url), NULL until the browser wraps it, and go
-- with the passkey.
CREATE TABLE passkeys (
  credential_id TEXT PRIMARY KEY NOT NULL,
  user_id       TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  public_key    BLOB NOT NULL,
  algorithm     INTEGER NOT NULL,
  sign_count    INTEGER NOT NULL,
  name          TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  last_used_at  TEXT,
  wrapped_nonce TEXT,
  wrapped_key   TEXT
);
CREATE INDEX passkeys_user ON passkeys (user_id);

-- A user's vault, as their browser sent it (Wiki.Core.Assistant.Vault):
-- its format, the salt the passkeys' PRF is evaluated on, and the sealed
-- settings (nonce and ciphertext, base64url). revision counts its
-- versions: it is the vault's tag, which a device sends back to change
-- the version it has, and it changes when a passkey's wrapped key goes.
CREATE TABLE assistant_vaults (
  user_id    TEXT PRIMARY KEY NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  format     INTEGER NOT NULL,
  salt       TEXT NOT NULL,
  nonce      TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  revision   INTEGER NOT NULL,
  updated_at TEXT NOT NULL
);

-- The user's vault (WP5.74 of docs/PLAN.md, Wiki.Core.Vault): the
-- assistant's vault of WP5.21 made general. A vault seals named items
-- (vault_items) under one vault key, which the browser wraps once for each
-- way to unlock it: once per passkey, in passkeys' wrapped_nonce and
-- wrapped_key as before, and, when the user chose it, once with a key
-- derived from their password (password_nonce and password_key, NULL
-- otherwise). The server cannot open any of it.
--
-- vaults is a user's vault: the salt every wrapping key is derived with,
-- the password's wrap, and revision, the vault's tag, as assistant_vaults
-- had it. Every vault of assistant_vaults moves here with its revision
-- unchanged, so that a tab that holds its tag can still store over it.
CREATE TABLE vaults (
  user_id        TEXT PRIMARY KEY NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  salt           TEXT NOT NULL,
  password_nonce TEXT,
  password_key   TEXT,
  revision       INTEGER NOT NULL,
  updated_at     TEXT NOT NULL
);

-- vault_items is a vault's sealed items, by name: assistant for the
-- writing assistant's settings (each vault of assistant_vaults had that
-- one item). key_id names the key pair an item holds, for an item that
-- holds a private key, and is NULL otherwise. nonce and ciphertext are
-- AES-GCM's, in base64url.
CREATE TABLE vault_items (
  user_id    TEXT NOT NULL REFERENCES vaults (user_id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  key_id     TEXT,
  nonce      TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  PRIMARY KEY (user_id, name)
);

INSERT INTO vaults (user_id, salt, password_nonce, password_key, revision, updated_at)
  SELECT user_id, salt, NULL, NULL, revision, updated_at FROM assistant_vaults;

INSERT INTO vault_items (user_id, name, key_id, nonce, ciphertext)
  SELECT user_id, 'assistant', NULL, nonce, ciphertext FROM assistant_vaults;

DROP TABLE assistant_vaults;

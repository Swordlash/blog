-- Encrypted spaces (WP5.74 of docs/PLAN.md, Wiki.Core.Encrypted): spaces
-- whose pages' titles and texts are encrypted in their members' browsers.
-- The server stores what the browsers send and cannot read it.
--
-- key_id: the id of an encrypted space's current key, NULL for a space
-- whose pages are plain text. The key itself is never here: each member
-- holds it through a row of key_grants.
ALTER TABLE spaces ADD COLUMN key_id TEXT;

-- key_grants is a symmetric key sealed to one user's public key (HPKE):
-- resource_kind says whose key it is (space: a space's key; page, kept
-- for later, a single page's), resource_id names that space or page, and
-- key_id the key. recipient_key_id is the public key of the directory it
-- is sealed to; a grant to a key that is no longer its user's current one
-- (retired by a password reset) opens for nobody, and its user waits for
-- a new grant. enc is HPKE's encapsulated key and sealed the sealed key,
-- both in base64url.
CREATE TABLE key_grants (
  resource_kind    TEXT NOT NULL CHECK (resource_kind IN ('space', 'page')),
  resource_id      TEXT NOT NULL,
  key_id           TEXT NOT NULL,
  recipient        TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  recipient_key_id TEXT NOT NULL REFERENCES public_keys (key_id) ON DELETE CASCADE,
  enc              TEXT NOT NULL,
  sealed           TEXT NOT NULL,
  created_at       TEXT NOT NULL,
  PRIMARY KEY (resource_kind, resource_id, key_id, recipient_key_id)
);

CREATE INDEX key_grants_recipient ON key_grants (recipient);

-- page_keys is the key of a page of an encrypted space, encrypted with the
-- space's key whose id is space_key_id: key_id names the page's key, and
-- nonce and wrapped are AES-GCM's.
CREATE TABLE page_keys (
  page_id      TEXT PRIMARY KEY NOT NULL REFERENCES pages (id) ON DELETE CASCADE,
  key_id       TEXT NOT NULL,
  space_key_id TEXT NOT NULL,
  nonce        TEXT NOT NULL,
  wrapped      TEXT NOT NULL
);

-- sealed_versions is a version of a page of an encrypted space, encrypted
-- with the page's key: its title and text, each with its nonce. The
-- version's row in page_versions has an empty title and text; tag is the
-- random id the browser gave the version, which the ciphertexts' additional
-- data names.
CREATE TABLE sealed_versions (
  page_id     TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  tag         TEXT NOT NULL,
  key_id      TEXT NOT NULL,
  title_nonce TEXT NOT NULL,
  title       TEXT NOT NULL,
  body_nonce  TEXT NOT NULL,
  body        TEXT NOT NULL,
  PRIMARY KEY (page_id, updated_at),
  FOREIGN KEY (page_id, updated_at) REFERENCES page_versions (page_id, updated_at) ON DELETE CASCADE
);

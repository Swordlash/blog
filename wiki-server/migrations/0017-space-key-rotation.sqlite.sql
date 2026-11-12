-- A new key for an encrypted space when a reader is removed (WP5.74b3 of
-- docs/PLAN.md, item 2): a rotation makes the space a new key, seals it to
-- its readers, wraps every page key again with it, and gives every page a
-- new page key, which the versions written after are encrypted with.
--
-- key_grants keeps its grants when their recipient's account or public
-- key is deleted: a grant of the space's current key to someone who is no
-- longer a reader is what makes a rotation due, and a deleted account is
-- no longer one. A rotation deletes them. Which kinds of key a grant may
-- be of is checked by the program, so that a later kind needs no new
-- table.
--
-- page_keys holds every key a page has had, by (page_id, key_id): the
-- versions written before a rotation stay encrypted with the page key of
-- their time. current marks the one the next version is encrypted with,
-- one for each page.
--
-- notifications takes one more kind, renew-key: an administrator of an
-- encrypted space told that its key must be renewed.
--
-- SQLite cannot drop a constraint or change a primary key: each table is
-- made again under a new name, filled, and renamed.

CREATE TABLE key_grants_17 (
  resource_kind    TEXT NOT NULL,
  resource_id      TEXT NOT NULL,
  key_id           TEXT NOT NULL,
  recipient        TEXT NOT NULL,
  recipient_key_id TEXT NOT NULL,
  enc              TEXT NOT NULL,
  sealed           TEXT NOT NULL,
  created_at       TEXT NOT NULL,
  PRIMARY KEY (resource_kind, resource_id, key_id, recipient_key_id)
);
INSERT INTO key_grants_17 SELECT resource_kind, resource_id, key_id, recipient, recipient_key_id, enc, sealed, created_at FROM key_grants;
DROP TABLE key_grants;
ALTER TABLE key_grants_17 RENAME TO key_grants;
CREATE INDEX key_grants_recipient ON key_grants (recipient);

CREATE TABLE page_keys_17 (
  page_id      TEXT NOT NULL REFERENCES pages (id) ON DELETE CASCADE,
  key_id       TEXT NOT NULL,
  space_key_id TEXT NOT NULL,
  nonce        TEXT NOT NULL,
  wrapped      TEXT NOT NULL,
  current      BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (page_id, key_id)
);
INSERT INTO page_keys_17 (page_id, key_id, space_key_id, nonce, wrapped, current) SELECT page_id, key_id, space_key_id, nonce, wrapped, TRUE FROM page_keys;
DROP TABLE page_keys;
ALTER TABLE page_keys_17 RENAME TO page_keys;
CREATE UNIQUE INDEX page_keys_current ON page_keys (page_id) WHERE current;

CREATE TABLE notifications_17 (
  seq        INTEGER PRIMARY KEY NOT NULL,
  id         TEXT NOT NULL UNIQUE,
  user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  kind       TEXT NOT NULL CHECK (kind IN ('mentioned', 'replied', 'commented', 'changed', 'renew-key')),
  page_id    TEXT NOT NULL REFERENCES pages (id) ON DELETE CASCADE,
  thread_id  TEXT REFERENCES threads (id) ON DELETE SET NULL,
  actor      TEXT NOT NULL,
  actor_name TEXT NOT NULL,
  title      TEXT NOT NULL,
  excerpt    TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  read_at    TEXT,
  mail       INTEGER NOT NULL DEFAULT 0 CHECK (mail IN (0, 1))
);
INSERT INTO notifications_17 SELECT seq, id, user_id, kind, page_id, thread_id, actor, actor_name, title, excerpt, created_at, read_at, mail FROM notifications;
DROP TABLE notifications;
ALTER TABLE notifications_17 RENAME TO notifications;
CREATE INDEX notifications_user ON notifications (user_id, seq);
CREATE INDEX notifications_mail ON notifications (user_id) WHERE mail = 1;

-- Comments and attachments in an encrypted space (WP5.74b3 of
-- docs/PLAN.md, item 1, Wiki.Core.Encrypted): each encrypted in the
-- browser with the key of its page's that was current when it was
-- written, which key_id names, with additional data of its own kind, so
-- that no ciphertext opens as another. The plain rows stay, so that the
-- tree of threads, permissions, cascades and the blob store are the
-- plain ones; they hold nothing of what was written.
--
-- sealed_threads is a thread's anchor, the quote it is about with its
-- context, encrypted (anchor and its nonce), or none for a thread about
-- the whole page (anchored false). The thread's row in threads has an
-- empty quote, prefix and suffix when the thread has an anchor, so that it
-- may be resolved as one about a quote, and none when it has not.
CREATE TABLE sealed_threads (
  thread_id    TEXT PRIMARY KEY NOT NULL REFERENCES threads (id) ON DELETE CASCADE,
  key_id       TEXT NOT NULL,
  anchored     BOOLEAN NOT NULL,
  anchor_nonce TEXT,
  anchor       TEXT
);

-- sealed_comments is a comment's text, encrypted (body and its nonce),
-- under a tag the browser picks at each writing of it, which its additional
-- data names. The comment's row in comments has an empty body.
CREATE TABLE sealed_comments (
  comment_id TEXT PRIMARY KEY NOT NULL REFERENCES comments (id) ON DELETE CASCADE,
  key_id     TEXT NOT NULL,
  tag        TEXT NOT NULL,
  nonce      TEXT NOT NULL,
  body       TEXT NOT NULL
);

-- sealed_attachments is an attachment's name and media type, encrypted
-- together (meta and its nonce), and the nonce its bytes are encrypted
-- with. The attachment's row in attachments is named by its id, of the
-- type application/octet-stream, and its blob holds the encrypted bytes:
-- a random nonce for each upload, so that two uploads of one file are two
-- blobs, which only their sizes relate. staged_blob is the blob of an
-- attachment encrypted while its space is being encrypted, not yet in its
-- row's place (the conversion of WP5.74b3's item 4): the storage keeps it
-- with the blobs the database names.
CREATE TABLE sealed_attachments (
  attachment_id TEXT PRIMARY KEY NOT NULL REFERENCES attachments (id) ON DELETE CASCADE,
  key_id        TEXT NOT NULL,
  meta_nonce    TEXT NOT NULL,
  meta          TEXT NOT NULL,
  bytes_nonce   TEXT NOT NULL,
  staged_blob   TEXT
);

-- Comments on pages (WP4.5 of docs/PLAN.md, decision 23): threads, each
-- opened by a comment and answered by replies.
--
-- A thread is about a quote of its page's rendered text (an inline thread:
-- quote, prefix and suffix, the W3C text quote selector of
-- Wiki.Core.Anchor), or, with all three NULL, about the whole page. Only an
-- inline thread is ever resolved. seq is its place among its page's
-- threads, in the order they were opened, and a comment's among its
-- thread's: the times are text, whose order is not the times', and a rowid
-- may change when the database is vacuumed.
--
-- A comment's author is a user's id, or the administrator's
-- (Wiki.Server.Storage.administratorId), so not a foreign key, as a
-- version's author is not; their name is read from users when the comment
-- is. Deleting a page deletes its threads, and a thread its comments.
CREATE TABLE threads (
  id         TEXT PRIMARY KEY NOT NULL,
  page_id    TEXT NOT NULL REFERENCES pages (id) ON DELETE CASCADE,
  quote      TEXT,
  prefix     TEXT,
  suffix     TEXT,
  resolved   INTEGER NOT NULL DEFAULT 0 CHECK (resolved IN (0, 1)),
  created_at TEXT NOT NULL,
  seq        INTEGER NOT NULL,
  CHECK ((quote IS NULL) = (prefix IS NULL) AND (quote IS NULL) = (suffix IS NULL)),
  CHECK (quote IS NOT NULL OR resolved = 0)
);

CREATE INDEX threads_page ON threads (page_id, seq);

CREATE TABLE comments (
  id         TEXT PRIMARY KEY NOT NULL,
  thread_id  TEXT NOT NULL REFERENCES threads (id) ON DELETE CASCADE,
  author     TEXT NOT NULL,
  body       TEXT NOT NULL,
  created_at TEXT NOT NULL,
  edited_at  TEXT,
  seq        INTEGER NOT NULL
);

CREATE INDEX comments_thread ON comments (thread_id, seq);

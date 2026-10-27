-- PostgreSQL's branch of migrations/0006-comments.sql, which says what
-- threads and comments are; resolved is a BOOLEAN (0001 says why).

CREATE TABLE threads (
  id         TEXT PRIMARY KEY NOT NULL,
  page_id    TEXT NOT NULL REFERENCES pages (id) ON DELETE CASCADE,
  quote      TEXT,
  prefix     TEXT,
  suffix     TEXT,
  resolved   BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TEXT NOT NULL,
  seq        INTEGER NOT NULL,
  CHECK ((quote IS NULL) = (prefix IS NULL) AND (quote IS NULL) = (suffix IS NULL)),
  CHECK (quote IS NOT NULL OR NOT resolved)
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

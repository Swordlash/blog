-- PostgreSQL's branch of migrations/0011-notifications.sql, which says
-- what these are; flags are BOOLEANs (0001 says why).

CREATE TABLE watches (
  user_id  TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  page_id  TEXT REFERENCES pages (id) ON DELETE CASCADE,
  space_id TEXT REFERENCES spaces (id) ON DELETE CASCADE,
  watching BOOLEAN NOT NULL,
  CHECK ((page_id IS NULL) <> (space_id IS NULL))
);

CREATE UNIQUE INDEX watches_page ON watches (user_id, page_id) WHERE page_id IS NOT NULL;
CREATE UNIQUE INDEX watches_space ON watches (user_id, space_id) WHERE space_id IS NOT NULL;

CREATE TABLE notifications (
  id         TEXT PRIMARY KEY NOT NULL,
  user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  kind       TEXT NOT NULL CHECK (kind IN ('mentioned', 'replied', 'commented', 'changed')),
  page_id    TEXT NOT NULL REFERENCES pages (id) ON DELETE CASCADE,
  thread_id  TEXT REFERENCES threads (id) ON DELETE SET NULL,
  actor      TEXT NOT NULL,
  actor_name TEXT NOT NULL,
  title      TEXT NOT NULL,
  excerpt    TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  seq        INTEGER NOT NULL,
  read_at    TEXT,
  mail       BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX notifications_user ON notifications (user_id, seq);
CREATE INDEX notifications_mail ON notifications (user_id) WHERE mail;

ALTER TABLE users ADD COLUMN notification_mail TEXT CHECK (notification_mail IN ('off', 'now', 'daily'));
ALTER TABLE users ADD COLUMN watch_own BOOLEAN NOT NULL DEFAULT TRUE;

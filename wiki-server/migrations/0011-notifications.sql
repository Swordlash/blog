-- Mentions, watching and notifications (WP4.13 of docs/PLAN.md,
-- Wiki.Core.Notification).

-- What a user chose to watch, or not to: a page, or a space (and with it
-- its pages and its subspaces'). A row is a choice made with the "Watch"
-- bell, which wins over whatever would otherwise decide (the nearest space
-- with a row, then whether the user made the page); a page or a space
-- with no row is decided that way. A row goes with its user, its page or
-- its space.
CREATE TABLE watches (
  user_id  TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  page_id  TEXT REFERENCES pages (id) ON DELETE CASCADE,
  space_id TEXT REFERENCES spaces (id) ON DELETE CASCADE,
  watching INTEGER NOT NULL CHECK (watching IN (0, 1)),
  CHECK ((page_id IS NULL) <> (space_id IS NULL))
);

CREATE UNIQUE INDEX watches_page ON watches (user_id, page_id) WHERE page_id IS NOT NULL;
CREATE UNIQUE INDEX watches_space ON watches (user_id, space_id) WHERE space_id IS NOT NULL;

-- What a user is told of: a mention, a reply in a thread of theirs, a
-- comment on a page they watch, or a save of it (kind: mentioned, replied,
-- commented, changed), by someone (actor, a user's id or the
-- administrator's, so not a foreign key, named as they were then), with
-- the page's title then and the start of the comment. seq is its place
-- among all notifications, in the order they were made (the times are
-- text, whose order is not the times'). read_at is when its user marked it
-- read; mail is 1 while it waits to be mailed, at once or in the day's
-- digest. It goes with its user and its page; a thread deleted leaves it
-- about the page.
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
  mail       INTEGER NOT NULL DEFAULT 0 CHECK (mail IN (0, 1))
);

CREATE INDEX notifications_user ON notifications (user_id, seq);
CREATE INDEX notifications_mail ON notifications (user_id) WHERE mail = 1;

-- How a user is told: their mail (off, now or daily; NULL until they
-- choose, which is at once with a verified address and off without one),
-- and whether they watch the pages they made and the threads they are in.
ALTER TABLE users ADD COLUMN notification_mail TEXT CHECK (notification_mail IN ('off', 'now', 'daily'));
ALTER TABLE users ADD COLUMN watch_own INTEGER NOT NULL DEFAULT 1 CHECK (watch_own IN (0, 1));

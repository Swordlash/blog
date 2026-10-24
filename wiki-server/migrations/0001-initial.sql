-- The wiki's first schema: everything MonadWiki keeps (spaces, pages and
-- every version of each, attachments, drafts) and the people and grants the
-- permission rules read (users, groups, grants).
--
-- Times are ISO 8601 text in UTC with every digit of the second's fraction
-- the program had (Wiki.Server.Storage.Rows), so that a time read back is the
-- very time written: a save is checked against the updatedAt it started from,
-- by equality. Ids are text, as Wiki.Core.Id has them. The order of
-- children, permissions and the kinds of subjects are the words the export
-- format writes them with.
--
-- This file runs inside the transaction that applies the migrations, and
-- records nothing in schema_version itself (Wiki.Server.Storage.Migrate does).

CREATE TABLE users (
  id           TEXT PRIMARY KEY NOT NULL,
  login        TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL
);

CREATE TABLE groups (
  id   TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL
);

CREATE TABLE group_members (
  group_id TEXT NOT NULL REFERENCES groups (id) ON DELETE CASCADE,
  user_id  TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  PRIMARY KEY (group_id, user_id)
);

-- A grant names a user or a group. Not a foreign key, since it is one of two
-- tables; the rules count only grants for someone who is there.
CREATE TABLE global_grants (
  subject_kind TEXT NOT NULL CHECK (subject_kind IN ('user', 'group')),
  subject_id   TEXT NOT NULL,
  permission   TEXT NOT NULL CHECK (permission IN ('administer', 'create-spaces')),
  UNIQUE (subject_kind, subject_id, permission)
);

CREATE TABLE spaces (
  id             TEXT PRIMARY KEY NOT NULL,
  -- A subspace goes with the space it is in.
  parent         TEXT REFERENCES spaces (id) ON DELETE CASCADE,
  name           TEXT NOT NULL,
  slug           TEXT NOT NULL,
  public         INTEGER NOT NULL CHECK (public IN (0, 1)),
  math_macros    TEXT NOT NULL,
  created_at     TEXT NOT NULL,
  position       INTEGER NOT NULL,
  subspace_order TEXT NOT NULL CHECK (subspace_order IN ('name', 'newest-first', 'oldest-first', 'by-hand')),
  page_order     TEXT NOT NULL CHECK (page_order IN ('name', 'newest-first', 'oldest-first', 'by-hand'))
);

-- No two siblings share a slug, the top-level spaces included (whose parent
-- is NULL, which a plain unique index would take for all different).
CREATE UNIQUE INDEX spaces_sibling_slug ON spaces (coalesce(parent, ''), slug);

CREATE TABLE space_grants (
  space_id     TEXT NOT NULL REFERENCES spaces (id) ON DELETE CASCADE,
  subject_kind TEXT NOT NULL CHECK (subject_kind IN ('user', 'group')),
  subject_id   TEXT NOT NULL,
  permission   TEXT NOT NULL CHECK (permission IN ('view', 'edit', 'administer')),
  UNIQUE (space_id, subject_kind, subject_id, permission)
);

-- A page as it is now: its place in its space's tree, and its current
-- version, with the text the search compares queries with (the body as a
-- reader sees it, Wiki.Core.Search.bodyText), made by the write that made the
-- version, so that a search never parses a page.
CREATE TABLE pages (
  id          TEXT PRIMARY KEY NOT NULL,
  -- A page goes with its space, and with the page it is under.
  space_id    TEXT NOT NULL REFERENCES spaces (id) ON DELETE CASCADE,
  parent      TEXT REFERENCES pages (id) ON DELETE CASCADE,
  title       TEXT NOT NULL,
  slug        TEXT NOT NULL,
  body        TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  position    INTEGER NOT NULL,
  search_text TEXT NOT NULL
);

CREATE UNIQUE INDEX pages_sibling_slug ON pages (space_id, coalesce(parent, ''), slug);
CREATE INDEX pages_parent ON pages (parent);

-- Every version of every page, the current one included: a row for the page
-- as it was made, and one for each save, keyed by the page's updatedAt then.
-- The author is the id of whoever saved it (a user's, or the administrator's,
-- Wiki.Server.Storage.administratorId); NULL for a page imported from an export.
CREATE TABLE page_versions (
  page_id    TEXT NOT NULL REFERENCES pages (id) ON DELETE CASCADE,
  updated_at TEXT NOT NULL,
  title      TEXT NOT NULL,
  body       TEXT NOT NULL,
  author     TEXT,
  PRIMARY KEY (page_id, updated_at)
);

-- An attachment's bytes are either on the web (url) or in the blob store
-- under their content hash (blob, the SHA-256 in hex); never both. ordinal is
-- its place among the page's attachments, which a replacement keeps.
CREATE TABLE attachments (
  id         TEXT PRIMARY KEY NOT NULL,
  page_id    TEXT NOT NULL REFERENCES pages (id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  media_type TEXT NOT NULL,
  size       INTEGER NOT NULL CHECK (size >= 0),
  url        TEXT,
  blob       TEXT,
  ordinal    INTEGER NOT NULL,
  CHECK ((url IS NULL) <> (blob IS NULL)),
  UNIQUE (page_id, name)
);

CREATE INDEX attachments_blob ON attachments (blob) WHERE blob IS NOT NULL;

-- Each author's draft of a page. The author is a user's id, or the
-- administrator's (Wiki.Server.Storage.administratorId), so not a foreign key.
CREATE TABLE drafts (
  page_id  TEXT NOT NULL REFERENCES pages (id) ON DELETE CASCADE,
  author   TEXT NOT NULL,
  title    TEXT NOT NULL,
  body     TEXT NOT NULL,
  base     TEXT NOT NULL,
  saved_at TEXT NOT NULL,
  PRIMARY KEY (page_id, author)
);

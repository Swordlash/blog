-- The links on each page (issue #189, WP5.88 of docs/PLAN.md), from which
-- a page's backlinks, its list "Linked from", are read: a row for each
-- destination a page's text links to that may lead to a page (a path or a
-- permanent address), each once.
--
-- source_id is the page with the link, and ordinal the link's place among
-- its page's links. destination is the link's destination as written,
-- which is resolved again, without reading the page's text, when a change
-- to the tree of pages or spaces may lead it elsewhere. target_id is the
-- page it leads to now, NULL for none. name is what a page created or
-- moved must be named for the link to lead to it (the slug its path ends
-- in, or the id it names, its first 200 characters), NULL when no page
-- created or moved could be. pending marks a link to resolve again before
-- the transaction that marked it commits: a write marks the links its
-- change may lead elsewhere, and they are resolved together at its end.
-- No committed row is pending.
--
-- The table is derived from the pages' text, as the search's text is. This
-- step makes it empty; the program fills it when it opens the database,
-- with the parser and the resolver of its version, and fills it again when
-- a later version reads links otherwise (the setting links-version).
CREATE TABLE page_links (
  source_id   TEXT NOT NULL REFERENCES pages (id) ON DELETE CASCADE,
  ordinal     INTEGER NOT NULL,
  destination TEXT NOT NULL,
  name        TEXT,
  target_id   TEXT REFERENCES pages (id) ON DELETE SET NULL,
  pending     BOOLEAN NOT NULL,
  PRIMARY KEY (source_id, ordinal)
);

-- The links that lead to a page: what its backlinks are read by, and the
-- links resolved again when it is moved or deleted.
CREATE INDEX page_links_target ON page_links (target_id);
-- The links a page created or moved may lead to.
CREATE INDEX page_links_name ON page_links (name);
-- The links to resolve again at the end of a write.
CREATE INDEX page_links_pending ON page_links (pending);

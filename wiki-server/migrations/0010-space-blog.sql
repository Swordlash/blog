-- Whether a space is shown as a blog (WP4.14 of docs/PLAN.md): it opens at
-- its posts, its top-level pages the newest first, under its home page, and
-- a public one has an Atom and an RSS feed. Set in the space's settings,
-- with its profile; 0 for every space there is.
ALTER TABLE spaces ADD COLUMN blog INTEGER NOT NULL DEFAULT 0 CHECK (blog IN (0, 1));

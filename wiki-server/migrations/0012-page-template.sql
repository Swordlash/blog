-- Whether a page is one of its space's templates (WP4.15 of docs/PLAN.md):
-- listed under the space's "Templates" rather than in its tree, left out of
-- a search that does not ask for templates, and offered as the start of a
-- new page. Set from the page's "Use as template"; 0 for every page there is.
ALTER TABLE pages ADD COLUMN template INTEGER NOT NULL DEFAULT 0 CHECK (template IN (0, 1));

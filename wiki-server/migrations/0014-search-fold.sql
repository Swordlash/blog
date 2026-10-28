-- The search's fold of each page, and an index for counting and searching
-- a space's pages (WP5.16b of docs/PLAN.md, findings 5 and 8e of
-- docs/scalability-audit.md).
--
-- search_fold is the page's title and its search_text, each folded as the
-- search compares them (Wiki.Core.Search.foldText: no case, no
-- diacritics), separated by a line break. A search matches the query's
-- words against this column in SQL, so that only the pages that match are
-- read and folded, instead of every page of the wiki on every keystroke.
-- SQL cannot fold text as the search does, so this step leaves the column
-- NULL for the pages already there, and the storage fills it in when it
-- opens the database (Wiki.Server.Storage.Rows.fillSearchFolds).
ALTER TABLE pages ADD COLUMN search_fold TEXT;

-- A space's pages, templates or not. The count of each space's pages (the
-- directory at Home) reads this index alone instead of every page's row,
-- and a search finds a space's pages through it.
CREATE INDEX pages_space_template ON pages (space_id, template);

-- The pages whose fold is not filled in yet. The storage looks for them
-- each time it opens; once every fold is there, the index is empty, and
-- the look costs nothing however many pages there are.
CREATE INDEX pages_unfolded ON pages (id) WHERE search_fold IS NULL;

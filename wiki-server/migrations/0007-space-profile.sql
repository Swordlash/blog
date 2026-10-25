-- A space's profile (WP4.6 of docs/PLAN.md): the page it opens at, how it
-- is pictured, and what it is for.
--
-- home_page is one of the space's own pages, or NULL for none (the space
-- then opens at the list of its pages); deleting the page leaves the space
-- without one, and the storage clears it when the page moves to another
-- space. icon is Wiki.Core.Space's Icon as its JSON ({"emoji": …},
-- {"colour": …} or {"image": <blob>, "mediaType": …}), or NULL for the
-- default; an image's bytes are in the blob store, as an attachment's are,
-- and the blob is counted as referred to while a space's icon names it.
-- description is plain text, empty for none.
ALTER TABLE spaces ADD COLUMN home_page TEXT REFERENCES pages (id) ON DELETE SET NULL;
ALTER TABLE spaces ADD COLUMN icon TEXT;
ALTER TABLE spaces ADD COLUMN description TEXT NOT NULL DEFAULT '';

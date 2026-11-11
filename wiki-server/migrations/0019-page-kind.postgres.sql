-- What a page is (WP5.97 of docs/PLAN.md, issue #191, Wiki.Core.PageKind):
-- 'document', which every page is until it is made otherwise, or
-- 'presentation', a page presented as slides. The kind is the page's, not a
-- version's, and is chosen when the page is made. No CHECK: a kind this
-- program does not know (a newer program's, or later a plugin's) is kept
-- as written and shown as a document; the program accepts only the kinds
-- it knows when a page is made or changed.
ALTER TABLE pages ADD COLUMN kind TEXT NOT NULL DEFAULT 'document';

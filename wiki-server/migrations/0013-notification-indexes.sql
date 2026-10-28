-- Indexes for telling users of a save or a comment (WP5.16a of
-- docs/PLAN.md, finding 3 of docs/scalability-audit.md). Each write that
-- notifies used to read every user, every watch and every group
-- membership, and each notification it inserted found its seq with a scan
-- of the whole notifications table.
--
-- A new notification's seq is one more than the largest seq there is. An
-- index on seq lets SQLite read that largest value from the index's end.
-- Making seq the table's rowid would do the same without an index, but the
-- table's primary key is the id, a text, so that needs a rewrite of the
-- table.
CREATE INDEX notifications_seq ON notifications (seq);

-- The users who watch a page, or a space, found by the page or the space.
-- The unique indexes of 0011 start with the user, so they find one user's
-- watches, not a page's watchers.
CREATE INDEX watches_page_id ON watches (page_id);
CREATE INDEX watches_space_id ON watches (space_id);

-- The groups of some users, found by the user. The table's primary key
-- starts with the group, so it finds a group's members, not a user's
-- groups. Every transaction of a signed-in user reads that user's groups
-- this way too.
CREATE INDEX group_members_user ON group_members (user_id);

-- Users found by the first letters of their login or of their display
-- name, ignoring case: the editor's completion of mentions (WP5.28 of
-- docs/PLAN.md, Rows' loadUsersStartingWith). The query compares lower(...)
-- with a range of texts, in the collation "C", which compares code points:
-- the database's own collation (en_US.utf8 in the postgres image) passes
-- over punctuation, so a range of texts in it is not the texts that start
-- with some letters. An index answers the range only in the collation the
-- query compares in, so these are in "C" too; users_login_folded, in the
-- database's collation, still serves the sign-in's equality.
CREATE INDEX users_login_prefix ON users ((lower(login)) COLLATE "C");
CREATE INDEX users_name_folded ON users ((lower(display_name)) COLLATE "C");

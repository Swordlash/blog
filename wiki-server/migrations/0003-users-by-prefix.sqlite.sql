-- Users found by the first letters of their login or of their display
-- name, ignoring case: the editor's completion of mentions (WP5.28 of
-- docs/PLAN.md, Rows' loadUsersStartingWith). The query compares lower(...)
-- with a range of texts, which SQLite answers from an index on the same
-- expression. The login has one already (users_login_folded, which the
-- sign-in uses); this is the display name's.
--
-- SQLite's lower() folds only the letters of ASCII, so a display name that
-- starts with another capital letter is found by its login only.
CREATE INDEX users_name_folded ON users (lower(display_name));

-- The generation of the permission context (WP5.24 of docs/PLAN.md): one
-- row, whose number goes up by one in every write transaction that changes
-- what a permission check reads. That is the spaces, the global grants and
-- the grants on spaces, the users (who is active, their login and name),
-- and who is in which group. Wiki.Server.Storage.Rows bumps it in the same
-- transaction as each such write.
--
-- A server keeps the permission context of the last generation it read in
-- memory, and every read transaction reads this row first: when the number
-- is the one in memory, the context in memory is the database's, and is
-- not read again. A change by another process (the console's wiki-server
-- users ...) bumps the row too, so a running server sees it at its next
-- read.
CREATE TABLE permissions_generation (
  id         INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
  generation INTEGER NOT NULL
);

INSERT INTO permissions_generation (id, generation) VALUES (1, 0);

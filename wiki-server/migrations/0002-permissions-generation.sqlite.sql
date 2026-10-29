-- The generation of the permission context (WP5.24 of docs/PLAN.md): one
-- row, whose number goes up in every write transaction that changes what a
-- permission check reads: the spaces, the global grants and the grants on
-- spaces, the users (a user added or deleted, or their login, name or
-- whether they are disabled changed), and who is in which group.
--
-- A server keeps the permission context of the last generation it read in
-- memory, and every read transaction reads this row first: when the number
-- is the one in memory, the context in memory is the database's, and is
-- not read again. The triggers below bump the row in the same transaction
-- as the change, whoever makes it: the server, the console's wiki-server
-- users ... in another process, a foreign key's action (a page deleted
-- clears a space's home page), or a statement typed by hand. So no code has
-- to remember to.
--
-- Every column of a space counts, not only those a permission rule
-- reads: the copy in memory also answers the reads that show spaces (the
-- list of spaces, a space by its path), with their names, icons,
-- descriptions and order, so a change to any of them must reach it.
--
-- The row is one row that every such write updates. Two processes that
-- write at once (the server and the console, on PostgreSQL's serializable
-- writes) may then conflict on it, and one of them is run again: the
-- storage runs a write up to three times ('retrying'), which is enough for
-- writes as rare as these.
CREATE TABLE permissions_generation (
  id         INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
  generation INTEGER NOT NULL
);

INSERT INTO permissions_generation (id, generation) VALUES (1, 0);

-- SQLite's triggers run for each row a statement changes, inside the
-- database, so a statement that changes many rows bumps the number once for
-- each, at no cost of a round trip. A foreign key's action fires them too.

CREATE TRIGGER spaces_insert_permissions AFTER INSERT ON spaces
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

CREATE TRIGGER spaces_update_permissions AFTER UPDATE ON spaces
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

CREATE TRIGGER spaces_delete_permissions AFTER DELETE ON spaces
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

CREATE TRIGGER global_grants_insert_permissions AFTER INSERT ON global_grants
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

CREATE TRIGGER global_grants_update_permissions AFTER UPDATE ON global_grants
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

CREATE TRIGGER global_grants_delete_permissions AFTER DELETE ON global_grants
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

CREATE TRIGGER space_grants_insert_permissions AFTER INSERT ON space_grants
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

CREATE TRIGGER space_grants_update_permissions AFTER UPDATE ON space_grants
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

CREATE TRIGGER space_grants_delete_permissions AFTER DELETE ON space_grants
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

CREATE TRIGGER group_members_insert_permissions AFTER INSERT ON group_members
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

CREATE TRIGGER group_members_update_permissions AFTER UPDATE ON group_members
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

CREATE TRIGGER group_members_delete_permissions AFTER DELETE ON group_members
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

CREATE TRIGGER users_insert_permissions AFTER INSERT ON users
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

CREATE TRIGGER users_delete_permissions AFTER DELETE ON users
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

-- A user's other columns (the password, the e-mail address, the
-- notification settings) are not part of the permission context.
CREATE TRIGGER users_update_permissions AFTER UPDATE OF id, login, display_name, disabled ON users
WHEN OLD.id IS NOT NEW.id OR OLD.login IS NOT NEW.login OR OLD.display_name IS NOT NEW.display_name OR OLD.disabled IS NOT NEW.disabled
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

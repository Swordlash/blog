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
CREATE TABLE permissions_generation (
  id         INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
  generation BIGINT NOT NULL
);

INSERT INTO permissions_generation (id, generation) VALUES (1, 0);

-- PostgreSQL's triggers here run once for each statement, and bump the
-- number only if the statement changed a row (the rows it changed are the
-- trigger's transition table, "changed"): a statement that changes many
-- rows bumps it once, and a foreign key's action that changes none (a page
-- deleted that was no space's home page) does not bump it.
CREATE FUNCTION bump_permissions_generation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM changed) THEN
    UPDATE permissions_generation SET generation = generation + 1;
  END IF;
  RETURN NULL;
END
$$;

-- A user's other columns (the password, the e-mail address, the
-- notification settings) are not part of the permission context: an update
-- bumps the number only if it changed a user's id, login, name or whether
-- they are disabled.
CREATE FUNCTION bump_permissions_generation_users() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM after_update a
    WHERE NOT EXISTS (
      SELECT 1 FROM before_update b
      WHERE b.id = a.id AND b.login = a.login AND b.display_name = a.display_name AND b.disabled = a.disabled
    )
  ) THEN
    UPDATE permissions_generation SET generation = generation + 1;
  END IF;
  RETURN NULL;
END
$$;

CREATE TRIGGER spaces_insert_permissions AFTER INSERT ON spaces
  REFERENCING NEW TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();
CREATE TRIGGER spaces_delete_permissions AFTER DELETE ON spaces
  REFERENCING OLD TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();
CREATE TRIGGER spaces_update_permissions AFTER UPDATE ON spaces
  REFERENCING NEW TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();

CREATE TRIGGER global_grants_insert_permissions AFTER INSERT ON global_grants
  REFERENCING NEW TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();
CREATE TRIGGER global_grants_delete_permissions AFTER DELETE ON global_grants
  REFERENCING OLD TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();
CREATE TRIGGER global_grants_update_permissions AFTER UPDATE ON global_grants
  REFERENCING NEW TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();

CREATE TRIGGER space_grants_insert_permissions AFTER INSERT ON space_grants
  REFERENCING NEW TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();
CREATE TRIGGER space_grants_delete_permissions AFTER DELETE ON space_grants
  REFERENCING OLD TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();
CREATE TRIGGER space_grants_update_permissions AFTER UPDATE ON space_grants
  REFERENCING NEW TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();

CREATE TRIGGER group_members_insert_permissions AFTER INSERT ON group_members
  REFERENCING NEW TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();
CREATE TRIGGER group_members_delete_permissions AFTER DELETE ON group_members
  REFERENCING OLD TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();
CREATE TRIGGER group_members_update_permissions AFTER UPDATE ON group_members
  REFERENCING NEW TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();

CREATE TRIGGER users_insert_permissions AFTER INSERT ON users
  REFERENCING NEW TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();
CREATE TRIGGER users_delete_permissions AFTER DELETE ON users
  REFERENCING OLD TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation();
CREATE TRIGGER users_update_permissions AFTER UPDATE ON users
  REFERENCING OLD TABLE AS before_update NEW TABLE AS after_update FOR EACH STATEMENT EXECUTE FUNCTION bump_permissions_generation_users();

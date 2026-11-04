-- Private subspaces and personal spaces (WP5.54 of docs/PLAN.md,
-- Wiki.Core.Space).
--
-- sealed: the space is private from its parent. The grants and the public
-- flags of the spaces above it do not count in it, only its own and its
-- subspaces' (Wiki.Core.Permission.spacePermissions).
--
-- owner: the user whose personal space it is, none for any other space.
-- A user has at most one. The space belongs to its owner, so it goes with
-- the owner's account when an administrator removes the account.
--
-- active: whether a personal space is shown. Its owner turns it off from
-- the account menu, and it is then absent for everyone, its content kept,
-- until they turn it on again. Every other space is active.
--
-- personal_container: the space is the container of personal spaces,
-- "User subspaces", made when the first user turns one on. There is at
-- most one.
ALTER TABLE spaces ADD COLUMN sealed BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE spaces ADD COLUMN owner TEXT REFERENCES users (id) ON DELETE CASCADE;
ALTER TABLE spaces ADD COLUMN active BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE spaces ADD COLUMN personal_container BOOLEAN NOT NULL DEFAULT FALSE;
CREATE UNIQUE INDEX spaces_owner ON spaces (owner) WHERE owner IS NOT NULL;
CREATE UNIQUE INDEX spaces_personal_container ON spaces (personal_container) WHERE personal_container;

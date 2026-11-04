-- Avatars (WP5.55 of docs/PLAN.md, Wiki.Core.User.Avatar): the picture a
-- user uploaded of themselves, its bytes in the blob store as a space
-- icon's are (avatar_blob, the blob's id) with its media type
-- (avatar_media_type). Both are NULL for a user without one. Comments and
-- versions keep no copy: their authors' avatars are read from here, with
-- their names.
ALTER TABLE users ADD COLUMN avatar_blob TEXT NULL;
ALTER TABLE users ADD COLUMN avatar_media_type TEXT NULL;

-- A user's avatar is part of the permission context in memory: the user
-- who is asking is kept there with it, and a personal space with no icon of
-- its own is shown with its owner's avatar. So a change of either column
-- bumps the generation, as a change of the name does (the migration
-- 0002-permissions-generation).
DROP TRIGGER users_update_permissions;

CREATE TRIGGER users_update_permissions AFTER UPDATE OF id, login, display_name, disabled, avatar_blob, avatar_media_type ON users
WHEN OLD.id IS NOT NEW.id OR OLD.login IS NOT NEW.login OR OLD.display_name IS NOT NEW.display_name OR OLD.disabled IS NOT NEW.disabled
  OR OLD.avatar_blob IS NOT NEW.avatar_blob OR OLD.avatar_media_type IS NOT NEW.avatar_media_type
BEGIN
  UPDATE permissions_generation SET generation = generation + 1;
END;

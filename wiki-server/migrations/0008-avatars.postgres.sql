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
-- 0002-permissions-generation). The two columns may be NULL, hence IS NOT
-- DISTINCT FROM.
CREATE OR REPLACE FUNCTION bump_permissions_generation_users() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM after_update a
    WHERE NOT EXISTS (
      SELECT 1 FROM before_update b
      WHERE b.id = a.id AND b.login = a.login AND b.display_name = a.display_name AND b.disabled = a.disabled
        AND b.avatar_blob IS NOT DISTINCT FROM a.avatar_blob AND b.avatar_media_type IS NOT DISTINCT FROM a.avatar_media_type
    )
  ) THEN
    UPDATE permissions_generation SET generation = generation + 1;
  END IF;
  RETURN NULL;
END
$$;

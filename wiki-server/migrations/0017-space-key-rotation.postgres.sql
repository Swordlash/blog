-- A new key for an encrypted space when a reader is removed (WP5.74b3 of
-- docs/PLAN.md, item 2): a rotation makes the space a new key, seals it to
-- its readers, wraps every page key again with it, and gives every page a
-- new page key, which the versions written after are encrypted with.
--
-- key_grants keeps its grants when their recipient's account or public
-- key is deleted: a grant of the space's current key to someone who is no
-- longer a reader is what makes a rotation due, and a deleted account is
-- no longer one. A rotation deletes them. Which kinds of key a grant may
-- be of is checked by the program, so that a later kind needs no new
-- table.
--
-- page_keys holds every key a page has had, by (page_id, key_id): the
-- versions written before a rotation stay encrypted with the page key of
-- their time. current marks the one the next version is encrypted with,
-- one for each page.
--
-- notifications takes one more kind, renew-key: an administrator of an
-- encrypted space told that its key must be renewed.

ALTER TABLE key_grants DROP CONSTRAINT key_grants_recipient_fkey;
ALTER TABLE key_grants DROP CONSTRAINT key_grants_recipient_key_id_fkey;
ALTER TABLE key_grants DROP CONSTRAINT key_grants_resource_kind_check;

ALTER TABLE page_keys DROP CONSTRAINT page_keys_pkey;
ALTER TABLE page_keys ADD COLUMN current BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE page_keys ADD PRIMARY KEY (page_id, key_id);
CREATE UNIQUE INDEX page_keys_current ON page_keys (page_id) WHERE current;

ALTER TABLE notifications DROP CONSTRAINT notifications_kind_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_kind_check CHECK (kind IN ('mentioned', 'replied', 'commented', 'changed', 'renew-key'));

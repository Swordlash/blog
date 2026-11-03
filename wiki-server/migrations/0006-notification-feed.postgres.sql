-- The secret of a user's feed of notifications (WP5.31 of docs/PLAN.md):
-- the token in the address me/notifications.atom?token=…, made when the
-- user asks for the feed's address, replaced when they ask for a new one,
-- and none until then. The feed is found by the token, so it is indexed.
ALTER TABLE users ADD COLUMN feed_token TEXT;
CREATE UNIQUE INDEX users_feed_token ON users (feed_token);

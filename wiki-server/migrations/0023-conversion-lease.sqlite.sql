-- The lease on a conversion (item 4 of #213): one browser converts a
-- space's pages at a time. conversion_leases holds, for the space a
-- running conversion started from, the user whose browser converts it, the
-- token that browser's requests carry, and when the lease runs out unless
-- a page staged or committed renews it. A request with another token is
-- refused. The row goes when the conversion ends or is turned back.
CREATE TABLE conversion_leases (
  space_id   TEXT PRIMARY KEY NOT NULL REFERENCES spaces (id) ON DELETE CASCADE,
  holder     TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  token      TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

---
pr: 237
title: The upgrade's check looks at how people sign in
---

## New features

- `wiki-server check`, which every deploy runs after an upgrade, now
  refuses a stored password that nobody could sign in with (half of a
  password's record missing, one that does not decode, or an old-style
  hash the server cannot read), and names each such account. A deploy
  that finds one rolls back by itself, and a copy to PostgreSQL refuses
  to copy it:

  ```text
  wiki-server: The account anna (3f0c…) has an OPAQUE record without its stretch (opaque_stretch is empty), which no sign-in can use.
  wiki-server: Every record read, but some break a rule of the wiki's (above).
  ```

- When the check passes, it ends by saying how the accounts sign in, and
  which enabled accounts have no way in at all:

  ```text
  Every table and every record read.
  Accounts: 7 (6 enabled, 1 disabled). How the enabled ones sign in:
    with a password: 2, of which 1 with a hash from before OPAQUE until its next sign-in
    through a provider the settings name, with no password: 1
    with a passkey alone: 1
    no way in: 2
      finn: no password set
      gwen: only a provider the settings no longer name (gitlab)
  ```

  An account with no way in is not an error: one made without a password,
  one from an import, or one whose sign-in provider was removed. The list
  is there so that you can give them a password, or remove them.

- The rehearsal before a deploy has a new check, "ways in": every account
  that could sign in with a password before the upgrade must still be
  able to after it. If one cannot, the deploy stops before it touches the
  running wiki, and says which login:

  ```text
  wiki-server: ways in: failed: the login anna signed in with a password before the upgrade, and after it users list says no (no password)
  ```

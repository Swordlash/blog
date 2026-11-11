---
pr: 242
title: Every login is ASCII
---

## New features

- A login made before 2026-11-06, when logins came to be only ASCII
  letters, digits and punctuation, is renamed when the wiki is upgraded, if
  it breaks that rule: it becomes `user-` and the first eight letters and
  digits of the user's id. `wiki-server migrate`, which the deploy runs,
  prints a line for each:

  ```text
  Migrated the database from version 14 to 15 of the schema.
  Renamed the login "łucja" of the user 1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d to "user-1a2b3c4d", since a login is now ASCII letters, digits and punctuation, with a letter or digit, at most 64 characters and not ~ first. The user signs in with the same password under the new login.
  ```

  The administration's Activity lists the same rename, "Changed a user's
  login". The wiki tells the person nothing itself: pass the new login on.
  They sign in with the same password, and keep their sessions, their
  personal space at its address, their pages and their sign-in with a
  provider. A wiki with no such login prints nothing.

- `wiki-server check` now refuses a login that breaks the rule, and names
  the account, so a deploy that would leave one rolls back:

  ```text
  wiki-server: The account łucja (1a2b3c4d-…) has a login the rules of a login refuse: A login has only ASCII letters, digits and punctuation.
  ```

- The rehearsal before a deploy has a new check, "logins": an account whose
  login breaks the rule signs in after the upgrade, with its password,
  under its new login.

## Bug fixes

- An account made by signing in with a provider whose user name is only
  dots and underscores (`__`) got that as its login. It now gets the next
  choice, the e-mail address's first part or the name, or `user`.
- Importing a whole wiki's archive whose `users.json` holds a login the
  rule refuses is refused, naming the user, instead of bringing the login
  in. Merging an archive into a wiki, which brings no users, still works.

## Other changes

- An `@łucja` written in a page before the upgrade names nobody afterwards:
  mention the person by their new login.

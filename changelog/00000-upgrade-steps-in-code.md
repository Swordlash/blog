---
pr: 0
title: Upgrades can rewrite data in code, and their sign-in check is tested
---

## Other changes

- Before an upgrade switches to the new version, its rehearsal on a copy of
  the wiki already checks that an account with a password and an account
  through a sign-in provider, both made on the old version, still sign in
  on the new one. This check is now tested on every build, and fails with a
  message that says which sign-in did not work, for example "the
  password's first sign-in: not signed in".
- What the rehearsal asks of the old version (starting its server, making
  a user, reading the spaces and pages, signing in through a provider) is
  now documented as stable, so that the next version's rehearsal can still
  drive this one.
- A database upgrade can now include steps written in the server's own
  code, not only SQL, for changes such as rewriting every page's text from
  an old syntax to a new one. Such a step runs in the same transaction as
  the others: if it fails, the database stays exactly as it was before the
  upgrade.

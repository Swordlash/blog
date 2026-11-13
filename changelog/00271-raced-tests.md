---
pr: 271
title: Three tests no longer fail by chance on a busy machine
technical: true
---

## Other changes

- The test that reading and writing a page's HTML costs no more than in
  proportion to its length counts the memory the work takes instead of
  timing it, so a busy machine no longer fails it.
- The browser tests of the assistant's keys check, at the end of each
  test, only the keys that test made: a key one test left behind fails
  that test alone, not every test after it.
- The test of the PostgreSQL tests running side by side no longer takes
  PostgreSQL's own background work on a killed run's databases for a
  session the run left open:

  ```sh
  sh toolchain/test-postgres-namespaces.sh "$(cabal list-bin -v0 --builddir=dist-newstyle/native wiki-server:test:wiki-server-test)"
  ```

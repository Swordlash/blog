---
pr: 206
title: The deploy rehearses an upgrade on a copy of the wiki first
---

## New features

- Before an upgrade stops the running wiki, the deploy now tries the upgrade
  on a copy. It copies the database while the wiki keeps running, starts the
  old version on the copy and reads every page, migrates the copy with the new
  version, starts the new version and reads every page again. If a page is
  gone or reads differently, the deploy stops there, and the running wiki is
  as it was. This works for SQLite and PostgreSQL alike; on PostgreSQL the
  copy is a scratch database, `wiki_rehearsal`, removed afterwards.

  ```sh
  sh toolchain/deploy-local.sh            # the upgrade is rehearsed first
  sh toolchain/deploy-local.sh --no-rehearsal   # skips it, for an old version that cannot be driven
  ```

- `wiki-server rehearse` runs the same rehearsal by hand, against a live wiki
  and an old `wiki-server` program, in a scratch directory it removes at the
  end. It exits with 0 when every check passed, 6 when a check failed and 7
  when the old version could not be started or read.

  ```sh
  wiki-server rehearse --old ~/wiki-demo/bin/wiki-server --data ~/wiki-demo/data --scratch /tmp/rehearsal
  ```

- Every pull request's CI rehearses the upgrade from its base branch, on
  SQLite and on PostgreSQL.

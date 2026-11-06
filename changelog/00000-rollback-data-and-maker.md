---
pr: 0
title: Going back after a database switch, --fresh or an adoption
---

## New features

- An upgrade that switches the wiki between SQLite and PostgreSQL, or starts
  an empty wiki with `--fresh`, can now be undone. The old wiki is set
  aside, not deleted, and going back brings it back: the SQLite file from
  `data/replaced/`, or the PostgreSQL container on its old port. The wiki
  the failed upgrade started is set aside in its turn.

  ```sh
  sh toolchain/deploy-local.sh --postgres --fresh   # the upgrade moves the wiki to PostgreSQL
  sh toolchain/deploy-local.sh --rollback           # the SQLite wiki is back, as it was
  ```

- An upgrade that adopts a deployment under `--prefix` can be undone too:
  going back puts its state and its PostgreSQL files back in the home
  directory, where they were.

  ```sh
  sh toolchain/deploy-local.sh --prefix ~/wiki-demo   # adopts the deployment
  sh toolchain/deploy-local.sh --rollback --prefix ~/wiki-demo
  ```

- The configuration wizard is now the deploy screen of the maker's
  terminal interface, built with the maker instead of as a script of its
  own. `sh toolchain/configure.sh` runs it as before, with the same
  options; the maker runs it too:

  ```sh
  sh toolchain/maker.sh tui deploy
  ```

---
pr: 0
title: A deployed wiki moves from SQLite to PostgreSQL in one command
---

## New features

- A wiki that `deploy-local.sh` runs on SQLite can now move to PostgreSQL
  whole, accounts, passwords, settings and all, with one command, run from
  the checkout it was deployed from:

  ```sh
  sh toolchain/deploy-local.sh --move-to-postgres
  ```

  It builds the server with PostgreSQL, starts PostgreSQL in Docker as a
  deploy on PostgreSQL does, stops the wiki for a minute or two, backs it
  up, copies it, and checks that it reads the same in PostgreSQL as in
  SQLite before it switches the wiki over and starts it again. If anything
  fails, the wiki starts again on SQLite as it was. The SQLite file is
  never deleted: it is kept in `data/replaced/`, and `--rollback` goes back
  to it. Every deploy after the move keeps the wiki in PostgreSQL. The
  configuration wizard offers the move beside `--rollback`.

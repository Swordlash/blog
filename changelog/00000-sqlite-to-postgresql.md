---
pr: 0
title: A wiki in SQLite can be copied into PostgreSQL
---

## New features

- A wiki kept in SQLite can now move to PostgreSQL whole: its pages and
  their history, but also its accounts and their passwords, sessions,
  groups, permissions, settings, comments, notifications and the users'
  vaults, which an export and an import do not carry. Stop the server, make
  an empty PostgreSQL database, and copy the wiki into it:

  ```sh
  wiki-server copy-database --data /srv/wiki/data \
    --to-database postgres://wiki@127.0.0.1:5432/wiki \
    --to-database-password-file /srv/wiki/db-password
  ```

  The copy checks itself before it keeps anything: each table must read
  back from PostgreSQL as it is in SQLite, and the copy must read whole as
  the server reads a database. If anything is wrong it says what, keeps
  nothing, and leaves PostgreSQL empty. The SQLite file is never changed,
  and the attachments stay where they are. Then start the server on the
  copy with the same `--data` and `--database` in place of the SQLite file.
  The command refuses to run while a server is running on either database,
  and refuses a SQLite file that the running program has not migrated yet.

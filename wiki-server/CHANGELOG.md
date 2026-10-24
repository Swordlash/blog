# Changelog

## Unreleased

The storage, `Wiki.Server.Storage`: the wiki in an SQLite database, with the
attachments' bytes in files named by their SHA-256, behind the application's
`MonadWiki` (`SqliteWiki`), run as someone given per call: nobody, a user, or
the administrator, who passes every check. It passes the same contract as the
demo's in-memory backend. The schema is numbered SQL files under
`migrations/`, compiled into the program and applied in order, in one
transaction, when the storage is opened; `schema_version` records them, and a
database a newer program has migrated is refused. Every page keeps each of
its versions, and the text the search reads, prepared when it is saved. A
wiki comes in from an export archive into an empty storage, and goes out as
one.

`wiki-server backup --data DIR [--keep N]` copies the database aside with
SQLite's `VACUUM INTO`, into `DIR/backups/<time>.sqlite`, keeping the last N
(10 unless told). An attachment's file is deleted only when the storage is
opened and neither the database nor a backup kept refers to it, so that a
backup restored finds every file it names.

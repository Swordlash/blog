# Changelog

## Unreleased

The server. `wiki-server serve` (also what runs with no command) opens the
storage in `--data DIR` and serves the wiki on two listeners, each a Warp
server, in one process over one storage:

- the public listener, `--listen HOST:PORT` (default `127.0.0.1:8080`),
  serves the wiki at `--base-path` (default `/`) to an anonymous reader; with
  `--trust-network` everyone who reaches it is the administrator, which the
  server warns about as it starts and refuses on `0.0.0.0` or `::`;
- the admin listener, `--admin-listen HOST:PORT` (default `127.0.0.1:8081`,
  `--no-admin-listen` for none), serves the same at `/admin/` to the
  administrator without a login, and is refused on any address that is not
  loopback unless `--admin-listen-unsafe`.

Each serves the HTTP API of `wiki-api` under `api/v1/`, every refusal (the
routing's own, a body that does not parse, an upload over its limit
included) as an `ApiError`, and, with `--static DIR`, the built application
around it as the demo's static server did: a directory's `index.html`,
`404.html` with a 404 for any other address, precompressed `.br` and `.gz`
siblings, media types, `no-cache` with an `ETag`, nothing outside the
directory; every page with the `<base href>` of the place it is served at.
An attachment is streamed from its file with its media type, a `Range` answered,
`nosniff`, a sandboxing `Content-Security-Policy`, and shown in the browser only
when it is an image, a video, audio or plain text. An attachment is at most 50
MB; an archive to import at most `--max-import-size` MiB (512).

Export downloads the wiki as a zip file; import merges an archive into the
wiki in two steps, a preview and the import as chosen, matching spaces and
pages by path: a new space is made, a space on both sides merged (its math
macros taken when the server's are empty), a page on both sides kept as the
server has it unless the imported one is chosen, which replaces its title,
body and attachments as a new version. The archive's users, groups and grants
are not imported. Both, and `GET api/v1/admin/status` (version, data
directory, counts), are the administrator's only.

The log is one `key=value` line per request on standard output (listener,
principal, client, method, path without its query, status, milliseconds),
and an error line with the exception for a handler that throws. `SIGTERM` or
`SIGINT` stops accepting connections and lets those under way finish (ten
seconds at most) before the database is closed. `--version` says which
program it is.

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

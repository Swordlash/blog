# Changelog

## Unreleased

The administration's people, over the tables the schema had from the start
(no migration): `SqliteWiki` is a `MonadAdmin` (`Wiki.App.Backend.Admin`),
each operation one transaction that first checks for the global administer
(the operator, or a user granted it). Deleting a group deletes the grants to
it as well, which name it in a column that is no foreign key. The API's
`admin/directory`, `admin/users/<user>/administrator`, `admin/groups…`
endpoints are answered on the admin listener without a session, on the
public one under `--trust-network`, and refused (403) to an anonymous reader.

The server comes as a Docker image. The repository's `Dockerfile` builds
`wiki-server` at `-O2` and the application in its server mode, on the pinned
toolchain, into a Debian slim image that runs as an unprivileged user (uid
10001) and keeps its data in a volume at `/data`; `docker-compose.yml` publishes
the public listener on port 8080 and keeps the admin listener on the
container's loopback, reached with `docker compose exec`. The image's
entrypoint backs the database up before each start of the server, as a deploy
does. `--trust-network` is not accepted on `0.0.0.0`, so trusted mode runs the
container on the host's network with the server bound to the private address
(`docker-compose.trusted.yml`). See the README's "Running in Docker".

Page history, over the `page_versions` table the schema had from the start
(no migration): `SqliteWiki` lists a page's versions, the latest first
(ordered by time in Haskell, since the times' text does not sort as times
when one has no fraction), gives one by its time and restores one as a save
of it in the same transaction, conflict check and draft discarded included.
A version's author is named from the users table, the administrator as
`Administrator`, someone no longer a user by their id, and an imported page
as nobody known. The API serves the three endpoints, and the server renders
a page's history (`…/p/<page>/history/`), with a 404 for a `version` the page
does not have.

The server renders the wiki's pages. With a build that has a `template.html`
(`wiki-app-prerender --server` writes one), every address a page would be
served at, a directory's or one with no file, gets the application rendered
at the route it names, per request, as the listener's principal sees it: the
shell and its views over the backend over HTTP, whose requests the API's
application answers in the same process (`Wiki.Server.Render.inProcess`, which
the tests used to have to themselves). A page is complete before any script
runs. Its status is 200; 404 for an address that is no route and for a space or
a page that is not there; 403 for a space the reader may not see, whose page
says only that. The page carries, as JSON in a
`<script type="application/json" id="wiki-preload">` (every `<` escaped), the
API's answers the render read, which the program starts from. A rendered page
goes out with `no-cache` and no `ETag`, since it is for that reader and that
moment; nothing is cached on the server. Each render is logged
(`event=render`, its route, status, milliseconds and size).

A render that throws, takes more than ten seconds, or in which the API could
not answer something, is logged as an error and the address gets what it got
before: the build's `index.html` or `404.html`. A build without a template is
served as before.

The admin listener renders its pages below `/admin/`, links included, so it
no longer redirects addresses below the public base path to the same ones
below `/admin/`: only its root and `/admin` without the slash are redirected.
`Listener` has no `redirectFrom` any more.

`toApiError` gives `Maybe ApiError`: the application's `WikiError` has an
`Unreachable`, which is no refusal and has no `ApiError`. `wikiError` answers
it with a 503, which a client reads as the server failing; the storage never
gives it.

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

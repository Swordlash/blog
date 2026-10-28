# Changelog

## Unreleased

The export (`GET api/v1/export`) writes version 2 of the export format
(WP5.8, `docs/export.md`), the pages' comments included, read in two
queries for the whole wiki inside the export's read transaction. The
administrator's comments name them by the login `administrator`. Both
imports read versions 1 and 2. Loading a wiki into an empty storage
(`importArchive`) brings every comment with its id, its times, its edit
and its thread's resolution. The merge (`api/v1/import/apply`) brings a
page's comments with its content: a page it makes, and a page whose
content it replaces, get the archive's threads that the page does not have
yet, after its own; a page the server keeps keeps its own. Comments'
authors are matched by login with the server's users and its
administrator; anyone else is kept by their name and shown as "(not a user
here)". The import's audit entry counts the comments. An export of a wiki
with two attachments of the same bytes now imports: their shared blob used
to be refused. No migration.

The list of a space's pages carries no bodies (WP5.14): it reads only the
pages' titles, slugs, places and dates, however long the pages are. The
details of a blog's posts carry each post's excerpt instead. A space's
export and a blog's feed read the bodies themselves
(`Wiki.Server.Storage.spacePages`). A prerendered page carries the page it
shows by itself, beside its space's list.

Reads no longer wait for writes, or for one another (WP5.16a). The storage
opens four read-only SQLite connections beside the one that writes. Every
operation that only reads runs on one of them, and so do the lookup of a
request's session and the live channel's permission checks. A backup
copies the database through a connection of its own, so requests go on
while it runs. An import still holds the writer for its whole length, but
no longer stops reads. Writes still run one after another, in the order
they commit. The new `wiki-server-bench` executable times a big wiki's
page view, save, backup and comment, to compare two versions of the
storage.

A save or a comment reads only the users who could be told of it
(WP5.16a): those who watch the page or one of its spaces, the page's
maker, the thread's commenters and the people it mentions. It used to read
every user, every watch and every group membership. Migration
`0013-notification-indexes.sql` adds the indexes this needs, and one on
the notifications' `seq`: each new notification's number used to be found
by scanning the whole table. Who made a page is now read from its first
version alone.

The bell reads one page of a user's notifications, not all of them
(WP5.16a). It used to read every notification kept for the user (up to
500), and the pages of a whole space for each one, on every page view. It
now reads the newest 50, and reads further only when some of those are
about pages the user may no longer read. The pages of each space are read
once. The unread count is one SQL count by space, and still leaves out
notifications about pages the user may no longer read.

The live channel checks once per user whether an event's page may be
read, not once per tab (WP5.16a). An event on a page that 100 tabs of 3
users show makes 3 permission checks, on the storage's readers. `Who`
now has an `Ord` instance.

The static files' server sends a `.bin` file as `application/octet-stream`,
named so explicitly (WP5.5): TikZJax's compressed files are now zlib streams
named `.bin` rather than gzip files named `.gz`, since a corporate proxy may
refuse to download a gzip archive from a site it does not know. A `.gz` is
still sent as `application/gzip`, as its own bytes.

No password for accounts that sign in with a provider; the administrator
mails password links (WP5.6). An account that has no password and an
identity at a provider the server's settings have has no password to set:
`PUT account/password` and `PUT admin/users/<id>/password` answer 400 with
the reason, "Forgot your password?" mails it no link, and a link mailed
before sets none (400). Only configured providers count, so an account whose
last provider is disconnected or removed from the settings may be given a
password again. The directory says who (`providerOnly`). New `POST
admin/users/<id>/password-link` mails a user the reset's own link, to their
verified address, at once (204), recorded in the audit log as
`user.password-link`; 400 with the reason when the server sends no mail,
the user has no password to set, is disabled or has no verified address,
or the mail fails (the link is then forgotten); 429 within a minute of any
reset link the account was given. The public reset's limits do not apply
to it, but it counts towards the account's three an hour. The console's
`users password` is unchanged: it stays the operator's way in.

Licensed under the MIT licence (WP5.1), where it was proprietary: the
package now ships `LICENSE` and says `license: MIT` in its `.cabal` file.
A binary of `wiki-server` links pandoc, texmath and skylighting, which are
GPL-2.0-or-later, so whoever conveys one conveys it under the GPL (version 3,
since haskell-halogen's Apache-2.0 is linked too); the README's licence
section has the table of third-party licences.

Tables of contents and templates (WP4.15). Migration `0012-page-template.sql`
adds `pages.template`; `PUT api/v1/pages/<id>/template` sets it, as whoever
may edit the page (not a save: no version, `updated_at` unchanged; a
space's home page cannot be one). A search leaves templates out unless it
has `templates`, and `spaces/page-counts` does not count them. An import
keeps the flag of a page it makes, and a page it replaces keeps its own.
Feeds render headings without their anchor links, and an exported document
leaves out a `[[toc]]` paragraph, since its writer has a table of contents
of its own.

Reading offline (WP4.17). A `.webmanifest` file is served as
`application/manifest+json`. The service worker, `sw.js`, is one of the
application's files at the place the wiki is served at, which is its scope, so
it needs no `Service-Worker-Allowed` header, under the base path and the admin
listener's `/admin/` alike.

Observability (WP4.10). Migration `0009-audit-log.sql`: the `audit_log`
table, one row for each write of the administration's (grants on spaces and
of the wiki, a space made public, groups and members, accounts, the wiki's,
the server's and the backups' settings, invitations made, revoked and
accepted, accounts people make themselves, deletions of spaces and pages,
imports, and what `wiki-server users …` does, as `administrator` from
`console`), written by the storage in the write's own transaction
(`Wiki.Server.Storage.Audit`); its `detail` says what changed, a secret only
as `changed` or `cleared`; `address` is the request's (`Caller.address`,
`runSqliteWikiFrom`). `GET api/v1/admin/activity` pages through it, by
actor. The export carries it (`audit.json`), `importArchive` restores it and
the panel's import merges it, each entry once by id, and records itself.
`GET /metrics` on the admin listener only, Prometheus text written by hand
(`Wiki.Server.Metrics`): requests by listener, route pattern, method and
status class, a latency histogram, and gauges for live channels, spaces,
pages, attachments, users, the database's and the blobs' bytes, the backups
kept and the newest one's age, the schema's version, errors logged. Route
patterns are read from the API's own servant router
(`Wiki.Server.Routes`), so no id or secret of an address is a label; the
request log gains a `route` field. `GET /healthz` on both listeners
(`Wiki.Server.Health`): status, schema version, the newest backup's age.
`GET api/v1/admin/status` gains `schemaVersion`, `lastBackup`,
`connections` and the last twenty errors logged (`Wiki.Server.Log`'s
`ErrorRing`, kept by `keepingErrors`); a request answered with a 5xx is now
logged as an error. `Logger` carries the level and fields to its writer.
`Wiki.Server.Storage.Migrate` is compiled whenever the package is, so that a
migration added is embedded without deleting the build directory.

Spaces shown as blogs (WP4.14). Migration `0010-space-blog.sql` adds
`spaces.blog`; the storage answers `postDetails` (the earliest version's
author, the comments of every thread). `Wiki.Server.Feed` serves
`/s/<space>/feed.xml` (Atom) and `/s/<space>/feed.rss` (RSS 2.0, the
author as Dublin Core's `creator`) for a public space shown as a blog: its
newest 20 posts whole, rendered through the allowlist with their links and
attachments absolute; and `/sitemap.xml`, every public space and page with
its last change, at most 50 000. Both answer what an anonymous reader may
see whoever asks, and 404 otherwise and in a closed wiki. Absolute
addresses are under the panel's public address, or the request's own
(`Wiki.Server.Address`: `X-Forwarded-Host` or `Host`, `X-Forwarded-Proto`
or http, and the listener's place). The pages the server renders carry the
head `Wiki.App.Head` describes. An import shows a space as a blog when the
archive does.

Mentions, watching and notifications (WP4.13). Migration
`0011-notifications.sql`: `watches`, `notifications`, and `users`'
`notification_mail` and `watch_own`. Notifications are made in the save's or
comment's transaction, told to the user's connections over the live channel
once committed, and mailed by a thread of the server's (`Wiki.Server.Notifier`):
at once, or in a daily digest from 07:00 UTC, only to a verified address,
after checking again that the user may read the page, with an unsubscribe
link signed with a key the server keeps in `settings`. Notifications are
kept 90 days, at most 500 a user. The API's `notifications…` and
`unsubscribe/<secret>` are served; the latter is open in a closed wiki. A
space's profile changed in its settings, or its icon uploaded, is recorded
in the audit log as `space.profile`, with the fields that changed; a save
that changed nothing is not.

Account hygiene (WP4.11). Migration `0008-account-hygiene.sql`: `users.email`
and `email_verified_at`; `sessions.public_id` (filled for existing sessions)
and `address`; tables `totp`, `recovery_codes`, `reset_tokens` and
`email_verifications`, each going with its user. A session records where it
was last used from, and its last use at most once a minute
(`Accounts.seenEvery`); the cookie is still sent again hourly. A user lists
their sessions and ends one or all others (`GET`/`DELETE
api/v1/account/sessions[/<id>]`). A TOTP second factor (`Wiki.Server.Totp`:
RFC 4226/6238 over crypton's HMAC-SHA1, checked against both RFCs' vectors;
`Wiki.Server.SecondFactor`): begun, confirmed with a code (ten recovery
codes, SHA-256), removed with a code or by an administrator (`DELETE
api/v1/admin/users/<id>/second-factor`, and `wiki-server users
second-factor-remove LOGIN`). The QR code's modules are computed with
`qrcode-core` (an `allow-newer` on its `containers`). With one on, signing in
with a password answers 401 `SecondFactorRequired` and a `wiki_pending`
cookie (five minutes, five wrong codes) that `POST
api/v1/session/second-factor` ends; a provider's callback answers a code form
of its own posted to `auth/<provider>/second-factor`. Wrong codes count as
failed sign-ins. E-mail addresses (`Wiki.Server.Reset`) set by the user or the
administration's "New user", verified by a mailed link (a day,
`POST api/v1/email-verification/<secret>`); a password reset
(`POST api/v1/password-reset`) mails a single-use 30-minute link to a verified
address only, three an hour per account at most, looked up and mailed on a
thread after a 204 that is the same whatever the login, ten requests an
address in fifteen minutes (`Env.resets`), refused alike where no mail is
set; `POST api/v1/password-reset/<secret>` sets the password and ends every
session. `Env` gains `resets`, `pending` and `logger`; `Signing` gains
`pending`. The log hides the new links' secrets. `resolveSession`,
`signIn`, `register`, `acceptInvitation` and `landWith` take the request's
address.

Presence and edit conflicts (WP4.12). The live channel keeps, per
connection, the pages its tab says it edits (`{"editing": page}`, from
someone who may edit the page; `{"stopped": page}`), in memory
(`Wiki.Server.Presence`), and drops them with the connection; whenever who
edits a page changes, every connection subscribed to it is told who else
edits it (`Editing`), and the answer to a subscription says so too. A save of
a page, and a version restored, is told to the page's subscribers as
`PageChanged` with the new version's time, once committed (`Config.publish`
is now about pages, not only their comments). `Storage.editorOf` names
someone who may edit a page. No migration.

Scheduled backups, off by default (WP4.9). The server backs itself up once an
administrator turns that on in the administration (`GET`/`PUT
api/v1/admin/server/backups`, `POST …/run` for "Back up now"); nothing turns it
on from the command line. A thread of the server (`Wiki.Server.Backups`) reads
the settings from the `settings` table (rows `backup-*`, no migration) and
backs up when one is due: `VACUUM INTO data/backups/<time>.sqlite` with the
storage's connection held for the copy alone, `PRAGMA integrity_check` (a copy
that fails is deleted), the old ones pruned to the newest of so many days and
weeks (the deploy's included), and the new one with the attachments' files
copied to a directory or an rclone remote (`--rclone PATH`, `rclone` by
default), never deleting anything there. The rclone configuration is a
write-only secret, written for each run to a file only the server's user may
read and deleted after. The last backup's result is kept as the row
`backup-last`. `wiki-server restore BACKUP --data DIR [--attachments DIR]`
puts a backup back into a data directory, keeping the database it replaces
under `replaced/<time>/`. The storage now holds an `flock` on
`<data>/wiki.lock` while it is open (`DataDirInUse` otherwise), so a restore,
or a second server, is refused a data directory a server is running on.

Export to documents with pandoc (WP4.16), linked as a library (pandoc 3.12.1,
with its data files embedded and without its HTTP client, so that a
document never makes the server fetch anything): `GET
api/v1/pages/<page>/export/<format>` and `GET
api/v1/spaces/<space>/export/<format>` (`Wiki.Server.Export`), for whoever
may read the page or view the space, one export at a time each and at most
60 seconds. DOCX, standalone HTML, EPUB, and for a deck PowerPoint and
Beamer's LaTeX need nothing installed; the PDFs (a page's, a space's and a
deck's Beamer PDF) are typeset by `xelatex` through pandoc's PDF path when
the machine has it (`apt install texlive-xetex`), looked for at each
request, so installing it needs no restart. A page is read by pandoc's
Markdown reader with the extensions the wiki reads
(`Wiki.Server.Export.Document`): raw HTML through the wiki's allowlist, the
page's images from the blob store, the math macros of the wiki, the space
and the page expanded into each formula, Mermaid diagrams as notes with
their source, TikZ pictures drawn in the PDFs and Beamer and noted
elsewhere; a deck cut into slides as the wiki cuts it, its theme and aspect
mapped to Beamer's. The session's `exports` says which formats the server
makes. No migration. The first build after this is long: pandoc and its
dependencies are compiled once into the cabal store.

One space at a time (WP4.6). Migration `0007-space-profile.sql`: a space's
`home_page` (a page, `ON DELETE SET NULL`), `icon` (its JSON) and
`description`. A space made through the API comes with a "Home" page; a page
moved to another space stops being its old space's home page. The space's
profile is set with `PUT api/v1/spaces/<space>/profile`, an image for its
icon uploaded with `POST api/v1/spaces/<space>/icon` and served at
`GET api/v1/spaces/<space>/icon/<blob>` as an attachment is; the image is
kept in the blob store, and the files nothing refers to are collected with
the icons counted (a backup from before the migration refers to none).
`GET api/v1/spaces/page-counts`. The export and the whole import carry the
profiles and the icons' images; the merging import fills in a merged space's
description, icon and home page where it has none. `Config` gains
`iconAddress`. The server renders the directory of spaces at `/` and a
space's list of pages at `/s/<space>/pages/`, with a space's 403 and 404.

The server's settings from the administration (WP4.4). The wiki's public
address, its mail server and the providers people sign in with are no longer
options: `--smtp-host`, `--smtp-port`, `--smtp-security`, `--smtp-user`,
`--smtp-from`, `--public-url` and `--oidc` are refused with a pointer to the
administration's "Server" section, and `WIKI_SMTP_PASSWORD` and
`WIKI_OIDC_<NAME>_SECRET` are not read. They are kept in the database
(migration `0005-server-settings.sql`: rows of `settings` and a
`sign_in_providers` table), secrets included, set through `GET`/`PUT
api/v1/admin/server` (secrets never answered), and read per request, so a
change takes effect at once: the mailer is made per mail, and a provider's
discovery is asked again whenever its settings change. `POST
api/v1/admin/server/providers/<name>/check` runs discovery on a provider as
set or as typed; `POST api/v1/admin/server/mail/test` sends a test mail.
`wiki-server oidc check` takes `--data DIR` and checks the providers set
there. `withServerUsing` takes how mail is sent instead of a mailer and the
providers. An upgraded server starts with nothing set: set the address, mail
and providers again in the panel.

Comments (WP4.5). Migration `0006-comments.sql`: `threads` (on a page,
with an anchor's quote, prefix and suffix or none, resolved, their order)
and `comments` (author by id, Markdown body, created and edited times, their
order), deleted with their page. `SqliteWiki` is a `MonadComments`, each
operation one transaction under the rules of `Wiki.Core.Comment`, served at
`api/v1/pages/<page>/threads…`. The live channel, `api/v1/events`, is a
WebSocket (`websockets` and `wai-websockets`, `Wiki.Server.Events`): the
upgrade is authenticated by the session cookie as any request, refused 401
in a closed wiki to someone not signed in and 403 to another site's page
(its `Origin`); a tab subscribes to the pages it shows, each checked and
answered with the page's threads (read in the same hold of the storage as
the subscription is made, `Wiki.Server.Storage.threadsThen`, so that no
change falls between the two), and hears of every change to their comments once it is committed (the
storage's `Config.publish`), checked again before it is sent. The hub keeps
subscriptions in memory, pings every 20 seconds, closes a connection 256
messages behind and every connection when the server stops.

One's own password (WP3.7). `PUT api/v1/account/password` lets a user signed
in change their password, giving the current one, or set one if they sign in
only with a provider; the new one is checked first, then the current one,
whose wrong guesses count against the sign-in limit of the user's login from
that address (a right one clears it). Every other session of the user ends,
the one the request came with stays. The operator of the admin listener is
refused with 400, as for the rest of `account/…`. `Accounts.changePassword`
does it in one transaction after hashing, refusing with a 409 if the password
changed meanwhile.

Signing in with a provider (WP3.6): Google, GitHub, Apple, or any OpenID
Connect provider, each `--oidc NAME=KIND,CLIENT-ID[,ISSUER]` with its client
secret in `WIKI_OIDC_<NAME>_SECRET` (never the command line) and
`--public-url`, below which its redirect URI is (`auth/<NAME>/callback`);
`checkOptions` refuses a provider without `--public-url`, a bad name, an
`oidc` without its issuer, or one that is not `https` (but on this machine),
and the server will not start without each secret. `auth/<NAME>/start` and
`auth/<NAME>/callback` on the public listener, answered in a closed wiki too:
the authorization code flow with PKCE (but Apple's) and a nonce, the round
trip kept in memory for ten minutes and bound to the browser by a cookie of
its own (`wiki_oidc`, `SameSite=Lax`), the ID token's `iss`, `aud`, `exp` and
`nonce` checked without a signature check (it comes from the token endpoint
over TLS), GitHub's user and verified e-mail from its API, Apple's
`form_post` answer taken through a page of the wiki's. A known identity
signs its user in (not a disabled one); an unknown one is connected to the
user who asked, makes the account of an invitation it carries, makes an
account in an open wiki, and is refused in a closed one. The callback
answers with a page that goes on, not a redirect, so that the
`SameSite=Strict` session cookie is sent. Migration `0004-identities.sql`
adds `identities`; `GET`/`DELETE api/v1/account/identities` (not the last
way in) and `DELETE api/v1/admin/users/<id>/identities/<provider>` (which
ends the user's sessions); the session lists the providers. `wiki-server
oidc check` asks each provider how to sign in and prints its redirect URI.
New dependencies: `http-client`, `http-client-tls`, `http-api-data`.

An open or closed wiki (WP3.5). Migration `0003-settings.sql` adds
`settings` (an existing wiki stays open) and `invitations`. The settings are
kept in memory once read, and replaced under the connection's lock when they
change. In a closed wiki the public listener answers someone not signed in 401
on the API (but for `info`, `session`, `accounts`, `invitations`) and renders
every page as the way to sign in, with a 401, but an invitation's; the admin
listener is unchanged. Accounts may be made by anyone in an open wiki and by
invitation in any wiki, five attempts an address in fifteen minutes; new
accounts get the global `create-spaces` if the settings say so. Invitations
are mailed through SMTP with `--smtp-host`, `--smtp-port` (587; 465 is
implicit TLS, any other STARTTLS), `--smtp-security tls|starttls|plain`,
`--smtp-user` (its password from `WIKI_SMTP_PASSWORD`, never the command
line), `--smtp-from` and `--public-url`, through `smtp-mail` (which needs
`allow-newer` for `serialise` and `cborg` on GHC 9.14, in `cabal.project`);
without SMTP the panel shows the link. Invitation secrets never reach the log.

`--trust-network` is gone, with its warning and its refusal on `0.0.0.0`:
the public listener serves whoever signs in, and anyone else as an anonymous
reader; make the first administrator with `wiki-server users add LOGIN
--admin`. `ServerStatus` no longer reports it, and `docker-compose.trusted.yml`
is removed. The administration's account endpoints now go through the
storage (`SqliteWiki`'s new `MonadAdmin` methods `createUser`, `setPassword`,
`setDisabled`), which checks for an administrator before it hashes a
password; `PUT admin/users/<user>/create-spaces` grants or takes the global
create-spaces; `GET`/`PUT spaces/<space>/grants` read and change a space's
grants, for whoever administers it. No migration: the tables of 0001 hold it
all.

Accounts and sessions. Migration 0002 gives users an argon2id password hash
(nullable: a user without one cannot sign in, as every user made before is)
and a `disabled` flag, and adds `sessions`, keyed by the SHA-256 of each
session's random id. The public listener now finds who is asking per
request: the user whose session the `wiki_session` cookie names, or nobody
(no cookie, an ended session, a disabled user, and the cookie is then
cleared); the admin listener is still the operator, looking at no
cookie. Handlers are
given the caller (`Wiki.Server.Api.Caller`) instead of the listener's `Who`.
`POST api/v1/session` signs in (401 for a wrong login or password, 429 after
too many failures per login and address or per address, in memory), `DELETE`
signs out; the cookie is `HttpOnly`, `SameSite=Strict`, at the base path, and
`Secure` only with the new `--secure-cookies`; a session ends after two weeks
unused, on sign-out, and when its user is disabled or given a new password.
Every request that changes something, on both listeners, must carry
`X-Wiki-Request` (403 otherwise). The administration API makes a user with a
password, sets a password and disables a login. Answers and rendered pages
are `Cache-Control: private, no-cache` with `Vary: Cookie`, and a page is
rendered as the request's principal, signed-in users included.

`wiki-server users list|add|password|admin|disable --data DIR` makes and
changes users from the console, beside a running server, reading a password
from the terminal (asked twice, not echoed) or the first line of standard
input: the first administrator is made there. New dependencies: `crypton`
(argon2, its C compiled in) and `ram`.

The administration's people, over the tables the schema had from the start
(no migration): `SqliteWiki` is a `MonadAdmin` (`Wiki.App.Backend.Admin`),
each operation one transaction that first checks for the global administer
(the operator, or a user granted it). Deleting a group deletes the grants to
it as well, which name it in a column that is no foreign key. The API's
`admin/directory`, `admin/users/<user>/administrator`, `admin/groups…`
endpoints are answered on the admin listener without a session, on the
public one to an administrator's session, and refused (403) to anyone else.

The server comes as a Docker image. The repository's `Dockerfile` builds
`wiki-server` at `-O2` and the application in its server mode, on the pinned
toolchain, into a Debian slim image that runs as an unprivileged user (uid
10001) and keeps its data in a volume at `/data`; `docker-compose.yml` publishes
the public listener on port 8080 and keeps the admin listener on the
container's loopback, reached with `docker compose exec`. The image's
entrypoint backs the database up before each start of the server, as a deploy
does. See the README's "Running in Docker".

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
  serves the wiki at `--base-path` (default `/`) to whoever signs in there,
  and to anyone else as an anonymous reader;
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

A page's slides (`…/p/<page>/slides/`) are rendered per request like every
other route, with a 403 or a 404 where the page would have one.

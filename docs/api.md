# The HTTP API

The server speaks one HTTP API, under `/api/v1`, and the application's backend
over HTTP is its client. The API is a servant type, `Wiki.Api` in `wiki-api`:
the server serves that type, and the client makes every address it requests
from the same type (`Wiki.Api.Links`), so the two cannot disagree about a
path, a parameter or a header. It covers everything the application's backend
interface (`MonadWiki` in `wiki-app`) does, one endpoint per method, plus what
only the server does: describing itself, exporting the wiki and importing an
archive. The Haddock of `Wiki.Api` and of each module under it says the same
as this page.

## Conventions

- **Addresses are relative to the application.** Every path below starts at
  `api/v1`, and a browser resolves it against the page's `<base href>`, so a
  wiki served below a path (`HALOGEN_BASE_PATH`) has its API below the same
  path. Ids (`<space>`, `<page>`, `<attachment>`) are the opaque text the
  server gave them, percent-encoded; slugs keep the slug rules, and a path
  segment that is not a slug is refused with 400.
- **Bodies are JSON** (`Content-Type: application/json`), except an
  attachment's file and an archive, which are sent as a multipart form
  (`multipart/form-data`, a browser's `FormData`) and come back as bytes. A
  request body is an object whose fields name its arguments, even for one
  argument (`{"name": "Team"}`), so that a field can be added later. A
  response is one of the domain's own types, whose JSON the golden files in
  `wiki-api/test-server/golden/` pin down.
- **Times** are ISO 8601 in UTC, with as many digits of the second as they
  have (`"2026-10-24T09:30:12.345678Z"`).
- **Making something** answers 201 with what was made; **deleting** answers
  204 with no body; everything else answers 200.
- **A page's version is its `updatedAt`.** Every response that carries a page
  by itself carries its version as the `ETag` header, the time quoted:
  `ETag: "2026-10-24T09:30:12.345678Z"`. A save sends the version it was
  made from as `If-Match`, the same text, which the client can make from the
  page it holds without having kept the header. A save against an older
  version is a conflict (409); one without `If-Match`, or with a tag that is
  weak (`W/"…"`), `*` or not a time, is refused with 400.
- **Who is asking** is the server's to decide, from the listener the request
  came in on and, from Phase 3, its session; no endpoint takes it as an
  argument.

## Errors

A refusal is a status and a JSON body naming the reason, one per constructor
of the backend's `WikiError`, with its text where it has one:

| Status | Body | When |
| ------ | ---- | ---- |
| 404 | `{"error": "NotFound"}` | an id or a path names nothing |
| 403 | `{"error": "Forbidden"}` | it names something the user may not see, or may not do this to |
| 400 | `{"error": "Invalid", "message": "…"}` | the request cannot be carried out as it is |
| 409 | `{"error": "Conflict", "message": "…"}` | the wiki has changed since the request was made |

When more than one applies, the first in the order of `MonadWiki`'s Haddock
is given: not found, forbidden, invalid, conflict. So a user who may not act
learns nothing about whether their request was otherwise well formed. Any
endpoint may answer any of these; the table below names the ones each is
expected to give. A response with a 4xx status and no such body (one the
routing answered before a handler ran, or a proxy) means the error of its
status: 404 and 410 not found, 401 and 403 forbidden, 409 and 412 conflict,
any other 4xx invalid (`Wiki.Api.Error.errorForStatus`). A 5xx is a failure
of the server, not a refusal.

## Endpoints

`MonadWiki` names the method of the backend interface each endpoint carries.

### The server and the session

| Method | Path | Body | Response | Errors | `MonadWiki` |
| ------ | ---- | ---- | -------- | ------ | ----------- |
| GET | `api/v1/info` | | `ServerInfo` `{"name", "apiVersion"}` | | |
| GET | `api/v1/session` | | `SessionInfo` `{"user", "groups", "grants"}`: the user (`null` for nobody signed in), their groups, and the grants given to them or their groups | | `session` |

### Spaces

| Method | Path | Body | Response | Errors | `MonadWiki` |
| ------ | ---- | ---- | -------- | ------ | ----------- |
| GET | `api/v1/spaces` | | `[Space]`, every space the user may view with its ancestors, each before its subspaces | | `listSpaces` |
| GET | `api/v1/spaces/at/<slug>/<slug>…` | | `Space` at that path from the top level | 404, 403 | `getSpace` |
| POST | `api/v1/spaces` | `NewSpace` `{"parent": id or null, "name"}` | 201 `Space` | 404, 403, 400 | `createSpace` |
| PUT | `api/v1/spaces/<space>/name` | `SpaceName` `{"name"}` | `Space` | 404, 403, 400 | `renameSpace` |
| PUT | `api/v1/spaces/<space>/public` | `SpacePublic` `{"public": bool}` | `Space` | 404, 403 | `setSpacePublic` |
| PUT | `api/v1/spaces/<space>/math-macros` | `SpaceMathMacros` `{"mathMacros"}` | `Space` | 404, 403 | `setSpaceMathMacros` |
| PUT | `api/v1/spaces/<space>/order` | `SpaceOrder` `{"children": "ChildSpaces" or "ChildPages", "order": "ByName", "NewestFirst", "OldestFirst" or "ByHand"}` | `Space` | 404, 403 | `setSpaceOrder` |
| POST | `api/v1/spaces/<space>/move` | `SpaceMove` `{"parent": id or null}` | `Space` | 404, 403, 400 | `moveSpace` |
| POST | `api/v1/spaces/<space>/shift` | `ShiftBy` `{"shift": "ShiftUp", "ShiftDown", "ShiftToTop" or "ShiftToBottom"}` | `Space`, with its new position | 404, 403, 400 | `shiftSpace` |
| DELETE | `api/v1/spaces/<space>` | | 204 | 404, 403 | `deleteSpace` |

### Pages

| Method | Path | Body | Response | Errors | `MonadWiki` |
| ------ | ---- | ---- | -------- | ------ | ----------- |
| GET | `api/v1/spaces/<space>/pages` | | `[Page]`, the space's whole tree, each page before the pages under it | 404, 403 | `listPages` |
| GET | `api/v1/spaces/<space>/pages/at/<slug>/<slug>…` | | `Page` at that path in the space, with `ETag` | 404, 403 | `getPage` |
| POST | `api/v1/spaces/<space>/pages` | `NewPage` `{"parent": id or null, "title", "body"}` | 201 `Page`, with `ETag` | 404, 403, 400 | `createPage` |
| PUT | `api/v1/pages/<page>` | `PageEdit` `{"title", "body"}`, with `If-Match` | `Page`, with its new `ETag` | 404, 403, 400, 409 | `savePage` |
| POST | `api/v1/pages/<page>/move` | `PageMove` `{"space", "parent": id or null}` | `Page` | 404, 403, 400 | `movePage` |
| POST | `api/v1/pages/<page>/shift` | `ShiftBy` `{"shift"}` | `Page`, with its new position | 404, 403, 400 | `shiftPage` |
| DELETE | `api/v1/pages/<page>` | | 204 | 404, 403 | `deletePage` |

### Attachments

| Method | Path | Body | Response | Errors | `MonadWiki` |
| ------ | ---- | ---- | -------- | ------ | ----------- |
| POST | `api/v1/pages/<page>/attachments` | multipart form, one file part named `file`: its file name is the attachment's name, its `Content-Type` the attachment's media type | 201 `Attachment` | 404, 403, 400 (a bad name, or a file over 50 MB) | `uploadAttachment` |
| GET, HEAD | `api/v1/attachments/<attachment>/<name>` | | the file's bytes, streamed, with the attachment's media type as `Content-Type`; a `Range` request gets that range (a `<video>` seeks with one) | 404, 403 | `attachmentUrl` gives this address |
| DELETE | `api/v1/attachments/<attachment>` | | 204 | 404, 403 | `deleteAttachment` |

An attachment whose bytes the server keeps has `"source": {"tag":
"SourceBlob", "contents": <blob id>}`, and is fetched at the address above;
one that lives on the web (`"SourceUrl"`) is fetched at its own URL.
`Wiki.Api.Links.attachmentUrl` gives either. A download address ends in the
attachment's name, so that a browser saving it names the file; a name that is
not the attachment's is 404.

### Drafts

| Method | Path | Body | Response | Errors | `MonadWiki` |
| ------ | ---- | ---- | -------- | ------ | ----------- |
| GET | `api/v1/pages/<page>/draft` | | the signed-in user's `Draft` of the page, or `null` | 404, 403 | `getDraft` |
| PUT | `api/v1/pages/<page>/draft` | `DraftEdit` `{"base": time, "title", "body"}`: `base` is the page's `updatedAt` when the work started | `Draft` | 404, 403 | `saveDraft` |
| DELETE | `api/v1/pages/<page>/draft` | | 204 | 404, 403 | `discardDraft` |

### Search

| Method | Path | Body | Response | Errors | `MonadWiki` |
| ------ | ---- | ---- | -------- | ------ | ----------- |
| GET | `api/v1/search?q=<words>&space=<space>&only&limit=<n>` | | `[SearchHit]`, the best first | | `searchPages` |

The parameters are the application's own search address's
(`/search/?q=…&space=…&only`), except that `space` is the space's id rather
than its path, since that is what a `SearchQuery` holds, and `limit` is
added. `q` missing is no words, which finds nothing; `space` missing is every
space the user may view; `only` present leaves out the space's subspaces;
`limit` missing is 50. A search never refuses: a query with no words, a space
that is not there and one the user may not view all give `[]`.
`Wiki.Api.Links.searchUrl` writes the address of a query, and
`searchQueryOf` reads the query back, so both sides fill in the defaults
alike.

### Export and import

| Method | Path | Body | Response | Errors |
| ------ | ---- | ---- | -------- | ------ |
| GET | `api/v1/export` | | the wiki as a zip file (`application/zip`, [the export format](export.md)), with `Content-Disposition: attachment; filename="wiki-<date>.zip"` | 403 |
| POST | `api/v1/import/preview` | multipart form, the archive as a file part named `archive` | `ImportPlan` | 403, 400 (not an archive this program reads) |
| POST | `api/v1/import/apply` | multipart form, the same archive as `archive` and `ImportChoices` as JSON in a text part named `choices` | `ImportSummary` | 403, 400 |

Both need the global `administer` permission.

An import merges an archive into the wiki rather than replacing it, in two
steps. The preview reads the archive and answers what importing it would do:

```json
{"spaces": [
  {"path": ["docs"], "name": "Docs", "status": "SpaceMerged", "pages": [
    {"path": ["tour"], "title": "Tour", "attachments": 1,
     "conflict": {"title": "Tour", "updatedAt": "…", "sameContent": false}},
    {"path": ["tour", "more"], "title": "More", "attachments": 0, "conflict": null}]},
  {"path": ["docs", "notes"], "name": "Notes", "status": "SpaceNew", "pages": []}]}
```

Spaces come each before its subspaces, pages each before the pages under it,
in the archive's order. They are matched with the server's by path, never by
id: a space at the same path is merged (`SpaceMerged`), and a page at the
same path in it is a conflict, with the server's page's title and time, and
whether the two are the same. The dialog shows the plan with everything
checked, and for each conflict "keep the server's" (the default) or "take
the imported". Apply then sends the archive again (the server keeps nothing
between the steps) with the choices:

```json
{"skipSpaces": [["docs", "notes"]],
 "skipPages": [{"space": ["docs"], "page": ["tour", "more"]}],
 "conflicts": [{"page": {"space": ["docs"], "page": ["tour"]}, "resolution": "TakeImported"}]}
```

A skipped space is not imported, nor its subspaces; a skipped page is not
imported, nor the pages under it; a conflict not listed keeps the server's
page (`KeepServer`). `{"skipSpaces": [], "skipPages": [], "conflicts": []}`
imports everything and keeps every page of the server's. The plan is worked
out again when the import is applied, against the wiki as it is then, so a
conflict that has appeared since the preview keeps the server's page. The
import is one transaction, and answers with what it did:

```json
{"spacesCreated": 1, "spacesMerged": 1, "pagesCreated": 4, "pagesReplaced": 1,
 "pagesKept": 2, "pagesSkipped": 0, "attachments": 3}
```

Neither the archive's users, groups and grants nor its ids are imported: a
space or page made by an import has a new id, a space made by one has no
grants (the administrator needs none), and an attachment's bytes are kept
under their content hash, once, however many pages have them.

What a merge keeps of each side (a merged space keeps the server's settings
unless the server's are empty, attachments follow their pages by content
hash, positions follow the archive's order after the server's; the archive's
users, groups and grants are not imported) is the plan's WP2.8.

### Administration

| Method | Path | Body | Response | Errors |
| ------ | ---- | ---- | -------- | ------ |
| GET | `api/v1/admin/status` | | `ServerStatus` `{"version", "startedAt", "dataDir", "trustNetwork", "spaces", "pages", "attachments", "users", "backups"}` | 403 |

Only for the global `administer` permission: the operator on the admin
listener (decision 11 of the plan), and whoever is the administrator on the
public one (`--trust-network` until Phase 3, then an administrator's
session). Phase 3 adds the administration panel's users and permissions
here.

## The two listeners

The server answers on two addresses, with the same API and the same
application, as two different people:

- the **public listener** (`--listen`, the Tailscale address when deployed
  by `toolchain/deploy-local.sh --server`) serves the wiki at its base path
  (`--base-path`, `/` by default) to an anonymous reader, who sees the
  public spaces and changes nothing; with `--trust-network`, everyone who
  reaches it is the administrator instead (decision 19);
- the **admin listener** (`--admin-listen`, `127.0.0.1:8081` by default,
  loopback only unless `--admin-listen-unsafe`) serves the same application
  at `/admin/`, and its API at `/admin/api/v1/…`, to the administrator,
  without a login. From another machine it is reached through an SSH
  tunnel: `ssh -L 8081:127.0.0.1:8081 <host>`, then
  `http://127.0.0.1:8081/admin/`.

Every page is served with the `<base href>` of the place it is served at,
so the application loaded from `/admin/` asks the API at
`/admin/api/v1/`. A page's prerendered links are written for the public base
path, so the admin listener redirects an address below that path to the
same one below `/admin/`.

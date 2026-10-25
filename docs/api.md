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
- **Who is asking** is the server's to decide, for each request: on the
  public listener, the user whose session the request's cookie names, or
  nobody; on the admin listener, the administrator (see "The two
  listeners" below). No endpoint takes it as an argument, and the client
  never reads the cookie (it is `HttpOnly`).
- **A request to the API that changes something** (any method but GET,
  HEAD and OPTIONS) must carry the header `X-Wiki-Request` (any value; the
  application sends `1`), on both listeners, and is refused with 403
  otherwise. A page of another site can make a browser post a form here,
  with the wiki's cookie, but not send a header of its choosing without the
  server's consent (CORS), which this server never gives. Where the browser
  says where a request came from (`Sec-Fetch-Site`, sent to HTTPS origins
  and to the machine itself) it must say `same-origin` (or `none`).
- **Answers are private**: they depend on who asks, so they go out with
  `Cache-Control: private, no-cache` (unless an endpoint says otherwise)
  and `Vary: Cookie`, and so do the pages the server renders.

## Errors

A refusal is a status and a JSON body naming the reason, one per constructor
of the backend's `WikiError`, with its text where it has one:

| Status | Body | When |
| ------ | ---- | ---- |
| 404 | `{"error": "NotFound"}` | an id or a path names nothing |
| 403 | `{"error": "Forbidden"}` | it names something the user may not see, or may not do this to |
| 400 | `{"error": "Invalid", "message": "…"}` | the request cannot be carried out as it is |
| 409 | `{"error": "Conflict", "message": "…"}` | the wiki has changed since the request was made |
| 401 | `{"error": "Unauthenticated"}` | signing in failed: no account has that login and password, or it cannot sign in |
| 429 | `{"error": "TooManyRequests", "message": "…"}` | signing in was tried too often; `Retry-After` says how many seconds to wait |

The last two are signing in's alone, and have no `WikiError` of their own:
a client that meets them elsewhere takes them for forbidden and invalid.

When more than one applies, the first in the order of `MonadWiki`'s Haddock
is given: not found, forbidden, invalid, conflict. So a user who may not act
learns nothing about whether their request was otherwise well formed. Any
endpoint may answer any of these; the table below names the ones each is
expected to give. A response with a 4xx status and no such body (one the
routing answered before a handler ran, or a proxy) means the error of its
status: 404 and 410 not found, 401 unauthenticated, 403 forbidden, 409 and
412 conflict, 429 too many requests, any other 4xx invalid
(`Wiki.Api.Error.errorForStatus`). A 5xx is a failure
of the server, not a refusal.

## Endpoints

`MonadWiki` names the method of the backend interface each endpoint carries.

### The server and the session

| Method | Path | Body | Response | Errors | `MonadWiki` |
| ------ | ---- | ---- | -------- | ------ | ----------- |
| GET | `api/v1/info` | | `ServerInfo` `{"name", "apiVersion"}` | | |
| GET | `api/v1/session` | | `SessionInfo` `{"user", "groups", "grants", "standing"}`: the user (`null` for nobody signed in), their groups, the grants given to them or their groups, and how they came to be who they are | | `session` |
| POST | `api/v1/session` | `Credentials` `{"login", "password"}` | `SessionInfo` of the user signed in, and `Set-Cookie` with their session | 401, 429, 400 | (`signIn`) |
| DELETE | `api/v1/session` | | `SessionInfo` of nobody, and `Set-Cookie` clearing the session's | 400 | (`signOut`) |

`standing` is `"NotSignedIn"` (nobody: the application offers to sign in),
`"SignedIn"` (a user with a session: it offers to sign out) or
`"Operator"` (the administrator by where the request came from: the admin
listener; neither applies). A login is compared
without regard to the case of its letters or the blanks around it. Signing
in or out where everyone is the operator is refused with 400; signing in
again replaces the browser's session. `signIn` and `signOut` are methods of
`MonadAccount` (`Wiki.App.Account`), which only the backend over HTTP has.

### Sessions and the cookie

Signing in sets one cookie, `wiki_session`, whose value is the session's
random id (32 bytes, base64 for URLs); the server keeps only its SHA-256,
with the user and when it was last used:

```
Set-Cookie: wiki_session=<id>; Path=<base path>; Max-Age=1209600; HttpOnly; SameSite=Strict
```

`Secure` is added only when the server runs with `--secure-cookies`
(behind HTTPS): a browser never sends a secure cookie over plain HTTP,
which is how the wiki is served on a private network (decision 20). A
session ends when its user signs out, is disabled or is given a new
password, and after two weeks without being used; each use moves its end
on (recorded at most hourly, when the cookie is sent again with a fresh
`Max-Age`). A request whose cookie names a session that has ended, or no
session, is nobody's, and its answer clears the cookie (`Max-Age=0`).

Failed sign-ins are counted per login and address (5) and per address (30)
over 15 minutes, in the server's memory; beyond either, signing in answers
429 until the oldest failure is 15 minutes old. Signing in clears that
login's count from that address. Passwords are kept as argon2id hashes
(19 MiB, 2 passes, 1 lane), in the PHC string format, and must have 8 to
1024 characters.

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
| GET | `api/v1/spaces/<space>/grants` | | `SpaceAccess` `{"grants", "users", "groups"}`: the grants on the space and then on each of its ancestors, up (each `SpaceGrant` `{"space", "subject", "permission"}` names the space it is on), every `User` by login and every `Group` by name | 404, 403 | `spaceAccess` |
| PUT | `api/v1/spaces/<space>/grants` | `SpaceGrantChange` `{"subject", "permission", "granted": bool}` | 204 | 404, 403, 400 | `setSpaceGrant` |

A space's grants are read and changed by whoever administers it
(`AdministerSpace` on it or an ancestor, or the global `administer`). A
`subject` is `{"tag": "SubjectUser", "contents": <user id>}` or `{"tag":
"SubjectGroup", "contents": <group id>}`, a `permission` `"View"`, `"Edit"` or
`"AdministerSpace"`. A grant on the space holds in its subspaces too; one on an
ancestor is changed there. Giving a grant twice, or taking one from someone who
does not have it, changes nothing; giving one to a user or group that is not
there is 400, after the permission is checked. Whoever administers a space may
take that from themself, which the space's view does not offer.

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

### History

| Method | Path | Body | Response | Errors | `MonadWiki` |
| ------ | ---- | ---- | -------- | ------ | ----------- |
| GET | `api/v1/pages/<page>/versions` | | `[VersionInfo]` `{"page", "updatedAt", "title", "author"}`, the page's every version, the latest (the page as it is) first | 404, 403 | `listVersions` |
| GET | `api/v1/pages/<page>/versions/<time>` | | `Version` `{"page", "updatedAt", "title", "body", "author"}` | 404, 403 | `getVersion` |
| POST | `api/v1/pages/<page>/versions/<time>/restore` | none, with `If-Match` | `Page`, with its new `ETag` | 404, 403, 400, 409 | `restoreVersion` |

Every save of a page is a version of it, named by the page's `updatedAt` as
that version: in a path, the time in ISO 8601 with every digit of its
fraction, unquoted (`2026-10-24T09:30:12.345678Z`, its colons
percent-encoded by `Wiki.Api.Links`), which is the version's `ETag` without
the quotes. A page has a version for when it was made and one for each save;
a page that came in whole (an import) starts with the page as it was. A
version's `author` is `{"id", "name"}` (the user's display name; the
administrator's is `Administrator`; someone who is no longer a user is named
by their id), or `null` for nobody known (an import).

Reading a history needs what reading the page does, restoring what saving it
does. The page's permission is checked before the version is looked up, so a
reader who may not see the page gets 403 for any time, and only one who may
gets 404 for a time that is no version. A restore saves the version's title
and body as the page's latest version, against the version in `If-Match` as a
save is (409 if the page has been saved since), and so discards the
restorer's draft; the versions in between are kept.

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

| Method | Path | Body | Response | Errors | `MonadAdmin` |
| ------ | ---- | ---- | -------- | ------ | ------------ |
| GET | `api/v1/admin/status` | | `ServerStatus` `{"version", "startedAt", "dataDir", "spaces", "pages", "attachments", "users", "backups"}` | 403 | |
| GET | `api/v1/admin/directory` | | `Directory` `{"users", "administrators", "creators", "disabled", "withPassword", "groups", "membership"}`: every `User` by login (a disabled one too), the ids of the users granted the global `administer` themselves, of those granted the global `create-spaces` themselves, of those whose login is disabled and of those who have a password, every `Group` by name, and the members' ids of each group by its id (a group without members may be left out) | 403 | `directory` |
| PUT | `api/v1/admin/users/<user>/administrator` | `AdministratorFlag` `{"administrator"}` | 204 | 403, 404 | `setAdministrator` |
| PUT | `api/v1/admin/users/<user>/create-spaces` | `CreateSpacesFlag` `{"createSpaces"}` | 204 | 403, 404 | `setCreateSpaces` |
| POST | `api/v1/admin/groups` | `GroupName` `{"name"}` | 201 `Group` `{"id", "name"}` | 403, 400 | `createGroup` |
| PUT | `api/v1/admin/groups/<group>/name` | `GroupName` | `Group` | 403, 404, 400 | `renameGroup` |
| DELETE | `api/v1/admin/groups/<group>` | | 204 | 403, 404 | `deleteGroup` |
| PUT | `api/v1/admin/groups/<group>/members/<user>` | | 204 | 403, 404 | `addMember` |
| DELETE | `api/v1/admin/groups/<group>/members/<user>` | | 204 | 403, 404 | `removeMember` |
| POST | `api/v1/admin/users` | `NewAccount` `{"login", "displayName", "password"}` | 201, `Account` `{"user", "hasPassword", "disabled"}` | 403, 400, 409 (the login is taken, in any case) | `createUser` |
| PUT | `api/v1/admin/users/<user>/password` | `NewPassword` `{"password"}` | `Account`; the user's sessions end | 403, 404, 400 | `setPassword` |
| PUT | `api/v1/admin/users/<user>/disabled` | `AccountDisabled` `{"disabled"}` | `Account`; disabling ends the user's sessions | 403, 404 | `setDisabled` |

Only for the global `administer` permission: the operator on the admin
listener (decision 11 of the plan), and on the public one a user granted it,
by their session. Anyone else is refused with 403 before
anything the address names is looked for, so that the refusal says nothing
about which users and groups exist.

`MonadAdmin` (`Wiki.App.Backend.Admin`) is the administration panel's
backend interface, beside `MonadWiki`. An administrator here is a user
granted the global `administer` themself: marking one adds that grant,
unmarking takes it away (theirs too: the server allows an administrator to
demote themself, which the panel does not offer, since the admin listener can
always undo it), and a grant to a group is left alone. Letting a user create
spaces, or no longer, is the same with the global `create-spaces`. A group's name is
trimmed, not blank, and no other group's in any case (400 otherwise).
Deleting a group deletes its membership and every grant to it, global and on
spaces. Adding a member who is in the group already, and removing one who is
not, succeed and change nothing.

The last three are the accounts' (`Wiki.Api.Account`), whose forms are in the
same panel. A login is
at most 64 characters, with no blank in it and not starting with `~`, and
is no other user's in any case (409 otherwise); a blank display name is the
login. Setting a password, and disabling a login, end the user's sessions;
a disabled user stays in the directory. A password is never part of an
answer. The same operations, and making a user an administrator, are on the
console: `wiki-server users …` (see the README).

## The two listeners

The server answers on two addresses, with the same API and the same
application, as two different people:

- the **public listener** (`--listen`, the Tailscale address when deployed
  by `toolchain/deploy-local.sh --server`) serves the wiki at its base path
  (`--base-path`, `/` by default) to whoever the request's session names,
  or to an anonymous reader, who sees the public spaces and changes
  nothing;
- the **admin listener** (`--admin-listen`, `127.0.0.1:8081` by default,
  loopback only unless `--admin-listen-unsafe`) serves the same application
  at `/admin/`, and its API at `/admin/api/v1/…`, to the administrator,
  without a login, and looks at no cookie. From another machine it is reached through an SSH
  tunnel: `ssh -L 8081:127.0.0.1:8081 <host>`, then
  `http://127.0.0.1:8081/admin/`.

Every page is served with the `<base href>` of the place it is served at,
so the application loaded from `/admin/` asks the API at
`/admin/api/v1/`. A page's prerendered links are written for the public base
path, so the admin listener redirects an address below that path to the
same one below `/admin/`.

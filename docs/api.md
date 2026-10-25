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
| GET | `api/v1/session` | | `SessionInfo` `{"user", "groups", "grants", "standing", "providers"}`: the user (`null` for nobody signed in), their groups, the grants given to them or their groups (with whom the wiki is open to, `grants.access`), how they came to be who they are, and the providers one may sign in with, `{"name", "label"}` each (none where the server names none) | | `session` |
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
login's count from that address. A wrong current password given to change
one's own (`PUT account/password`, below) counts as a failed sign-in of
one's login, and a right one clears the count as signing in does. Passwords are kept as argon2id hashes
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

### Comments

| Method | Path | Body | Response | Errors | `MonadComments` |
| ------ | ---- | ---- | -------- | ------ | --------------- |
| GET | `api/v1/pages/<page>/threads` | | `[Thread]`, in the order they were opened | 404, 403 | `listThreads` |
| POST | `api/v1/pages/<page>/threads` | `NewThread` `{"anchor": Anchor or null, "body"}` | 201 `Thread` | 404, 403, 400 | `openThread` |
| POST | `api/v1/pages/<page>/threads/<thread>/comments` | `CommentText` `{"body"}` | 201 `Comment`, last in the thread | 404, 403, 400 | `reply` |
| PUT | `api/v1/pages/<page>/threads/<thread>/comments/<comment>` | `CommentText` `{"body"}` | `Comment`, with its `editedAt` | 404, 403, 400 | `editComment` |
| DELETE | `api/v1/pages/<page>/threads/<thread>/comments/<comment>` | | 204 | 404, 403, 400 | `deleteComment` |
| DELETE | `api/v1/pages/<page>/threads/<thread>` | | 204 | 404, 403 | `deleteThread` |
| PUT | `api/v1/pages/<page>/threads/<thread>/resolved` | `ThreadResolution` `{"resolved": bool}` | `Thread` | 404, 403, 400 | `setResolved` |

A page's comments (WP4.5 of the plan) come in threads. A `Thread` is `{"id",
"page", "anchor", "resolved", "createdAt", "comments"}`: its `anchor` is the
quote of the page's rendered text it is about, `{"exact", "prefix",
"suffix"}` (the quote and up to 32 characters of the text before and after
it: a W3C text quote selector), or `null` for a thread about the whole page;
its `comments` are `[Comment]` `{"id", "thread", "author", "body",
"createdAt", "editedAt"}`, the first the one that opened it, the rest
replies, one level deep. A comment's `body` is Markdown, rendered as a page
is, and its `author` is `{"id", "name"}`, named as a version's author is.
Where a quote is on the page, or that the page no longer has it, is the
client's to find (`Wiki.Core.Anchor.locate`): the server keeps the quote as
it was given, its context cut to 32 characters.

Reading a page's threads takes what reading the page does; commenting,
replying and resolving or reopening a thread take that and being signed in
(the operator on the admin listener comments as the administrator); a
comment is edited by its author alone, and deleted by its author or by
whoever administers the page's space; a whole thread is deleted by whoever
administers the space, or by the one who opened it while every comment in it
is theirs. Only an inline thread is resolved (400 for a thread about the
page). The first comment of a thread is the thread: deleting it deletes the
thread, which is refused (400) while it has replies. A thread or a comment
is addressed under its page; one that is not on the page named is 404,
after the page's own 404 and 403. A comment is not blank and at most 20 000
characters long, a quote not blank and at most 2000 (400).

### The live channel

`api/v1/events` is a WebSocket, not a servant route: one per browser tab, on
which the tab says which pages it shows and the server tells it what happens
to their comments as it happens (decision 23 of the plan,
`Wiki.Api.Events`). The upgrade is a request like any other: who is asking is
found from its session cookie, a closed wiki answers someone who has not
signed in 401 before upgrading, an upgrade whose `Origin` is not the
server's own address (its `Host`, or the `X-Forwarded-Host` a proxy in
front sets) is 403, and a request to the address that is no upgrade is 426.
A connection stays who it was opened as: a tab that signs in or out opens
another.

Every message is a JSON text frame. The tab sends `{"subscribe": "<page>"}`
and `{"unsubscribe": "<page>"}`; the server answers a subscription with
`{"subscribed": "<page>", "threads": [Thread]}`, or `{"refused": "<page>"}`
for a page that is not there or that the connection's user may not read,
and then sends `{"page":
"<page>", "event": PageEvent}` for each change to the page's comments, once it
is committed, to every connection subscribed to it (the tab that made the
change included), checking again that the user may read the page. A
`PageEvent` is an object with a `type`, below.

The answer's `threads` are the page's threads as `GET
api/v1/pages/<page>/threads` would give the connection's user at that
moment, and the server subscribes the connection in the same hold of its
storage as it reads them: every change committed after that read is sent
after the answer, and none committed before it is sent as an event. So a
tab that replaces what it shows of the page's comments with the answer, and
folds in the events that follow, misses nothing between its first read of
the page (with the page, or from the HTML the server rendered it into) and
its subscription, and asks for nothing more to catch up.



| `type` | Fields | What happened |
| ------ | ------ | ------------- |
| `thread-opened` | `thread`: `Thread` | a thread was opened, with its first comment |
| `comment-added` | `comment`: `Comment` | a reply |
| `comment-edited` | `comment`: `Comment` | a comment was edited |
| `comment-deleted` | `thread`, `comment`: ids | a reply was deleted |
| `thread-resolved` | `thread`: id, `resolved`: bool | a thread was resolved or reopened |
| `thread-deleted` | `thread`: id | a thread was deleted, or its first comment with it |

The type is open: a client ignores an event of a type it does not know, so
that later ones ("someone is editing this page", "this page changed") ride
the same channel. Nothing is replayed: a tab that loses its connection
connects again and subscribes again, and the answers are what it missed.
The server pings every 20 seconds, keeps subscriptions in memory, closes a
connection that does not keep up with its messages (256 waiting), and
closes every connection when it stops.

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

### Whom the wiki lets in

| Method | Path | Body | Response | Errors | |
| ------ | ---- | ---- | -------- | ------ | - |
| POST | `api/v1/accounts` | `NewAccount` `{"login", "displayName", "password"}` | `SessionInfo` of the account made, and `Set-Cookie` with its session | 403 (a closed wiki), 400, 409, 429 | (`register`) |
| GET | `api/v1/invitations/<secret>` | | `InvitationInfo` `{"email", "expiresAt"}` | 404 (used, revoked, expired or none) | (`invitationFor`) |
| POST | `api/v1/invitations/<secret>` | `NewAccount` | `SessionInfo` of the account made, and `Set-Cookie`; the invitation is used up | 404, 400, 409, 429 | (`acceptInvitation`) |
| GET | `api/v1/admin/settings` | | `WikiSettings` `{"access", "newAccountsCreateSpaces"}`, `access` `"Open"` or `"Closed"` | 403 | `wikiSettings` |
| PUT | `api/v1/admin/settings` | `WikiSettings` | `WikiSettings` as they now are | 403, 400 | `setWikiSettings` |
| GET | `api/v1/admin/invitations` | | `Invitations` `{"mailing", "invitations"}`: whether the server mails them, and every `Invitation` `{"id", "email", "createdAt", "expiresAt", "expired"}` not used, the latest first | 403 | `invitations` |
| POST | `api/v1/admin/invitations` | `NewInvitation` `{"email"}` | 201 `Invited` `{"invitation", "token", "mailError"}` | 403, 400 | `invite` |
| DELETE | `api/v1/admin/invitations/<invitation>` | | 204 | 403, 404 | `revokeInvitation` |

A wiki is **open** (the default, and what a wiki made before the setting
is) or **closed** (WP3.5 of the plan). The access travels in every
session's grants (`grants.access`), so the application knows before anyone
signs in which it is.

- Open: anyone reads the public spaces, and may make themself an account
  (`POST accounts`), which holds no grant unless `newAccountsCreateSpaces`
  gives it the global `create-spaces`, and is signed in at once.
  `newAccountsCreateSpaces` (in the panel, "Let every new account create
  spaces") applies to every account made by the person it is for: by
  themself, by invitation, or by signing in with a provider for the first
  time, in an open wiki or a closed one; an administrator may also grant
  `create-spaces` to each user (`PUT admin/users/<user>/create-spaces`).
- Closed: someone who has not signed in is answered 401 `Unauthenticated`
  for every endpoint but `info`, `session` (all three methods), `accounts`
  (which answers 403) and `invitations/…`, and every page of the
  application is the way to sign in, with a 401, but an invitation's
  (`/invite/<secret>/`, 404 when the invitation cannot be used). Public
  spaces are public to those signed in only. The admin listener is not
  affected: its operator is the administrator.

Accounts in a closed wiki come by invitation: an administrator invites an
e-mail address, and the invitation's link (`<public url>invite/<secret>/`)
makes one account, once, within seven days; it is gone when used, revoked
or replaced (inviting an address again gives it a new link), and an
expired one stays listed until then. The secret is 32 random bytes, kept
as its SHA-256 only, so it is given back once: in the mail, when the
server has a mail server and a public address (the server's settings,
below, and `mailing` is true), and
otherwise in the answer that made it (`token`), for the panel to show the
link to pass on; when the mail could not be sent, `mailError` says why and
`token` is given too. Making an account either way is limited to five
attempts an address in fifteen minutes, every attempt counted, and needs
the application's header like any write. No secret is ever written in
the log: the path segment after `invite` or `invitations` is logged as
`…`.

### Signing in with a provider

| Method | Path | Body | Response | Errors | |
| ------ | ---- | ---- | -------- | ------ | - |
| GET | `auth/<provider>/start?next=<path>` (`&link=1`, `&invite=<secret>`) | | 302 to the provider, and `Set-Cookie: wiki_oidc=…` | 404 (no such provider), 403 (`link` without a session), 502 (the provider cannot be reached) | |
| GET | `auth/<provider>/callback?code=…&state=…` | | 200, a page that goes on to `next`, and `Set-Cookie` with the session (but when connecting) | 400 (a state not given, or not this browser's), 403, 404, 429, 502 | |
| POST | `auth/<provider>/callback` | a form `code`, `state`, `user` (Apple's) | 200, a page that goes on to the GET above | | |
| GET | `api/v1/account/identities` | | `SignInMethods` `{"password", "identities"}`: whether the user has a password, and each `LinkedIdentity` `{"provider", "email", "name", "linkedAt"}` | 401 (nobody signed in), 400 (the operator) | (`identities`) |
| DELETE | `api/v1/account/identities/<provider>` | | `SignInMethods` as they are then | 401, 404 (none there), 409 (the last way to sign in) | (`unlinkIdentity`) |
| DELETE | `api/v1/admin/users/<user>/identities/<provider>` | | 204; the user's sessions end | 403, 404 | `unlinkUserIdentity` |

People may sign in with an account at a provider the server's settings
name (WP3.6 of the plan; set in the administration since WP4.4, see "The
server's settings" below), beside a password or instead of one. A provider
added there signs people in from the next request on, one removed no longer
does, and one changed is asked how to sign in again. The `auth/…` addresses are below the place the
public listener serves the wiki at, not the API's: the browser goes to
them, it does not fetch them, they answer with pages, and they are answered
in a closed wiki too, since they are the way in. The admin listener has none.

`start` remembers the round trip (in memory, for ten minutes: its state, its
nonce, its PKCE verifier, what it is for and `next`, a path of the wiki's own,
or the wiki's root) and sends the browser to the provider's authorization
endpoint, giving it a cookie of the round trip's own (`wiki_oidc`, `HttpOnly`,
`SameSite=Lax`, `Path=<base path>auth/`). The provider sends it back to the
callback, the redirect URI `<public url>auth/<provider>/callback` registered
with it; Apple posts a form there, which is answered with a page that goes on
to the GET, from the wiki's own site, so that the browser sends the cookie.
The callback takes a state only with that cookie and once, exchanges the code
at the token endpoint with the client's secret and the verifier, and checks
the ID token's `iss`, `aud` (and `azp`), `exp` and `nonce` (GitHub, which has
no ID token, is asked its `user` and `user/emails` instead); an e-mail address
is kept only if the provider says it is verified. Then:

- an identity that is a user's signs that user in, unless they are disabled
  (403); connecting it to another user is refused (403);
- an unknown one is connected to the user who asked (`link=1`), or, with an
  invitation (`invite=…`), makes the invitation's account and uses the
  invitation up; otherwise it makes an account in an open wiki and is
  refused in a closed one (403);
- an account so made has no password, a login made from the provider's
  login, the e-mail's local part or the name (lower case, a number after it
  if taken), and the display name the provider gives.

The callback then answers with a page that sets the session's cookie and goes
on to `next` itself, rather than a redirect, since the browser sends no
`SameSite=Strict` cookie on a redirect that ends another site's navigation.
Accounts made, and failed exchanges, count against the limit on making
accounts (five an address in fifteen minutes; 429). Codes, tokens, states
and secrets are never written in the log (the log has no query strings).

### One's own password

| Method | Path | Body | Response | Errors | |
| ------ | ---- | ---- | -------- | ------ | - |
| PUT | `api/v1/account/password` | `PasswordChange` `{"current", "new"}` | `SignInMethods` as they are then; the user's other sessions end | 401 (nobody signed in, or `current` missing or wrong), 429, 400 (the operator, or a `new` that cannot be a password) | (`changePassword`) |

A user signed in changes their password, or sets one if they have none
(one who signs in only with a provider's account, WP3.7 of the plan). Where
they have one, `current` must be it: a session alone is not enough, so that
whoever finds a browser left signed in cannot lock its owner out. Where they
have none, `current` is `null` or left out. `new` must have 8 to 1024
characters, and is checked before anything else. Every other session of the
user ends, as when an administrator sets a password; the one the request
came with stays, and with it the cookie. Wrong current passwords count
against the sign-in limit of the user's login from that address (above),
and once it is reached the answer is 429 with `Retry-After`, the right
password included.

### Administration

| Method | Path | Body | Response | Errors | `MonadAdmin` |
| ------ | ---- | ---- | -------- | ------ | ------------ |
| GET | `api/v1/admin/status` | | `ServerStatus` `{"version", "startedAt", "dataDir", "spaces", "pages", "attachments", "users", "backups"}` | 403 | |
| GET | `api/v1/admin/directory` | | `Directory` `{"users", "administrators", "creators", "disabled", "withPassword", "identities", "groups", "membership"}`: every `User` by login (a disabled one too), the ids of the users granted the global `administer` themselves, of those granted the global `create-spaces` themselves, of those whose login is disabled and of those who have a password, the providers each user signs in with by their id (a user with none may be left out), every `Group` by name, and the members' ids of each group by its id (a group without members may be left out) | 403 | `directory` |
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

### The server's settings

| Method | Path | Body | Response | Errors | `MonadAdmin` |
| ------ | ---- | ---- | -------- | ------ | ------------ |
| GET | `api/v1/admin/server` | | `ServerSettings` `{"publicUrl", "mail", "providers"}`, each secret as `"set"` or `"not-set"` | 403 | `serverSettings` |
| PUT | `api/v1/admin/server` | `ServerSettingsChange`, each secret `null` (kept), `""` (cleared) or a new one | `ServerSettings` as they now are | 403, 400 | `setServerSettings` |
| POST | `api/v1/admin/server/providers/<name>/check` | `null` (the provider as set) or a `ProviderSettings` with its secret as in a change (the provider as typed) | `ProviderCheck` `{"redirectUri", "clientSecret", "discovered", "problem"}` | 403, 404 (nothing given and no provider of that name) | `checkProvider` |
| POST | `api/v1/admin/server/mail/test` | `MailTest` `{"to"}` | `MailTestResult` `{"failure"}`, `null` when sent | 403, 400 (no mail server or public address, or not an address) | `sendTestMail` |

The wiki's public address, the mail server invitations go through and the
providers people sign in with (WP4.4 of the plan, `Wiki.Api.ServerSettings`)
are set here and nowhere else: the server has no option for them (the
owner's decision of 2026-10-25). They are kept in the database (migration
`0005-server-settings.sql`), read by the server per request from memory, and
take effect at the next request; nothing is set until an administrator sets
it, and a wiki made before them goes on with no mail and passwords only.

```json
{
  "publicUrl": "https://wiki.example.org/",
  "mail": {"host": "mail.example.org", "port": 587, "security": "starttls",
           "user": "wiki", "password": "set", "from": "Wiki <wiki@example.org>"},
  "providers": [{"name": "google", "kind": "google", "clientId": "1234-abc.apps.googleusercontent.com",
                 "issuer": null, "secret": "set"}]
}
```

`security` is `tls` (implicit, port 465), `starttls` or `plain`; `kind` is
`google`, `apple`, `github` or `oidc` (any OpenID Connect provider, at its
`issuer`; for another kind `issuer` is an address in place of its own, a
GitHub Enterprise server's, say). A provider's `name` is lower-case letters,
digits and dashes, starting with a letter, at most 32 characters, and is in
its redirect URI, `<publicUrl>auth/<name>/callback`.

**Secrets are written and never read back.** A `GET` (and the answer to a
`PUT`) says of the mail account's `password` and each provider's `secret`
only `"set"` or `"not-set"`. A `PUT` replaces the settings whole, and for
each secret sends `null` or leaves the field out to keep it (the mail
server's, or the provider's of the same name), `""` to clear it, or the new
one. A provider left out is removed with its secret, as is the mail server
when `mail` is `null`. A change is checked whole, and refused with 400 and
the first reason: the address `http` or `https` with a host (a slash is
added at its end); mail and providers need the address; the mail server
needs its host, a port from 1 to 65535 and its sender, and a password when it
has a user; each provider a valid name no other has, its client id and its
secret, an issuer for `oidc`, and any address over `https` (or `http` on
this machine, for tests). The secrets are kept in clear in the database,
which holds password and session hashes already and is as sensitive as its
file; no secret is ever written in the log.

`check` asks a provider for its discovery document (GitHub's endpoints are
fixed) afresh, as set or as typed in the panel before it is saved (a typed
provider without a secret takes the one set for its name), and answers with
its endpoints, or the `problem` in words (it cannot be reached, its document
names another issuer, or the settings are not ones it could have); the
redirect URI once there is a public address. The test mail goes through the
mail server as set, to the address given, and says why it was not sent if it
was not. The demo's backend keeps the settings for the tab's life, answers
`check` with that it cannot ask, and sends no mail.

`wiki-server oidc check --data DIR [NAME]` does what `check` does, from the
machine, for the providers set in that data directory, and prints each
redirect URI.

## The two listeners

The server answers on two addresses, with the same API and the same
application, as two different people:

- the **public listener** (`--listen`, the Tailscale address when deployed
  by `toolchain/deploy-local.sh --server`) serves the wiki at its base path
  (`--base-path`, `/` by default) to whoever the request's session names,
  or to an anonymous reader, who in an open wiki sees the public spaces and
  changes nothing, and in a closed one sees only the way to sign in;
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

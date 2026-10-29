# The HTTP API

The server speaks one HTTP API, under `/api/v1`, and the application's backend
over HTTP is its client. The API is a servant type, `Wiki.Api` in `wiki-api`:
the server serves that type, and the client is derived from the same type
with servant-client-core (`Wiki.App.Backend.Http.Client` in `wiki-app`), so
the two cannot disagree about a path, a parameter, a header or a body. It covers everything the application's backend
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
- **Bodies are JSON** (`Content-Type: application/json`; the application
  sends `application/json;charset=utf-8`), except an attachment's file and an
  archive, which are sent as a multipart form (`multipart/form-data`) and
  come back as bytes. A
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
| 404 | `{"error": "NotFound"}` | an id or a path names nothing, or something the user may not see |
| 403 | `{"error": "Forbidden"}` | it names something the user may see, but may not do this to |
| 400 | `{"error": "Invalid", "message": "…"}` | the request cannot be carried out as it is |
| 409 | `{"error": "Conflict", "message": "…"}` | the wiki has changed since the request was made |
| 401 | `{"error": "Unauthenticated"}` | signing in failed: no account has that login and password, or it cannot sign in |
| 429 | `{"error": "TooManyRequests", "message": "…"}` | signing in was tried too often; `Retry-After` says how many seconds to wait |
| 401 | `{"error": "SecondFactorRequired"}` | the login and password are right, and the account has a second factor: the code is to come (below) |

The last three are signing in's alone, and have no `WikiError` of their own:
a client that meets them elsewhere takes them for forbidden and invalid.

When more than one applies, the first in the order of `MonadWiki`'s Haddock
is given: not found, forbidden, invalid, conflict. So a user who may not act
learns nothing about whether their request was otherwise well formed.

A space the user may not view answers exactly as a space that does not
exist: 404, and so does everything in it (its pages, their attachments,
comments, versions and drafts, its watches, its subspaces, its export and
its feed). A search scoped to it finds nothing, as one scoped to a space
that does not exist does. So no refusal tells anyone that a space or a page
exists. A space the user may view answers 403 to what they may not do in
it: a save without the permission to edit, or a change of its grants without
the permission to administer it. The administration is the exception: it
checks the global `administer` before it looks up anything a request names,
so whoever does not hold it gets 403 whatever they name (below). Any
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
| GET | `api/v1/info` | | `ServerInfo` `{"name", "apiVersion", "capabilities"}`: `capabilities` is `Capabilities` `{"database", "search"}`, the database the server keeps the wiki in (`"postgres"` or `"sqlite"`) and how its search finds pages (`"FullText"` or `"FoldedText"`, see [Search](#search)) | | |
| GET | `api/v1/session` | | `SessionInfo` `{"user", "groups", "grants", "standing", "providers", "exports", "boxes"}`: the user (`null` for nobody signed in), their groups, the grants given to them or their groups (with whom the wiki is open to, `grants.access`), how they came to be who they are, the providers one may sign in with, `{"name", "label"}` each (none where the server names none), the formats pages and spaces export as (see [Documents](#documents)), and the kinds of box the administration defined, as in the server's settings below, which every page is rendered with | | `session` |
| POST | `api/v1/session` | `Credentials` `{"login", "password"}` | `SessionInfo` of the user signed in, and `Set-Cookie` with their session | 401, 429, 400 | (`signIn`) |
| DELETE | `api/v1/session` | | `SessionInfo` of nobody, and `Set-Cookie` clearing the session's | 400 | (`signOut`) |
| POST | `api/v1/session/second-factor` | `OneTimeCode` `{"code"}`, with the `wiki_pending` cookie | as `POST session` | 401 (a wrong code, counted as a failed sign-in), 429, 400 (no sign-in waiting in this browser, or it expired) | (`confirmSecondFactor`) |

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
| GET | `api/v1/spaces/page-counts` | | `{"<space id>": n, …}`, how many pages each space the user may view has (not the ancestors listed for their names) | | `pageCounts` |
| GET | `api/v1/spaces/at/<slug>/<slug>…` | | `Space` at that path from the top level | 404 | `getSpace` |
| POST | `api/v1/spaces` | `NewSpace` `{"parent": id or null, "name"}` | 201 `Space`, with its home page made | 404, 403, 400 | `createSpace` |
| PUT | `api/v1/spaces/<space>/name` | `SpaceName` `{"name"}` | `Space` | 404, 403, 400 | `renameSpace` |
| PUT | `api/v1/spaces/<space>/public` | `SpacePublic` `{"public": bool}` | `Space` | 404, 403 | `setSpacePublic` |
| PUT | `api/v1/spaces/<space>/math-macros` | `SpaceMathMacros` `{"mathMacros"}` | `Space` | 404, 403 | `setSpaceMathMacros` |
| PUT | `api/v1/spaces/<space>/profile` | `SpaceProfile` `{"description", "icon": icon or null, "homePage": page id or null}` | `Space` | 404, 403, 400 | `setSpaceProfile` |
| POST | `api/v1/spaces/<space>/icon` | multipart form, one file part named `file`: its `Content-Type` the image's media type, its file name not looked at | `Space`, its icon the image | 404, 403, 400 (not a PNG, JPEG, GIF, WebP or AVIF image, empty, or over 1 MB) | `uploadSpaceIcon` |
| GET, HEAD | `api/v1/spaces/<space>/icon/<blob>` | | the image's bytes, with its media type | 404 | `spaceIconUrl` gives this address |
| PUT | `api/v1/spaces/<space>/order` | `SpaceOrder` `{"children": "ChildSpaces" or "ChildPages", "order": "ByName", "NewestFirst", "OldestFirst" or "ByHand"}` | `Space` | 404, 403 | `setSpaceOrder` |
| POST | `api/v1/spaces/<space>/move` | `SpaceMove` `{"parent": id or null}` | `Space` | 404, 403, 400 | `moveSpace` |
| POST | `api/v1/spaces/<space>/shift` | `ShiftBy` `{"shift": "ShiftUp", "ShiftDown", "ShiftToTop" or "ShiftToBottom"}` | `Space`, with its new position | 404, 403, 400 | `shiftSpace` |
| DELETE | `api/v1/spaces/<space>` | | 204 | 404, 403 | `deleteSpace` |
| GET | `api/v1/spaces/<space>/grants` | | `SpaceAccess` `{"grants", "users", "groups"}`: the grants on the space and then on each of its ancestors, up (each `SpaceGrant` `{"space", "subject", "permission"}` names the space it is on), every `User` by login and every `Group` by name | 404, 403 | `spaceAccess` |
| PUT | `api/v1/spaces/<space>/grants` | `SpaceGrantChange` `{"subject", "permission", "granted": bool}` | 204 | 404, 403, 400 | `setSpaceGrant` |

A `Space` is `{"id", "name", "slug", "parent", "public", "mathMacros",
"createdAt", "position", "subspaceOrder", "pageOrder", "homePage", "icon",
"description"}`. Its `homePage` is the id of the page it opens at, one of its
own, or `null`; a space made through the API comes with one, a page titled
"Home" whose first version is its creator's, and a page that is deleted, or
moved to another space, leaves its space without one. Its `icon` is `null`
for the default (the first letter of its name on a colour picked from its
id), `{"emoji": "📘"}`, `{"colour": "teal"}` (one of
`Wiki.Core.Space.iconColours`: blue, teal, green, olive, orange, red, pink,
purple, indigo, slate) or `{"image": <blob>, "mediaType": "image/png"}`, an
uploaded image, fetched at the address above (`Wiki.Api.Links.spaceIconUrl`),
which names the blob so that a new image is at a new address. Its
`description` is plain text, empty for none, at most 500 characters.

A space's profile and icon are set by whoever administers it, checked as
`Wiki.Core.Space.checkProfile` checks them, after the permission: a home page
that is not one of the space's pages, a colour not in the palette, an emoji
that is blank, longer than 16 characters or has a space in it, and an image
the space does not have already are 400. An image is uploaded, never named:
a profile names one only to keep the image the space has, and one that names
another kind of icon lets the image go. The image is kept under its hash, as
an attachment's bytes are, and served as they are (`nosniff`, sandboxed),
to whoever may view the space.

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
| GET | `api/v1/spaces/<space>/pages` | | `[PageSummary]` `{"id", "space", "parent", "title", "slug", "createdAt", "updatedAt", "position", "template"}`, the space's whole tree, each page before the pages under it: a `Page` without its `body` and `attachments`, which `getPage` reads | 404 | `listPages` |
| GET | `api/v1/spaces/<space>/post-details` | | `{"<page id>": PostDetails}` `{"author", "comments", "excerpt"}` for every page of the space: the author of its first version (or `null`), its number of comments, and, for a blog's post, its first paragraph as text (`""` for any other page) | 404 | `postDetails` |
| GET | `api/v1/spaces/<space>/pages/at/<slug>/<slug>…` | | `Page` at that path in the space, with `ETag` | 404 | `getPage` |
| POST | `api/v1/spaces/<space>/pages` | `NewPage` `{"parent": id or null, "title", "body"}` | 201 `Page`, with `ETag` | 404, 403, 400 | `createPage` |
| PUT | `api/v1/pages/<page>` | `PageEdit` `{"title", "body"}`, with `If-Match` | `Page`, with its new `ETag` | 404, 403, 400, 409 | `savePage` |
| POST | `api/v1/pages/<page>/move` | `PageMove` `{"space", "parent": id or null}` | `Page` | 404, 403, 400 | `movePage` |
| POST | `api/v1/pages/<page>/shift` | `ShiftBy` `{"shift"}` | `Page`, with its new position | 404, 403, 400 | `shiftPage` |
| PUT | `api/v1/pages/<page>/template` | `PageTemplate` `{"template": bool}` | `Page`; not a save, its `updatedAt` stays | 404, 403, 400 (a space's home page) | `setPageTemplate` |
| DELETE | `api/v1/pages/<page>` | | 204 | 404, 403 | `deletePage` |

### Attachments

| Method | Path | Body | Response | Errors | `MonadWiki` |
| ------ | ---- | ---- | -------- | ------ | ----------- |
| POST | `api/v1/pages/<page>/attachments` | multipart form, one file part named `file`: its file name is the attachment's name, its `Content-Type` the attachment's media type | 201 `Attachment` | 404, 403, 400 (a bad name, or a file over 50 MB) | `uploadAttachment` |
| GET, HEAD | `api/v1/attachments/<attachment>/<name>` | | the file's bytes, streamed, with the attachment's media type as `Content-Type`; a `Range` request gets that range (a `<video>` seeks with one); `ETag` the hash of the bytes, and `Cache-Control: private, max-age=300`, since the bytes never change under this address | 404 | `attachmentUrl` gives this address |
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
| GET | `api/v1/pages/<page>/versions?before=<time>&limit=<n>` | | `[VersionInfo]` `{"page", "updatedAt", "title", "author", "number"}`, a page of the page's history, the latest (the page as it is) first: at most `limit` versions (50 if missing, 500 at most) of those saved before the version `before` (of all, if missing), written as in a version's address; `number` is the version's place in the history, 1 for the first | 404 | `listVersions` |
| GET | `api/v1/pages/<page>/versions/<time>` | | `Version` `{"page", "updatedAt", "title", "body", "author"}` | 404 | `getVersion` |
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
reader who may not see the page gets 404 for any time, as for a page that
does not exist, and only one who may see it learns from a 404 that a time is
no version. A restore saves the version's title
and body as the page's latest version, against the version in `If-Match` as a
save is (409 if the page has been saved since), and so discards the
restorer's draft; the versions in between are kept.

### Comments

| Method | Path | Body | Response | Errors | `MonadComments` |
| ------ | ---- | ---- | -------- | ------ | --------------- |
| GET | `api/v1/pages/<page>/threads` | | `[Thread]`, in the order they were opened | 404 | `listThreads` |
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
after the page's own 404 (a page that is not there, or that the user may
not read). A comment is not blank and at most 20 000
characters long, a quote not blank and at most 2000 (400).

### The live channel

`api/v1/events` is a WebSocket, not a servant route: one per browser tab, on
which the tab says which pages it shows and which it edits, and the server
tells it what happens to them as it happens (decision 23 of the plan,
`Wiki.Api.Events`). The upgrade is a request like any other: who is asking is
found from its session cookie, a closed wiki answers someone who has not
signed in 401 before upgrading, an upgrade whose `Origin` is not the
server's own address (its `Host`, or the `X-Forwarded-Host` a proxy in
front sets) is 403, and a request to the address that is no upgrade is 426.
A connection stays who it was opened as: a tab that signs in or out opens
another.

Every message is a JSON text frame. The tab sends `{"subscribe": "<page>"}`
and `{"unsubscribe": "<page>"}`, and `{"editing": "<page>"}` when it opens
the page's editor and `{"stopped": "<page>"}` when it closes it; the server
answers a subscription with `{"subscribed": "<page>", "threads": [Thread],
"editing": [Author]}`, or `{"refused": "<page>"}` for a page that is not
there or that the connection's user may not read, and then sends `{"page":
"<page>", "event": PageEvent}` for each change to the page's comments and
each save of it, once it is committed, and each change of who edits it, to
every connection subscribed to it (the tab that made the change included),
checking again that the user may read the page. A `PageEvent` is an object
with a `type`, below.

Who edits a page is kept per connection, in memory: from `{"editing"}` (taken
only from someone who may edit the page; anyone else's is ignored) until
`{"stopped"}` or the connection's end, which a closed tab or a lost network
comes to. A connection is told everyone editing the page on other
connections, each person once (their id and display name, as a comment's
author), so a tab never hears of itself but does hear of its own user in
another tab; the answer to a subscription's `editing` says who it is then. A
tab that connects again says again which pages it edits.

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
| `editing` | `editors`: [`Author`] | who else edits the page changed: these do now |
| `page-changed` | `updatedAt`: time | the page was saved (or a version restored): its new version's time |

Besides what happens to the pages it subscribed to, a connection opened by a
user is sent `{"notification": Notification}` for every notification made
for that user (below), whatever page it is about, once the write that made
it is committed. Nobody else's connection is, and nothing is sent to a
connection of someone not signed in.

The type is open: a client ignores an event of a type it does not know, so
that later ones ride the same channel. Nothing is replayed: a tab that loses its connection
connects again and subscribes again, and the answers are what it missed.
The server pings every 20 seconds, keeps subscriptions in memory, closes a
connection that does not keep up with its messages (256 waiting), and
closes every connection when it stops.

### Notifications

| Method | Path | Body | Response | Errors | `MonadNotifications` |
| ------ | ---- | ---- | -------- | ------ | -------------------- |
| GET | `api/v1/notifications` | | `Notifications` `{"unread", "items": [Notification]}` | 403 | `notifications` |
| POST | `api/v1/notifications/read` | `ReadMark` `{"ids": [id], "everything": bool}` | `Notifications` | 403 | `markRead` |
| GET | `api/v1/notifications/settings` | | `NotificationSettings` `{"mail", "watchOwn", "verifiedEmail", "mailing"}` | 403 | `notificationSettings` |
| PUT | `api/v1/notifications/settings` | `NotificationSettingsChange` `{"mail", "watchOwn"}` | `NotificationSettings` | 403 | `setNotificationSettings` |
| GET | `api/v1/notifications/people?login[]=<login>&…` | | `{"<login>": Author}`, of those that are users' | | `mentionable` |
| GET | `api/v1/notifications/people/search?q=<letters>` | | `[User]` `{"id", "login", "displayName"}` | 400 | `mentionCandidates` |
| GET | `api/v1/notifications/watches/pages/<page>` | | `Watch` `{"watching", "reason"}` | 404, 403 | `watching` |
| PUT | `api/v1/notifications/watches/pages/<page>` | `Watching` `{"watching": bool}` | `Watch` | 404, 403 | `setWatching` |
| GET | `api/v1/notifications/watches/spaces/<space>` | | `Watch` | 404, 403 | `watching` |
| PUT | `api/v1/notifications/watches/spaces/<space>` | `Watching` | `Watch` | 404, 403 | `setWatching` |
| POST | `api/v1/unsubscribe/<secret>` | | 204 | 404 | `unsubscribe` |

Mentions, watching and notifications (WP4.13 of the plan,
`Wiki.Core.Notification`). A `Notification` is `{"id", "kind", "page",
"thread", "actor", "title", "excerpt", "createdAt", "read", "location"}`:
`kind` is `mentioned` (a page or a comment mentions the user), `replied` (a
comment in a thread they opened or replied in), `commented` (a comment on a
page they watch) or `changed` (a save of a page they watch); `thread` is the
comment's thread or `null`; `actor` is who did it, `{"id", "name"}`, named as
they were then; `title` the page's title then; `excerpt` the start of the
comment, or empty; `location` where the page is now, `{"space": [slug],
"page": [slug]}`. Each write tells each user once, the first kind that
applies in that order, never the one who did it, and never someone who may
not read the page; a notification of a page the user may no longer read is
left out of the list. The list is the latest 50, the newest first; `unread`
counts all of those kept (90 days, at most 500 a user).

`people/search` is what the editor completes a mention with: the users who
may sign in whose login or display name starts with `q`, ignoring case, at
most ten, ordered by display name and then login, compared by code points.
Only users whose login a mention can name are answered
(`Wiki.Core.Markdown.Ast.mentionsWhole`: a page that says `@login`
mentions that login and nothing else), so that the login written mentions the user chosen.
To a visitor who is not signed in, and for a `q` of fewer than two
characters, it answers `[]`; without `q` it is a 400. A signed-in user is
otherwise never given a list of the wiki's users (only an administrator,
or a space's administrator choosing whom to grant to, sees them all); the
shortest `q` keeps the search from listing everyone a letter at a time.
The server lowers `q` with the database's own `lower`, then answers from
the indexes of the lowered login and display name, in one statement unless
logins a mention cannot name fill a page of the answer. PostgreSQL lowers
every letter (as its character type says); SQLite lowers only the letters
of ASCII, so there another letter is matched only in the case it was typed
in.

A page is watched as its `Watch` says: `{"watching": bool, "reason"}`, the
reason `{"tag": "Chosen"}` (the user chose so for it), `{"tag": "FromSpace",
"contents": "<space>"}` (the nearest of its spaces with a choice),
`{"tag": "OwnPage"}` (they made it, the author of its first version, and
watch their own) or `{"tag": "Unchosen"}`. A space is watched by its own
choice, else its nearest ancestor's. `PUT` makes a choice for that page or
space, which wins over the rest.

`mail` is `off`, `now` or `daily`: at once, or in one digest a day from
07:00 UTC, grouped by page; until the user chooses, `now` with a verified
address and `off` without one, and nothing is mailed to an address that is
not verified, or by a server without mail settings (`mailing`). Before a
notification is mailed the server asks again whether its user may read the
page. Each mail carries a link to `unsubscribe/<secret>/`, the application's
page whose button posts to `api/v1/unsubscribe/<secret>`: the secret names
the user and is signed by the server, works without signing in (in a closed
wiki too) and only turns the mail off. Everything else here is the signed-in
user's own: someone not signed in, and the operator on the admin listener,
are refused (403); `people` names nobody to someone not signed in.

### Search

| Method | Path | Body | Response | Errors | `MonadWiki` |
| ------ | ---- | ---- | -------- | ------ | ----------- |
| GET | `api/v1/search?q=<words>&space=<space>&only&limit=<n>&templates` | | `[SearchHit]`, the best first | | `searchPages` |

The parameters are the application's own search address's
(`/search/?q=…&space=…&only`), except that `space` is the space's id rather
than its path, since that is what a `SearchQuery` holds, and `limit` is
added. `q` missing is no words, which finds nothing; `space` missing is every
space the user may view; `only` present leaves out the space's subspaces;
`limit` missing is 50; `templates` present searches the spaces' templates
too (a page's `template`), which are left out otherwise. A search never refuses: a query with no words, a space
that is not there and one the user may not view all give `[]`.
`Wiki.Api.Links.searchUrl` writes the address of a query, and
`searchQueryOf` reads the query back, so both sides fill in the defaults
alike.

How a search finds pages depends on the server's database, and
`api/v1/info`'s `capabilities.search` says which; the answer's shape is the
same. `"FoldedText"` (SQLite, and the demo): every word of the query anywhere
in a page's title or text, folded (no case, no diacritics), a part of a word
too, a hit in the title first. `"FullText"` (PostgreSQL): PostgreSQL's
full-text search over the same folded text, whole words only, the query read
as a web search engine reads it (`"a phrase"`, `or`, `-word` to leave out),
the pages ranked by how well they match (`ts_rank`, a hit in the title above
one in the text alone). Either way each hit has its title and a snippet with
the query's words marked.

### Documents

| Method | Path | Body | Response | Errors |
| ------ | ---- | ---- | -------- | ------ |
| GET, HEAD | `api/v1/pages/<page>/export/<format>` | | the page as a document of that format, with its media type and `Content-Disposition: attachment; filename="<title>.<extension>"` | 404, 400, 429 |
| GET, HEAD | `api/v1/spaces/<space>/export/<format>` | | the space's pages as one document, in the space's order, after a title page and a table of contents | 404, 400, 429 |

The formats (`Wiki.Api.Export`) are `docx` (Word, its formulas as Word's
equations), `html` (one standalone page, its images inside it and its
formulas as MathML), `epub`, `pdf` (typeset by `xelatex`), and for a page
written as a deck only, `pptx`, `beamer-tex` (the LaTeX source of a Beamer
presentation) and `beamer-pdf`. The server makes them with pandoc, linked
into it; only the PDFs need a program, `xelatex`, which the server looks for
on its `PATH` at each request: `exports` in the session lists what it
offers, and a PDF asked for without it is 400. So is a presentation of a
page that is not a deck, or of a space, and a document pandoc or TeX could
not make, with their reason. Whoever may read the page (view the space)
may export it. Each person makes one export at a time (a user by their id,
someone not signed in by their address): another asked for meanwhile is
429. One that takes longer than 60 seconds is stopped and refused with 400.

What a document holds is the page as the wiki shows it, as far as the format
can: the page's images (its attachments' that the server keeps) inside it;
links to other pages and to attachments that are not images under the
wiki's public address (as text when it has none); the space's math macros,
and those the page's formulas define, expanded into each formula; raw HTML
through the page's allowlist. A Mermaid diagram, which needs a browser, is
a note with its source; a TikZ picture is drawn in the PDFs and the Beamer
source, and a note elsewhere. Nothing is fetched from the web: an image
there is a link to it.

### Export and import

| Method | Path | Body | Response | Errors |
| ------ | ---- | ---- | -------- | ------ |
| GET | `api/v1/export` | | the wiki as a zip file (`application/zip`, [the export format](export.md)), with `Content-Disposition: attachment; filename="wiki-<date>.zip"` | 403 |
| POST | `api/v1/import/preview` | multipart form, the archive as a file part named `archive` | `ImportPlan` | 403, 400 (not an archive this program reads) |
| POST | `api/v1/import/apply` | multipart form, the same archive as `archive` and `ImportChoices` as JSON in a text part named `choices` | `ImportSummary` | 403, 400 |

Both need the global `administer` permission.

The server writes the export's zip file into `<data>/tmp/` one file at a
time, copying each attachment from its file, then sends it and deletes it:
an export costs disk the size of the archive, and memory for the wiki's
records but not its attachments. A form's file (an attachment, an icon, an
archive to import) is written to `<data>/tmp/` as it arrives too, and deleted when the request ends. An
import reads the archive's files into memory, about the archive's size in
all; `--max-import-size` (512 MiB by default) bounds it.

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

A page's comments come with its content: a page the import makes, and a
page whose content it replaces, get the archive's comment threads that the
page does not have yet, after its own; a page the server keeps keeps its
own. A comment's author is the server's user with the author's login, or
else is kept by their name, shown as "(not a user here)". The audit entry
of the import counts the comments it brought. [The export
format](export.md) says more.

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
| GET | `api/v1/admin/settings` | | `WikiSettings` `{"access", "newAccountsCreateSpaces", "adminCreatesPasswordAccounts"}`, `access` `"Open"` or `"Closed"` | 403 | `wikiSettings` |
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

`adminCreatesPasswordAccounts` (in the panel, "The administration may
create accounts with a password"; true by default, and for a wiki made
before the setting) decides whether the administration makes accounts
with a password (`POST admin/users`, below). When it is false, that
endpoint answers 403 `Forbidden` to everyone, the operator on the admin
listener included, before it looks at the login, the password or the
address. Accounts with a password are then made on the server's console,
with `wiki-server users add`, and the panel shows a note saying so in
place of its form for a new user (WP5.18 of the plan). The `Forbidden`
body carries no text, as every `Forbidden`; the setting, which `GET
admin/settings` and `GET admin/directory` both return, is the reason. The
console, invitations, accounts people make themselves in an open wiki,
sign-in providers, a password an administrator sets for an existing user
and a link to choose one are not affected. A change of the setting is
recorded in the audit log with the wiki's other settings
(`settings.wiki`, whose detail has `administration creates accounts with
a password`, `yes` or `no`).

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
- an account so made has no password (and none to set while it signs in
  with a provider the server has: see "One's own password"), a login made from the provider's
  login, the e-mail's local part or the name (lower case, a number after it
  if taken), and the display name the provider gives.

The callback then answers with a page that sets the session's cookie and goes
on to `next` itself, rather than a redirect, since the browser sends no
`SameSite=Strict` cookie on a redirect that ends another site's navigation.
Accounts made, and failed exchanges, count against the limit on making
accounts (five an address in fifteen minutes; 429). Codes, tokens, states
and secrets are never written in the log (the log has no query strings).

A user with a second factor (below) who signs in with a provider is not
signed in at the callback: the callback answers a page of its own with a
form for the code, which it posts to `auth/<provider>/second-factor` with the
`wiki_pending` cookie; the right code sets the session's cookie and goes on
to `next`, a wrong one answers the form again (401), five end the sign-in.

### One's own password

| Method | Path | Body | Response | Errors | |
| ------ | ---- | ---- | -------- | ------ | - |
| PUT | `api/v1/account/password` | `PasswordChange` `{"current", "new"}` | `SignInMethods` as they are then; the user's other sessions end | 401 (nobody signed in, or `current` missing or wrong), 429, 400 (the operator, a `new` that cannot be a password, or a user who has no password to set) | (`changePassword`) |

A user signed in changes their password, or sets one if they have none
and no provider to sign in with (WP3.7 of the plan). A user who has no
password and an account at a provider the server's settings have has no
password to set (WP5.6): they sign in there, and this endpoint, the
administrator's `PUT admin/users/<user>/password` and `password-link`
answer 400 with the reason, as a reset's link does (below). Only the
providers the server has now count: a user whose last provider was
disconnected, or removed from the server's settings, has no way in, and
may be given a password, or set one if they are still signed in. `Directory`'s
`providerOnly` lists who has none to set, by this rule. Where
they have one, `current` must be it: a session alone is not enough, so that
whoever finds a browser left signed in cannot lock its owner out. Where they
have none, `current` is `null` or left out. `new` must have 8 to 1024
characters, and is checked before anything else. Every other session of the
user ends, as when an administrator sets a password; the one the request
came with stays, and with it the cookie. Wrong current passwords count
against the sign-in limit of the user's login from that address (above),
and once it is reached the answer is 429 with `Retry-After`, the right
password included.

### Keeping an account safe

| Method | Path | Body | Response | Errors | |
| ------ | ---- | ---- | -------- | ------ | - |
| GET | `api/v1/account/sessions` | | `[SessionSummary]` `{"id", "createdAt", "lastSeenAt", "address", "current"}`, the most recently used first | 401, 400 (the operator) | (`ownSessions`) |
| DELETE | `api/v1/account/sessions/<session>` | | the sessions then | 401, 404 (not one of theirs), 400 (the one asking: sign out instead) | (`endOwnSession`) |
| DELETE | `api/v1/account/sessions` | | the sessions then: the one asking alone | 401 | (`endOtherSessions`) |
| GET | `api/v1/account/second-factor` | | `SecondFactorState` `{"enabled", "recoveryCodesLeft", "asksPassword"}` | 401 | (`secondFactorState`) |
| POST | `api/v1/account/second-factor/totp` | `CurrentPassword` `{"password"}` (where the user has one) | `TotpEnrolment` `{"secret", "uri", "qr"}`: the secret in base32, the `otpauth://` address, and that address as a QR code's modules, row by row (`"1"` dark, `"0"` light, no quiet zone) | 401 (nobody signed in, or a wrong password, counted), 429, 409 (one is on already) | (`enrolTotp`) |
| PUT | `api/v1/account/second-factor/totp` | `OneTimeCode` `{"code"}` | `RecoveryCodes` `{"codes"}`, shown this once | 401 (a wrong code, counted), 429, 404 (none begun), 409 | (`confirmTotp`) |
| POST | `api/v1/account/second-factor/remove` | `OneTimeCode` (a code or a recovery code) | `SecondFactorState` | 401 (a wrong code, counted), 429, 404 (none on) | (`removeOwnSecondFactor`) |
| GET | `api/v1/account/email` | | `EmailState` `{"email", "verified", "mailing", "mailError", "asksPassword"}` | 401 | (`ownEmail`) |
| PUT | `api/v1/account/email` | `EmailChange` `{"email", "password"}` (`""` for none; the password where the user has one, unless the address is the one they have) | `EmailState`; a link to verify a new address is mailed to it, `mailError` says why if it could not be | 401 (nobody signed in, or a wrong password, counted), 429, 400 (not an address, or the server sends no mail) | (`setOwnEmail`) |
| POST | `api/v1/email-verification/<secret>` | | 204: the address the link was mailed to is the user's verified address | 404 (used, expired, or no longer the user's address) | (`verifyEmail`) |
| POST | `api/v1/password-reset` | `ResetRequest` `{"login"}` (a login or an e-mail address) | 204, whatever it names | 429 (ten an address in fifteen minutes), 400 (the server sends no mail: for every login alike) | (`requestPasswordReset`) |
| POST | `api/v1/password-reset/<secret>` | `NewPasswordByMail` `{"password"}` | 204: the password is set, every session of the user ends, nobody is signed in | 404 (used or expired), 400 (a password that cannot be one, or a user who has no password to set) | (`resetPassword`) |

WP4.11 of the plan. A session alone does not give an account away: giving
another address (or none) and beginning a second factor take the current
password where the user has one, as a new password does (WP3.7); `asksPassword`
in the states says whether. A wrong one counts as a failed sign-in. Sending
the link again for the address one has asks nothing.

A session is named by an id of its own (16 random bytes in
hex), never by the secret its cookie carries; `address` is the network
address it was last used from, and "last seen" is written at most once a
minute.

The second factor is TOTP as RFC 6238 has it (HMAC-SHA-1, 30-second steps,
six digits), a code taken from one step before to one step after now and only
if later than the last one taken, so each is taken once. Signing in with the
password of a user who has one answers 401 `SecondFactorRequired` and sets a
cookie of a sign-in waiting for its code, for five minutes:

```
Set-Cookie: wiki_pending=<id>; Path=<base path>; Max-Age=300; HttpOnly; SameSite=Strict
```

and `POST session/second-factor` ends it with a code or an unused recovery
code (ten, `abcd-efgh-ijkl-mnop`, 80 random bits each, kept as SHA-256, each
taken once, typed in any case with or without the dashes). Wrong codes count
as failed sign-ins of the login from that address, and five end the sign-in.
The secret is kept in the database in clear, as the server needs it.

An e-mail address is trusted once the link mailed to it (a day, single use)
is followed; only a verified address is sent a reset, and never one of a
user who has no password to set (one who signs in with a provider the
server has, WP5.6), whose link, if mailed before, sets none. A reset's link works
once, for thirty minutes; an account is mailed at most three an hour; the
answer to asking for one is the same whatever it names, and the looking up
and mailing happen after it.

An administrator has the same link mailed to a user with `POST
admin/users/<user>/password-link` (WP5.6): mailed at once, to the user's
verified address, answered 204 once it is sent, and recorded in the audit
log (`user.password-link`). Neither limit of the request above applies to
it (the address's ten in fifteen minutes, the account's three an hour),
but it counts towards the account's three, and a user mailed any reset's
link less than a minute ago is mailed none (429, with `Retry-After`), so
that a button clicked twice mails once. A link that could not be mailed is
forgotten, and the answer (400) says why. The administration offers it
instead of typing a password wherever the server sends mail and the user
has a verified address. Both links' secrets are kept as SHA-256 and left
out of the log. The links are the application's pages
`reset-password/<secret>/` and `verify-email/<secret>/`, which a closed wiki
shows to anyone, as an invitation's.

### The assistant's keys across devices

| Method | Path | Body | Response | Errors | `MonadVault` |
| ------ | ---- | ---- | -------- | ------ | ------------ |
| GET | `api/v1/assistant/vault` | | `StoredVault` `{"tag", "vault"}`, the tag also as `ETag`; with `If-None-Match` naming the server's tag, 304 and no body | 401, 400 (the operator), 404 (no vault: syncing is off) | `fetchVault` |
| PUT | `api/v1/assistant/vault` | `Vault` `{"format", "salt", "nonce", "ciphertext", "wrapped"}`, over the version `If-Match` names, or without `If-Match` a first one | `StoredVault` as it now is | 401, 409 (another version, or a first one where there is a vault), 400 (a wrapped key for a passkey not the user's, another format, a part empty or longer than 256 KiB) | `storeVault` |
| DELETE | `api/v1/assistant/vault` | | 204: the vault and every passkey of the user gone | 401 | `deleteVault` |
| GET | `api/v1/assistant/passkeys` | | `[PasskeyInfo]` `{"id", "name", "createdAt", "lastUsedAt", "unlocks"}`, the oldest first | 401 | `listPasskeys` |
| POST | `api/v1/assistant/passkeys/registration` | | `RegistrationOptions` `{"challenge", "rpId", "rpName", "userId", "userName", "displayName", "exclude"}` | 401 | `beginRegistration` |
| PUT | `api/v1/assistant/passkeys/registration` | `RegistrationResponse` `{"id", "clientDataJSON", "attestationObject"}` | `PasskeyInfo` | 401, 400 (no challenge waiting, or an answer that does not check), 409 (registered already), 400 (twenty passkeys already) | `finishRegistration` |
| POST | `api/v1/assistant/passkeys/assertion` | | `AssertionOptions` `{"challenge", "rpId", "allow"}` | 401 | `beginAssertion` |
| PUT | `api/v1/assistant/passkeys/assertion` | `AssertionResponse` `{"id", "clientDataJSON", "authenticatorData", "signature"}` | `PasskeyInfo`, used now | 401, 404 (not one of the user's passkeys), 400 (no challenge waiting, or an answer that does not check), 409 (its counter went back) | `finishAssertion` |
| DELETE | `api/v1/assistant/passkeys/<id>` | | `[PasskeyInfo]` left; its wrapped key goes, and the vault's tag changes | 401, 404 | `dropPasskey` |

WP5.21 of the plan (`Wiki.Api.Vault`, `Wiki.Core.Assistant.Vault`). The
writing assistant's settings, API keys among them, are sealed in the browser
with a random vault key (AES-GCM); the vault key is wrapped once per
passkey, with a key derived (HKDF-SHA256, the vault's salt) from that
passkey's WebAuthn PRF output. The server stores what the browser sends and
can open none of it; the PRF output and the vault key never leave the
browser. All bytes are base64url without padding:

```json
{
  "tag": "\"3\"",
  "vault": {
    "format": 1,
    "salt": "<32 bytes>",
    "nonce": "<12 bytes>",
    "ciphertext": "<the settings, sealed>",
    "wrapped": {"<credential id>": {"nonce": "<12 bytes>", "key": "<the vault key, wrapped>"}}
  }
}
```

A passkey is registered and used in two requests each: the first gives a
challenge, kept for the session that asked (by its secret's hash), for five
minutes, used once; the second sends the browser's answer, which the server
checks (`Wiki.Server.WebAuthn`): the client data's type, challenge and
origin (the public address's, or the request's host over the scheme
`X-Forwarded-Proto` names, else HTTP), the
relying party's hash (the host without its port), the user present and
verified, and for a use the signature (ES256 or RS256) over the
authenticator data and the client data's SHA-256, and a counter that goes
up (or stays 0, as a synced passkey's does). The attestation statement is
not checked: the wiki asks for none. Neither signs anyone in.

### Administration

| Method | Path | Body | Response | Errors | `MonadAdmin` |
| ------ | ---- | ---- | -------- | ------ | ------------ |
| GET | `api/v1/admin/status` | | `ServerStatus` `{"version", "startedAt", "dataDir", "spaces", "pages", "attachments", "users", "backups", "schemaVersion", "lastBackup", "connections", "errors"}`: the schema's version (its last migration), when the newest backup kept in the data directory was made (`null` for none), how many live channels are open, and the last errors the server logged since it started, the newest first, twenty at most, each `LoggedError` `{"at", "route", "message"}` (`route` a route pattern such as `/api/v1/pages/:page`, or the part of the server, such as `backup-scheduler`; never an address with its ids or secrets) | 403 | `serverStatus` |
| GET | `api/v1/admin/activity?actor=<user>&before=<entry>` | | `Activity` `{"available", "entries", "more", "actors"}`: the audit log, the newest first, at most 50 entries logged before the entry `before` names (the oldest entry of the page before; none after an id the log does not have), or else from `offset=<n>` on (0 if missing; slower the further it skips), of one actor's (`actor` a user's id, or `~administrator` for the operator) or everyone's; each `AuditEntry` `{"id", "at", "actor": {"id", "login"}, "action", "subject": {"kind", "id", "name"}, "detail", "address"}`; `more` whether older entries follow; `actors` everyone the log has an entry of, by login | 403 | `activity` |
| GET | `api/v1/admin/directory` | | `Directory` `{"users", "administrators", "creators", "disabled", "withPassword", "identities", "providerOnly", "secondFactor", "emails", "mailing", "adminCreatesPasswordAccounts", "groups", "membership"}`: every `User` by login (a disabled one too), the ids of the users granted the global `administer` themselves, of those granted the global `create-spaces` themselves, of those whose login is disabled and of those who have a password, the providers each user signs in with by their id (a user with none may be left out), the ids of those who have no password to set (none, and an account at a provider the server has: see "One's own password"), the ids of those with a second factor, each user's e-mail address `{"email", "verified"}` by their id (a user with none left out), whether the server sends mail, the wiki's setting `adminCreatesPasswordAccounts` (whether the administration may create accounts with a password, above), every `Group` by name, and the members' ids of each group by its id (a group without members may be left out) | 403 | `directory` |
| GET | `api/v1/admin/users?offset=<n>&limit=<n>&q=<words>&administrators&disabled` | | `UserPage` `{"users", "total", "offset", "groups", "mailing", "adminCreatesPasswordAccounts"}`: one page of the users, in order of login ignoring case, from `offset` (0 if missing), at most `limit` of them (25 if missing, 100 at most), those whose login or display name holds every word of `q` ignoring case (everyone if missing), only those granted the global `administer` themselves with the flag `administrators`, only the disabled with the flag `disabled`; each `UserSummary` `{"user", "administrator", "createsSpaces", "disabled", "hasPassword", "identities", "providerOnly", "secondFactor", "email", "groups"}` (the fields mean what the directory's do, for one user; `groups` the ids of their groups), `total` how many users match on every page, `offset` the query's, `groups` every `Group` by name, `mailing` and `adminCreatesPasswordAccounts` as in the directory. The administration's users section reads this, a page at a time; the directory stays for what needs every user (the groups' section) | 403, 400 (an `offset` below 0, or a `limit` outside 1 to 100) | `userPage` |
| PUT | `api/v1/admin/users/<user>/administrator` | `AdministratorFlag` `{"administrator"}` | 204 | 403, 404 | `setAdministrator` |
| PUT | `api/v1/admin/users/<user>/create-spaces` | `CreateSpacesFlag` `{"createSpaces"}` | 204 | 403, 404 | `setCreateSpaces` |
| POST | `api/v1/admin/groups` | `GroupName` `{"name"}` | 201 `Group` `{"id", "name"}` | 403, 400 | `createGroup` |
| PUT | `api/v1/admin/groups/<group>/name` | `GroupName` | `Group` | 403, 404, 400 | `renameGroup` |
| DELETE | `api/v1/admin/groups/<group>` | | 204 | 403, 404 | `deleteGroup` |
| PUT | `api/v1/admin/groups/<group>/members/<user>` | | 204 | 403, 404 | `addMember` |
| DELETE | `api/v1/admin/groups/<group>/members/<user>` | | 204 | 403, 404 | `removeMember` |
| POST | `api/v1/admin/users` | `NewAccount` `{"login", "displayName", "password", "email"}` (`email` optional: a link to verify it is mailed there) | 201, `Account` `{"user", "hasPassword", "disabled"}` | 403 (also to an administrator while the wiki's `adminCreatesPasswordAccounts` is false: such accounts are then made on the console), 400, 409 (the login is taken, in any case) | `createUser` |
| DELETE | `api/v1/admin/users/<user>/second-factor` | | 204: the user signs in with their password alone | 403, 404 (none) | `removeSecondFactor` |
| DELETE | `api/v1/admin/users/<user>` | | 204: the account is removed with its sessions, memberships, grants, second factor, passkeys, vault, drafts, watches and notifications; the page versions and comments the user wrote, and others' notifications of what they did, stay under the id `~former:<login>` (shown as the login, "not a user here"), and the login may be taken again; the activity log records `user.remove` | 403, 404, 409 (the login is not disabled), 400 (one's own account) | `removeUser` |
| PUT | `api/v1/admin/users/<user>/password` | `NewPassword` `{"password"}` | `Account`; the user's sessions end | 403, 404, 400 (a password that cannot be one, or a user who has no password to set) | `setPassword` |
| POST | `api/v1/admin/users/<user>/password-link` | | 204: the link "Forgot your password?" mails is mailed to the user's verified address | 403, 404, 400 with the reason (the server sends no mail, the user has no password to set, their login is disabled, they have no verified address, or the mail could not be sent), 429 (a link was mailed to them less than a minute ago) | `sendPasswordLink` |
| PUT | `api/v1/admin/users/<user>/disabled` | `AccountDisabled` `{"disabled"}` | `Account`; disabling ends the user's sessions | 403, 404 | `setDisabled` |

Every write of the administration's is recorded in the audit log in the
same transaction as the write (WP4.10 of the plan): grants on spaces and of
the wiki, a space made public or private, a space's profile (its
description, icon, home page and whether it is a blog), groups and their members,
accounts (made, a password set or a link to choose one mailed, disabled or enabled, a second factor or a
provider's account taken away), the wiki's, the server's and the backups'
settings, invitations made, revoked and accepted, an account made by its
owner, deletions of spaces and pages, imports; and what the console does
(`wiki-server users …`, recorded as `administrator` from `console`). An
entry's `action` is one of `space.grant`, `space.revoke`, `space.public`,
`space.profile`, `space.delete`, `page.delete`, `user.create`, `user.register`,
`user.administrator`, `user.create-spaces`, `user.password`,
`user.disable`, `user.enable`, `user.remove`, `user.second-factor-remove`,
`user.identity-remove`, `group.create`, `group.rename`, `group.delete`,
`group.member-add`, `group.member-remove`, `settings.wiki`,
`settings.server`, `settings.backups`, `invitation.create`,
`invitation.revoke`, `invitation.accept`, `wiki.import`; its `detail` is an
object of texts saying what changed, in which a secret (a password, a client
secret, the rclone configuration) is only ever `changed` or `cleared`;
`address` is where the request came from. Reads are not recorded.

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
| GET | `api/v1/admin/server` | | `ServerSettings` `{"publicUrl", "mail", "providers", "assistantHosts", "boxes"}`, each secret as `"set"` or `"not-set"` | 403 | `serverSettings` |
| PUT | `api/v1/admin/server` | `ServerSettingsChange`, each secret `null` (kept), `""` (cleared) or a new one | `ServerSettings` as they now are | 403, 400 | `setServerSettings` |
| POST | `api/v1/admin/server/providers/<name>/check` | `null` (the provider as set) or a `ProviderSettings` with its secret as in a change (the provider as typed) | `ProviderCheck` `{"redirectUri", "clientSecret", "discovered", "problem"}` | 403, 404 (nothing given and no provider of that name) | `checkProvider` |
| POST | `api/v1/admin/server/mail/test` | `MailTest` `{"to"}` | `MailTestResult` `{"failure"}`, `null` when sent | 403, 400 (no mail server or public address, or not an address) | `sendTestMail` |
| GET | `api/v1/admin/server/backups` | | `Backups` `{"available", "settings", "last", "running", "next", "kept"}`: `settings` is `BackupSettings` `{"enabled", "schedule", "keep", "destination"}`, `schedule` `{"daily": "HH:MM"}` (UTC) or `{"everyHours": n}`, `keep` `{"daily", "weekly"}`, `destination` `null`, `{"directory": path}` or `{"rclone": remote, "config"}` with `config` `"set"` or `"not-set"`; `last` a `BackupRecord` `{"startedAt", "finishedAt", "trigger", "file", "size", "failure", "offSite"}` or `null` | 403 | `backups` |
| PUT | `api/v1/admin/server/backups` | `BackupSettingsChange`, the rclone `config` `null` or left out (kept), `""` (cleared) or a new one | `Backups` as they now are | 403, 400 | `setBackupSettings` |
| POST | `api/v1/admin/server/backups/run` | | `Backups` once the backup is made, or after 20 s with `running` true | 403, 400 (backups are off) | `backUpNow` |

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
                 "issuer": null, "secret": "set"}],
  "assistantHosts": ["http://localhost:11434"],
  "boxes": [{"name": "exercise", "label": "Exercise", "colour": "teal", "icon": "pencil"}]
}
```

`boxes` (WP5.29) are the kinds of box, `> [!KIND]`, the administration
defined (`Wiki.Core.Markdown.Box`): each with its `name` (lower-case letters
and dashes, starting with a letter, at most 32 characters, neither one of
GitHub's five kinds nor `title`), the `label` its boxes are titled with (at
most 60 characters; an empty one is made from the name), a `colour` of the
theme (`blue`, `green`, `purple`, `amber`, `red`, `teal`, `orange`, `pink`,
`grey`) and an `icon` (`none`, `info`, `lightbulb`, `pencil`, `question`,
`check`, `star`, `book`, `flag`). Two kinds with one name, or a name that
cannot be one, are refused (400). They are stored as JSON in the setting
`boxes`, and every session carries them. Settings without the field read
as having none.

`assistantHosts` (WP5.21) are the addresses the writing assistant may reach
from the browser besides Anthropic's and OpenAI's APIs, as origins: every
page's Content Security Policy allows them in `connect-src`, with those of
`--assistant-hosts`. A base URL is taken down to its origin; anything else
than an `https:` or `http:` origin is refused (400). Settings without the
field read as having none.

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

## Health and metrics

Two addresses at the root of a listener, outside the place it serves the
wiki at, and answered before a closed wiki's rule:

- `GET /healthz`, on both listeners, to anyone: `Health` `{"status",
  "schemaVersion", "lastBackupAgeSeconds"}`, 200 with `"ok"`, or 503 with
  `"failing"` when the database cannot be read; `lastBackupAgeSeconds` is
  how long ago the newest backup in the data directory was made, `null` when
  there is none. Nothing of the wiki's content or people.
- `GET /metrics`, on the admin listener only (the public one answers 404):
  Prometheus's text format, version 0.0.4 (`text/plain; version=0.0.4`).
  `wiki_http_requests_total{listener, route, method, status}` (a counter;
  `status` is the class, `2xx`; `method` one of HTTP's own, or `OTHER`), `wiki_http_request_duration_seconds{listener,
  route}` (a histogram, buckets from 5 ms to 10 s; the live channel is
  counted but not timed), and gauges read at each scrape: `wiki_build_info
  {version}`, `wiki_start_time_seconds`, `wiki_schema_version`,
  `wiki_websockets_open`, `wiki_spaces`, `wiki_pages`, `wiki_attachments`,
  `wiki_users`, `wiki_database_bytes` (on SQLite its files, with the
write-ahead log; on PostgreSQL what `pg_database_size` says),
  `wiki_blobs`, `wiki_blob_bytes` (the blobs the attachments and the
  spaces' icons name, counted once each, and their sizes, from the database:
  a scrape reads no directory), `wiki_backups_kept`,
  `wiki_backup_age_seconds` (absent when there is no backup), and the counter
  `wiki_errors_total`. A `route` is the pattern the request matched, read
  from the API's own router (`/api/v1/spaces/:space/name`), or
  `/api/v1/events`, `/auth/:provider/<step>`, `/static` (the build's files),
  `/page` (a page the server renders), `/healthz`, `/metrics`, and
  `/api/unmatched`, `/auth/unmatched`, `/unmatched` for what matches
  nothing; never an address, so ids make no series and no secret of an
  address is a label.

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

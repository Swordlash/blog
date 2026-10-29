# Changelog

## Unreleased

The wiki's guide, the demo's Tour, Markdown guide, Diagrams, Mathematics and
Presentations, moves to `Wiki.App.Guide` (WP5.29), which the demo and the
server share; the server's guide has a tour of its own. The Markdown guide
has a section "Notes and boxes", and the demo defines the kind of box
`exercise`. `Session` gains `boxes`, which pages are rendered with. The
administration's Server section has "Boxes", to define kinds of box, and
its Overview offers "Install the guide" where the wiki has none;
`MonadAdmin` gains `installGuide`.

The editor completes mentions (WP5.28). An `@` followed by two letters or
more, where a mention counts (not in code, a link, HTML or math; brackets
that make no link are text), opens a
list of the users whose login or display name starts with the letters, from
`@codemirror/autocomplete`, a new npm dependency of the bundle; Enter or Tab
writes `@login` and a space. Only users whose login a mention can name are
offered. `MonadNotifications` gains `mentionCandidates`, which every
backend implements: the demo over its users, the HTTP backend through the
new `notifications/people/search` endpoint. A backend of your own needs it
too. The editor's syntax tree knows the wiki's TeX math (`$…$`, `$$…$$`,
`\(…\)`, `\[…\]`) as a node of its own. On a Mac, Ctrl+B, Ctrl+E and Ctrl+K
in the text are bold, code and link only, no longer also CodeMirror's Emacs
moves.

The application needs a browser released within the last year: Chrome and
Edge 140 or later, Firefox 133 or later, Safari 18.2 or later (WP5.27). The
jsbits now use what the platform offers in place of code of their own:
`Uint8Array.prototype.toBase64` and `Uint8Array.fromBase64` for the bytes of
uploads, of the demo's attachments and of the passkeys and sealed keys
(those set the floor), and `indexedDB.databases()` alone to find the demo's
data, without the fallback for Firefox before 126.

The administration is a page per section (WP5.25): `Route.Admin` takes an
`AdminSection` (`Overview`, `Users UserListing`, `Groups`, `Permissions`,
`Server`, `Backups`, `Activity`), each at `/admin/<section>/`, and
`/admin/` opens the first. On these routes the sidebar is the
administration's navigation. `Wiki.App.View.Admin` is gone: the groups are
`Wiki.App.View.Groups`, the users `Wiki.App.View.Users` (a table read with
the new `MonadAdmin.userPage`, paged, searched and filtered from the
address, the page size kept in local storage) and every operation on one
user is in `Wiki.App.View.UserDialog`, a modal `<dialog>`
(`Wiki.App.Browser.showDialog` and `closeDialog`); `passwordControl` moved
there and takes whether the server mails and a `UserSummary`. The server's
section no longer mounts the status and the backups, which are sections of
their own, and the wiki's export and import moved under the backups. The
HTTP backend's cache gains `userPages`, used once from a prerendered page.

`MonadAdmin` gains `removeUser` (WP5.25), and the dialog's account part
offers "Remove the account…" for a disabled login that is not one's own,
confirmed by typing the login; the dialog then closes with the new output
`Removed`. The demo removes the account as the server does, and keeps each
removed account's login (`MemState.removed`, saved with the accounts'
flags) to name the author of the versions it saved.

The HTTP backend's client is derived from the API's type with
servant-client-core (WP5.23). `Wiki.App.Backend.Http.Request` is gone: its
`Request`, `Body`, `Response`, `multipart` and `multipartForm` are replaced
by servant's request and response and by servant-multipart-client, and
every method of `HttpWiki` calls an endpoint function made from
`ApiWith Mem`, so a request the API does not declare no longer compiles.
`HttpWiki` has a `RunClient` instance: every request goes through it, and it
keeps what the hand-written calls did (giving up inside `atOnce`, the
request marker, asking who is asking after a 401 or 403). A `Transport` now
takes an `HttpRequest` (servant's request, its body collected, its path
relative to the page's base; `requestUrl` and `requestHeaderList` give its
address and headers) and returns servant's `Response`; the transports live
in `Wiki.App.Backend.Http.Transport` and are re-exported by
`Wiki.App.Backend.Http`. `answer`, `failureOf`, `fromApiError`,
`sessionInfo` and `fromSessionInfo` move to `Wiki.App.Backend.Http.Client`.
On the wire: JSON is sent as `application/json;charset=utf-8`, an `Accept`
header is sent, a form's boundary is random, and a response with a status
other than the one the endpoint declares (a 201 for a read, say) is
`Unreachable`, as a 2xx with the wrong body already was.

The assistant's settings are sealed in a vault (WP5.21): `MonadAssistant`
stores the device's record (`deviceRecord`, `keepDeviceRecord`) instead of
the settings (`assistantSettings`, `keepAssistantSettings`,
`updateAssistantSettings`, `readSettings` and `writeSettings` are gone), and
gains WebCrypto and WebAuthn (`sealWith`, `openWith`, `deviceKey`,
`createPasskey`, `usePasskey`, `wrapWith`, `unwrapWith`, ...).
`Wiki.App.Assistant.Keys` reads and changes the settings (`loadKeys`,
`readKeys`, `changeKeys`) and syncs them (`turnOnSync`, `unlockKeys`,
`addPasskey`, `removePasskey`, `turnOffSync`, `setAskEachTime`).
`MonadVault` (`Wiki.App.Assistant.Sync`) is the server's half, with
instances for `HttpWiki` and, keeping nothing, `MemWiki`, `BrowserDOM` and
`MemDOM`; the shell, the editor and the assistant's settings page need it.
`sealingHere` says whether the browser offers WebCrypto: a page served over
plain HTTP from another machine gets none, and there the settings are
stored as text, as before, with a warning on the settings page. The editor
loads the keys with `loadFollowedKeys`, which asks the server only when the
device already syncs.

The assistant checks another service's base URL against the page's
Content Security Policy before it sends anything (WP5.21): an address the
page does not allow fails at once with `Blocked`, saying which addresses
it does allow. The server section of the administration sets the
assistant's hosts. The browser tests run under the page's policy, and
fail on any violation.

The routes and backend methods for mailed links take the new token types
(WP5.15): `ResetPassword ResetToken`, `VerifyEmail VerificationToken`,
`Unsubscribe UnsubscribeToken`, and `resetPassword`, `verifyEmail` and
`unsubscribe` likewise.

The demo's `attachBytes` and `attachUrl` take a `MimeType` (WP5.15).

The demo's `attachBytes` and `attachUrl` take a `FileName` (WP5.15).

The demo's `attachUrl` takes a `Url` (WP5.15).

Passwords are `Password` in the backend classes (WP5.15): `signIn`,
`resetPassword`, `setPassword`, `enrolTotp` and `setOwnEmail` take one. The
forms wrap what was typed when they submit it.

Presenting shows a slide's steps (WP5.20). The right arrow, Space and
PageDown show the next step before the next slide; the left arrow and
PageUp hide the last step, or go back to the slide before, whole; End goes
to the last slide, whole. A later step's content is in place from the
start, hidden with `visibility: hidden`, and fades in (not where reduced
motion is asked for). `PageSlides` has a step after the slide, written
`?step=2` and left out at 1, and the slides view's `Input` has `step`. The
overview and the print show whole slides; "each step on its own page"
prints a copy of a slide at each of its steps before the slide. The demo's
Presentations deck has two more slides, "Steps" and "One item at a time".

The browser application compiles faster, and nothing else changes
(WP5.19): haskell-halogen is pinned to the commit that writes its element
rows as flat lists of labels.

The demo starts without reading the attachments' bytes or the pages'
versions from IndexedDB, only their keys (WP5.16c). An attachment's bytes
are read when it is shown (for its object URL, which then holds them) or
exported; a page's versions when its history is shown, and its first
version when the page's creator is needed. `MemState` gains `unreadBlobs`
and `unreadVersions`, and `Records` holds `Nothing` for a record not read.
A write saves only the stores it may have changed (`touched`), so a draft
saved while typing encodes the drafts and nothing else. `readWholly` gives
the wiki with everything read, for the tests.

The administration can leave accounts with a password to the server's
console (WP5.18). "Who may come in" has a checkbox, on by default, "The
administration may create accounts with a password". With it off, the
Users section shows a note naming `wiki-server users add` in place of
its form for a new user. The demo keeps the setting for the tab's life,
as its other wiki settings, and then refuses `createUser` with
`Forbidden`, as the server does.

The administration's Activity pages through the log with the entry its
"Older" starts after, not with how many entries to skip (WP5.16b), so
an old page of a long log is as quick as the first.

A page's history lists its latest 50 versions, and "Older…" under the
list fetches the 50 before them (WP5.16b). A version older than those is
still opened by its address: the history fetches the versions down to it.
`MonadWiki.listVersions` takes a `VersionsQuery`; each version carries its
number.

The backends answer `NotFound` for a space the current user may not view,
and for everything in it, exactly as for a space that does not exist
(WP5.17). `Forbidden` is left for what the user may not do in a space they
may view. The in-memory backend follows the server, and the contract tests
state the rule. So a private space now shows "There is nothing here" to
whoever may not view it, with the title "Not found", instead of "You do
not have permission". The client's own checks before a write (the editor
and the new page form) still say "You do not have permission", since
they apply to spaces the user may view.

The writing assistant works with Claude Haiku 4.5 again (WP5.17). Since
the effort picker came (WP4.19), every request has carried
`output_config.effort`, and Claude Haiku 4.5 refused each one with a 400:
"This model does not support the effort parameter." The island
(`web/src/assistant.js`) now sends the request again without
`output_config` and leaves it out for the rest of the chat, as it already
did with `thinking` for a model that refuses adaptive thinking. Claude
Haiku 4.5 refuses both, so its first answer comes after two refusals. The
effort picker stays: a model that refuses the effort runs without one.

"Export the wiki" writes version 2 of the export format (WP5.8,
`docs/export.md`): a directory per space and per page, with the page's
Markdown in `page.md`, its attachments and its comments. "Import a wiki"
reads versions 1 and 2, and brings the comments in, their authors matched
by login with the archive's users. The summary of an import counts the
comments. A comment by someone who is not a user here (one an import kept
by their name) shows their name followed by "(not a user here)". The new
ids the demo makes start after the ids of imported comments too. The demo
still keeps each page's comments in IndexedDB in the record it had, so a
demo saved before reads as it did.

`Wiki.App.Shell` compiles in an eighth of its time (WP5.13): 11 s instead
of 87 s on wasm, and 5.4 GB allocated instead of 21 GB. Its `Slots` row has
six labels instead of 27: the views whose output is `ViewOutput` share the
label `"view"`, indexed by `ViewSlot`, and the children with no output
share `"part"`, indexed by `PartSlot`. The row is written as a sorted list
with `Data.Row.Internal`'s `R` and `:->`, not with `.+` and `.==`, because
the compiler reduced those type families again at every slot and kept the
proofs in the compiled code. Nothing a user sees changes.

The writing assistant's chat shows that the model is working (WP5.11).
From Send until the first text, the model's message shows "Thinking" with
three animated dots (still when the reader prefers reduced motion). After
three seconds without anything from the model, a count of the seconds
waited appears beside the dots. The summary of the model's thinking streams
under the line, collapsed until clicked, and stays at the top of the
message as "Thought" once the model goes on. While the model writes a tool
call, a status line says "Editing the page"; the edit's note replaces it
once the edit is made. Streaming text ends in a blinking cursor. Each
message shows the time it was sent, by the browser's clock, and a finished
answer shows how long it took. The island (`web/src/assistant.js`) and
`jsbits/assistant.js` report two more events for this: `thinking`, the
summary's text as it streams, and `tool-start`, when the model begins a
tool call (`Wiki.App.Assistant.Heard`'s `HeardThinking` and
`HeardToolStart`). The scripted provider takes `{thinking}` steps, a
`pause` on a tool step, and a step of `{wait}` alone.

The panel closes with a "Close" button in its header, which replaces the
`×`, and with Escape in the message box (`Wiki.App.Assistant.closesPanel`).
The provider's bubble still closes it too.

The effort a new conversation starts with is chosen per provider on the
assistant's settings page ("Effort"), and is medium unless chosen. The
picker under the chat starts at that default and changes the effort for the
current conversation only; it no longer writes the settings.

A page shown again is fetched again (WP5.14), so a tab no longer shows a
page without someone else's edit made while it showed another page. The
HTTP backend caches page content (pages, lists of pages, the details of a
blog's posts, version lists, searches and the directory's page counts)
only until the first route change, which the shell announces with the new
`MonadLoad.endPreload`. Until then the cache answers from what the server
prerendered the page with, so the first render still matches that page;
from then on page content is fetched on every read, and the cache holds
only the session, the spaces, drafts, versions, comment threads,
notifications, watches and the administration's data. The list of a
space's pages has no bodies (`Wiki.Core.Page.PageSummary`): the views read
a page by itself, the blog reads its home page and lists its posts with
the excerpts `postDetails` gives, and the new-page form reads the template
it starts from. The page view tells the shell the page it shows
(`Showing`), for the link preview in the document's head.

The live channel's socket waits a random 70 % to 130 % of its pause
before it opens again (WP5.16a), so that the tabs a server restart
disconnected do not all connect again in the same instant.
`Wiki.App.Live.jittered` is that wait. The longest wait is now 39 seconds,
130 % of the half-minute pause.

TikZ pictures draw Polish and German letters (WP5.10): `ł` and `Ł`, which
failed with "Cannot read properties of undefined (reading 'toString')",
the umlauts, which failed with "Could not find font metric for 127", and
`ą ę Ą Ę`, which failed with "Command \k unavailable in encoding OT1". The
web bundle patches dvi2html in TikZJax's worker (`tikzjax/run-tex.js`,
by `web/src/tikz-patch.mjs`, which stops the build if a new TikZJax no
longer has the code it patches; `tikzjax/NOTICE.txt` says what changed),
and the island defines an ogonek, drawn by TikZ, before each picture. A
character the fonts do not have, such as `€` or `°`, gives an error in TeX's
shape that names it and its line, instead of a JavaScript error.

The page's payload is written from and read into the backend's cache
directly (WP5.9): `Wiki.App.Backend.Http.Preload` no longer has the
`Preload` record, a record per kind of answer, `Answer`, `toPreload` or
`fromPreload`; `preloadJSON` and `parsePreload` are the payload as a JSON
value, beside `encodePreload` and `decodePreload` as before. A page carries
the same bytes, and the module compiles in a third of what it cost.

Every form of the administration is one column (WP5.5): the public address,
the mail server and its test, a provider, the backups, an invitation and a
new user each put a label above its field, every field as wide as the form
up to 30rem, and the buttons under the last, where they wrapped two or three
fields to a row before.

The administration's "Add a provider" explains itself (WP5.5): under each
field a hint in the README's words says what it is and, for the client id,
the secret and the fourth field, where it comes from for the kind chosen;
the line on the redirect URI says what is missing while it cannot be known
(the public address, then the name) and, once it can, how to register it.

TikZ pictures are drawn behind a proxy that refuses gzip downloads (WP5.5):
the page serves TikZJax's TeX, its format and its TeX files
(`tikzjax/tex.wasm.gz`, `core.dump.gz`, `tex_files/*.gz` as published) as
zlib streams of the same bytes named `.bin`, sent as
`application/octet-stream`, and the worker that starts TikZJax asks for
those names. No `.gz` file ships under `tikzjax/` any more; a deployment
serving the page from its own server needs nothing new.

The writing assistant, bring-your-own-key (WP4.19, decision 21). Round
bubbles floating at the top right of the text, Claude's and ChatGPT's with
their logos from simple-icons, kept in view under the toolbar and growing
into a pill with their label on hover or focus, open a chat beside the
Markdown with that provider, or close it if it is open with it; switching
provider starts a new conversation, the changes made by then kept to decide
(`Wiki.App.View.Assistant`). Under the message, the provider's model (its
list, or "Other…") and its effort (Anthropic's `output_config.effort`,
OpenAI's `reasoning.effort`, low by default), kept per provider with the
settings and taking effect from the next message. The panel has shortcuts
that fill the message in (improve, fix grammar, shorten, expand, summarise,
continue, translate), the selection attached as a chip that can be detached,
the model's answer streamed, Stop, and the conversation kept for the editing
session. The model edits the page through two tools, and each edit is a
tracked change in CodeMirror, on green with what it replaced struck through
in red, accepted or rejected with the control after it or all at once in the
panel; a save with changes left accepts them, which the editor says beside
Save. The next message tells the model which of its changes the author
rejected or undid (and accepted) since its last turn: the editor remembers
each decision by the change's id. Settings are a page of the user's own,
`/assistant/` (`AssistantSettings`), reached from the account panel and the
demo's user menu: a key per provider, kept in this browser's IndexedDB
database `wiki-assistant` under the user's id and never sent to the wiki's
server, "Test the key", "Forget", the provider and the model, and a warning
on a page served over plain HTTP. Keys outlive signing out; "Forget" takes
them away. `MonadAssistant` (`Wiki.App.Assistant`) is required by
`Shell.component` and `Editor.component`, with instances for `BrowserDOM`,
`MemDOM`, `ReaderT`, `MemWiki` and `HttpWiki`; the providers are Anthropic's
and OpenAI's SDKs in `islands/assistant.js`, fetched the first time the
panel is used. `SignIn.Input` gains the `router`.

The models offered are the provider's own: the editor asks each provider
with a key for its list (`GET /v1/models`, `listModels`) when it opens, as do
keeping or testing a key and "Refresh the list" on the settings page, and the
list is kept with the settings, with when; the pickers group it into
Recommended, All models and Other…, the first recommended one the default,
and offer the wiki's short list until there is one. The same request says
whether the provider can be reached: one that cannot (a network that blocks
it) keeps its bubble, dimmed, titled "Cannot reach Anthropic from this
network", and the panel says so with "Try again"; a message that gets an
answer clears it. A provider has a bubble only once the user has a key for
it; a user with none has one bubble, "Assistant", which opens the panel at
its set-up. OpenAI's settings take a Base URL, for any service that speaks
its API (GitHub Models, OpenRouter, Ollama or LM Studio on this machine,
which need no key: an empty key sends no Authorization header); its list is
all its models, and plain HTTP to another machine is warned against. The
settings are the editor's, which the panel changes through it
(`Assistant.Output`'s `ChangeSettings`, `Retry`, `Reached`; `Assistant.Input`
gains `settings`, `problem` and `checking`; `Using` is gone), each change made
to the settings as they are kept (`updateAssistantSettings`).
`MonadAssistant` gains `listModels`, and `Ready` its `baseUrl`. On a page
where a test installed the scripted provider, its script answers for every
provider, so that no test reaches a real one.

No password for accounts that sign in with a provider; the administrator
mails password links (WP5.6). The menu under a user's name offers no "Set a
password…" to one who has no password and signs in with a provider the
server has (`View.SignIn.passwordOffer`). The administration's Users table
shows no password button for such a user; where the server sends mail and
the user has a verified address, "Send a password link…" asks, then mails
them the reset's link; otherwise "Set password…"/"Reset password…" stays,
with why under it ("The server sends no mail…", "No verified address…", or
a disabled login) (`View.Admin.passwordControl`). `MonadAdmin` gains
`sendPasswordLink`: over HTTP the new endpoint; the demo refuses it, sending
no mail. A user whose providers are all gone from the server reads "No way
in" in the table.

The demo's Diagrams page has a TikZ picture whose fence starts with
`\usetikzlibrary` (WP5.3), so that the README's example of one links to a
page where it is drawn. The test suite checks the README against the demo:
each example of Markdown it shows is on the page it links to, word for word,
each link into the demo leads to a space or a page the demo has (and to one
of the page's headings, when it names one), and each of
its screenshots (`docs/screenshots/`, taken by `toolchain/screenshots.mjs`)
is under 300 KB.

Licensed under the MIT licence (WP5.1), where it was proprietary: the
package now ships `LICENSE` and says `license: MIT` in its `.cabal` file.

The demo keeps its wiki in the IndexedDB database `wiki-demo`
(`Wiki.App.Demo.demoDatabase`), no longer `wiki` (WP5.2). IndexedDB is per
origin, and the demo on GitHub Pages shares `swordlash.github.io` with every
other site published there, so the name has to be the wiki's own. A browser
that used a demo built before this keeps what it wrote under the old name,
which the demo no longer opens: it starts from the demo's own content, and
the server's "Import this browser's demo data…" no longer finds the old
database either. To carry such a wiki over, export it with a build from
before this change ("Export the wiki" in its administration) and import the
zip file. No public demo existed under the old name.

Tables of contents and templates (WP4.15). A page with three headings or
more shows a "Contents" panel: beside the text on a wide window (with the
comments' panel under it when that is open), above it on a narrower one,
foldable (this browser remembers), with the section being read marked
(`jsbits/toc.js`, an IntersectionObserver setting `data-current`); a page
with `[[toc]]` shows the list there instead. A heading shows a `#` link to
itself on hover; following it, or any link to a place in the page, puts the
place in the address bar, and a page opened at an address with a fragment
scrolls to it. Templates: "Use as template" in a page's actions (for whoever
may edit it), a note on a template, the space's templates under "Templates"
in its sidebar and its pages rather than in the tree, and "New page" offers
"Blank", the space's templates and the built-in ones, filling in the title,
the date and the author. `MonadWiki` gains `setPageTemplate`, on every
backend and in the contract; page counts leave templates out, and so does a
search unless its query asks for them. The demo's team has a template,
"Weekly sync", and its handbook a `[[toc]]`.

Reading offline and installing (WP4.17). The page links a web manifest
(`web/manifest.webmanifest`: every address relative, so one file serves any
base path) with icons `web/bundle.sh` draws from `web/src/icon.svg`
(`web/src/pwa.mjs`, 192 and 512 pixels, plain and maskable), and `index.js`
registers a service worker (`web/src/sw.js`, written as `sw.js` with the
build's version, a hash of the files it keeps, and their list): the
application's files kept when it is installed, pages and the API's reads kept
as they are read (50 pages, 300 answers, oldest out; images of at most 1 MB
among the attachments; never `session`, `admin/…`, `account/…`,
`notifications…`, drafts, exports, the archive, invitations, mail links,
`events` or `auth/…`), all served from the network while there is one and
from what was kept when there is not, with `web/offline.html` for a page
never read. A new build's worker deletes every other version's caches. A page
the worker served offline carries `<meta name="wiki-offline-copy">` with the
time it was kept, which the shell reads (`Wiki.App.Offline.offlineCopy`) to say
"You are reading an offline copy from …" above the route, over the network
backend, until the reader goes elsewhere; the shell's offline notice now also
shows from the start for such a page, or when `navigator.onLine` is false. "Install" sits in the header while the
browser's `beforeinstallprompt` offer, kept by `index.js`, is open. Signing out
over HTTP lets go of the pages and answers kept (`forgetReads`). The WASI shim
is bundled as `wasi-shim.js` instead of being imported from jsDelivr, so that
the page starts with no network.

Observability (WP4.10). The administration gains "Activity"
(`Wiki.App.View.Activity`): the audit log, newest first, fifty at a time,
filtered by person; and the Server section a "Status" part
(`Wiki.App.View.Status`): the program, its schema, the newest backup, live
channels, the wiki's counts and the last errors the server logged, with
"Refresh". `MonadAdmin` gains `activity` and `serverStatus`; the demo keeps no
log and has no server, and both parts say so. Over HTTP both are read from
what the server's page carries once (`once`, the cache's `activity` and
`status`, preloaded) and afresh after that, since they change on the server
by themselves.

Spaces shown as blogs (WP4.14). "Show as a blog" in Space settings. A blog
opens at its posts (`Wiki.App.View.Blog`): under its home page, if it has
one, each post as a card of the directory's with its title, date, author
where known, comments and excerpt, ten a page, the later pages at
`/s/<space>/?page=n` (the new route `Posts`, which a space that is no blog
shows as `Space`). A post's page shows when it was posted and links to the
previous (older) and the next (newer) post. `MonadWiki` gains
`postDetails`, cached and preloaded over HTTP (a comment's write lets it
go) and answered by the demo from its versions and threads. The shell's
`Settled` answers with a `Wiki.App.Head.Head` rather than a title: a public
page's description and OpenGraph properties (`og:title`, `og:description`,
`og:url`, `og:type`, `og:image` from the page's first image or the space's
uploaded icon) and a public blog's feeds, which `Wiki.App.Static.withHead`
writes into a page for the prerender and the server alike (`headTags`; the
demo's addresses are paths, and it announces no feeds). `Rendered` and
`Served` gain `meta`. The demo's Blog is shown as a blog, without a home
page.

Mentions, watching and notifications (WP4.13). A mention, `@login`, is a
link to a search for it, titled with the user's name, for someone signed in
(`Wiki.App.View.Body`'s `Place` gains `people`, asked of the backend for the
logins a view shows: `askPeople`, `unasked`). The header has a bell beside
the user's name (`View.Bell`) with the unread count, the latest
notifications linking to their page or thread, "Mark read" and "Mark all
read", live over the server's WebSocket; a page's action bar and a space's
actions have a "Watch" button (`View.Watch`); the account panel, and the
demo's, a "Notifications" block (`View.NotificationSettings`): mail never,
at once or daily, and whether one's own pages and threads are watched. A
new capability, `Wiki.App.Backend.Notifications.MonadNotifications`, on both
backends (the demo keeps its notifications in IndexedDB store
`notifications`, database version 5, and mails nothing), with a contract in
`wiki-app:contract`. `Live.Feed` gains `listen`/`unlisten`, which keep the
socket open with no page shown, and `Heard` gains `Notice` and `Reopened`.
New route `Unsubscribe` (`/unsubscribe/<secret>/`, `View.Unsubscribe`),
shown in a closed wiki too. The shell, the page, the slides, the editor and
the space's and the blog's views ask for `MonadNotifications`; a blog's
view has the space's "Watch" button among its actions, and resolves the
mentions of its home page.

Account hygiene (WP4.11). The account panel under a signed-in user's name
gains `Wiki.App.View.Security`: their sessions with "Sign out" and "Sign out
everywhere", a second factor set up from a QR code drawn as an `<svg>` of
`<rect>`s (`qrRuns`) and a confirming code, with recovery codes shown once,
and removed with a code, and an e-mail address verified by a mailed link. A
new capability, `Wiki.App.Security.MonadSecurity`, for both backends: the
demo lists its one session (in a "Your account…" panel under its user
switcher) and shows the second factor and mail disabled with a note. The
sign-in form asks for the code after the password when the server wants one
(`SignInError.SecondFactorNeeded`, `MonadAccount.confirmSecondFactor`), and
offers "Forgot your password?" (`requestPasswordReset`). New routes
`ResetPassword` (`/reset-password/<secret>/`, `View.Reset`) and `VerifyEmail`
(`/verify-email/<secret>/`, `View.VerifyEmail`), shown in a closed wiki too.
The administration's Users table shows each user's address and second
factor, with "Remove second factor" (`MonadAdmin.removeSecondFactor`), and
"New user" takes an e-mail address where the server sends mail.

Presence and edit conflicts (WP4.12). Over the server's backend the page
view says who has its editor open ("Edgar Editor is editing this page.", at
the end of the action bar) and shows a save of the page made elsewhere at
once, or, while the reader has text selected, a comment's quote, a rename or
a move under way, offers it ("Changed since: show the new version"). The
editor watches its page too: when someone else edits it, it asks before
starting ("… Open the editor anyway?"), says it edits it once the author goes
on (or starts typing), names the others while it is open, says it stopped
when it goes away, and says when someone else has saved the page meanwhile.
A save refused as a `Conflict` opens the conflict view instead of the bare
refusal: their version, compared with the author's text, beside it (two
columns on a wide screen), with "Keep mine" (save over theirs), "Take
theirs" (their version in the editor, the author's text and draft gone) and
"Merge by hand" (the author's text stays, what their save changed beside it,
the next save over their version); the text is kept as a draft at once. The
demo has no channel, so no presence, but the same conflict view.
`Wiki.App.Live.Feed` gains `startEditing`, `stopEditing` and `editorsOf`
(said again on every new connection); `Editor.Input` has the `feed`; the
cache lets the pages read go when a save is heard (`afterEvent`).
`Wiki.App.View.Diff` renders a diff for the history and the editor alike;
`Wiki.App.View.Common.whoIs` names who is editing.

Scheduled backups (WP4.9). The administration's Server section has a
"Backups" part (`Wiki.App.View.Backups`, a component of its own that the
section mounts): whether the server backs itself up, when, how many it keeps
and where it copies them off the machine, the last backup's time, size and
result, when the next is due, and "Back up now", which reads the backups again
every two seconds while the server says one is under way. The rclone
configuration is typed once and never shown again ("Replace…", "Clear").
`MonadAdmin` gains `backups`, `setBackupSettings` and `backUpNow`; the demo's
backend answers that it makes none (`available = False`), and the part is
shown disabled with a note. The backend over HTTP keeps the backups as it keeps
the server's settings, and a page the server renders carries them.

Export to documents (WP4.16). A page's actions and a space's have an
"Export" menu (`Wiki.App.View.Export`, a `<details>` of links the browser
downloads) with the formats the backend makes: Word, HTML, EPUB and, where
the server has `xelatex`, PDF; a deck also PowerPoint and Beamer (its LaTeX,
and its PDF). `Session` gains `exports`, the formats the backend makes: none
over `MemWiki` (the demo has no pandoc, so it shows no menu), what the
server says over HTTP. The administration's "Server" section says what
pages export as and whether the server found `xelatex`.

One space at a time (WP4.6), as Confluence has it. The front page is the
directory of spaces (`Wiki.App.View.Directory`): a card per top-level space
with its icon, name, description, number of pages and subspaces, the spaces
this browser visited last (`Wiki.App.Recent`, kept in local storage, in a
browser only), and "New space". Inside a space the sidebar shows that space
alone: "All spaces" and a menu to switch to another, its icon and name, "Up
to" the space above a subspace, its home page and "Pages and settings", its
pages, and its subspaces below them; the breadcrumbs start at "Spaces". A
space's own route shows its home page, or its list of pages if it has none;
the list moved to a route of its own, `SpacePages` (`/s/<space>/pages/`), so
a space or page slugged `pages` is written `~pages`. The space's
"Permissions" grew into "Space settings" (`Wiki.App.View.SpaceSettings`):
its name, description, icon (its letter, a colour, an emoji, or an uploaded
image) and home page, above its permissions; "Rename" moved there. A page's
actions offer "Set as home page" to whoever administers its space.
`MonadWiki` gains `setSpaceProfile`, `uploadSpaceIcon`, `spaceIconUrl` and
`pageCounts`, and `createSpace` makes a space with a "Home" page; the
backends keep a space without a home page that was deleted or moved away.
`HttpWiki` caches the page counts and the page carries them in
`wiki-preload` as `pageCounts`. The views' `Context` has `icons`. The demo's
spaces have emoji (Projects a colour), descriptions and home pages.

A page's bar of actions (`.page-actions`) and the editor's toolbar stay
under the header while the page scrolls, so that a long page is edited
without scrolling back up (the owner's request). The shell measures the
header's and the bar's heights into `--header-height` and
`--page-actions-height` (`jsbits/layout.js`, `Wiki.App.Browser.keepHeights`),
which the comments' panel is stacked under too, and marks a bar stuck there
with `data-stuck`, which gives it a hairline.

The editor no longer loses what is typed just after a save is asked for.
It made its text read-only while the save was on its way, which refused
the keystrokes (and toolbar commands) that came meanwhile without a word;
a Ctrl+S followed at once by more typing lost that typing on a slow
connection or machine. The text stays writable now, and what is typed
during a save is unsaved after it and kept as a draft, as the save already
allowed for.

Comments (WP4.5). `MonadComments` (`Wiki.App.Backend.Comments`: `listThreads`,
`openThread`, `reply`, `editComment`, `deleteComment`, `deleteThread`,
`setResolved`) has instances for `MemWiki` (kept in IndexedDB, in a store
`threads` of database version 4), `HttpWiki` (a page's threads cached and
carried in `wiki-preload` as `threads`, a comment's write folded into them
rather than emptying the cache) and the server's storage, with a shared
contract (`Wiki.App.Backend.Contract.Comments`). The page view marks the
quotes of its inline threads in the page (`Wiki.Core.Anchor`), lists them
in a panel beside it (`Wiki.App.View.Comments`), opened by "Comments (n)"
after "History" or a click on a quote, and lists threads about the whole
page under it, with a form for a new one; text selected in the page gets a
"Comment" button beside it (`jsbits/comments.js` reads the selection as an
anchor), and someone not signed in reads the threads and is told to sign
in. `Wiki.App.View.Body` gains `rendered`, `articleOf` and `commentBodies`
and is polymorphic in a component's slots (`HasIslands`). The live
channel: `Wiki.App.Live` (`MonadLive`, an `HttpWiki` instance only, handed
to the shell as `Shell.Input.live`), one WebSocket per tab, opened when a
page is first watched, subscribed to the page shown, whose comments are
then replaced with the ones the server's answer carries (`Heard`'s
`Replaced`), which catches up with whatever changed since the page was
read without a request; opened again after a pause (1 s doubling to 30 s)
when it closes, and subscribed again, with the same catching up; and
opened again as the new user after signing in or out. The demo's first post has comments. Exports carry no comments.

The server's settings in the administration (WP4.4). A "Server" section
beside "Who may come in" (`Wiki.App.View.Server`): the public address, the
mail server with a test mail, and the providers, each with its redirect URI
and "Check"; secrets are typed once and shown only as set or not.
`MonadAdmin` gains `serverSettings`, `setServerSettings`, `checkProvider`
and `sendTestMail`; the demo keeps the settings for the tab's life, asks no
provider and sends no mail; over HTTP they are cached and preloaded with the
administration.

Account fixes (WP3.7). A signed-in user's name is always a button that opens
their account panel, not only where the server names providers; the panel has
"Change password…" (current, new, new again) or, for a user without a
password, "Set a password…", through `MonadAccount`'s new `changePassword`
(`passwordErrorText` says why it failed); their other sessions end, this one
stays and keeps its cache. The administration's "Creates spaces" switch shows
on and disabled, with "An administrator creates spaces anyway.", for an
administrator, as the rules in `Wiki.Core.Permission` decide; a stored grant
is kept and shown again when they stop being one. The setting "A new account
may create spaces" reads "Let every new account create spaces", with a line
saying it applies to accounts people make themselves, by invitation or by
signing in with a provider.

Signing in with a provider (WP3.6). `Session` gains `providers`, which
the sign-in and "Create account" forms and an invitation's page offer as
links to the server's round trip ("Sign in with Google"), coming back to the
page; a signed-in user's name opens how they sign in (password, the
providers' accounts, "Connect …", "Disconnect", not the last way in), through
`MonadAccount`'s new `identities` and `unlinkIdentity`. The administration's
account column says "Signs in with GitHub" where that is so and disconnects
an account (`MonadAdmin.unlinkUserIdentity`; the demo's users have none).

The browser's network through haskell-halogen (WP4.3, with the pin at
haskell-halogen 5ea6dba). `HttpWiki`'s requests go through
haskell-halogen-net's `Halogen.Net.Fetch` instead of a `fetch` of our own
(`jsbits/fetch.js` is gone): the same requests (same-origin credentials, the
`X-Wiki-Request` marker, bytes in, status and bytes out), and now a request
whose wait is killed is aborted, so a view that goes away while it loads (a
navigation, a sign-out) leaves no request running. The time limits stay
(30 seconds, 6 minutes for an upload), enforced by the same kill.
`Wiki.App.Backend.Http` exports `fetchTransport` (the browser's transport
with limits of one's choosing), `timeLimit`, `fetchFailure` and `noAnswerIn`.
The browser's own cache is no longer told `no-store`: `Halogen.Net.Fetch` has
no cache mode, and the server's `Cache-Control: private, no-cache` on every
API answer already makes the browser ask it each time.

The slides' keys are heard on the whole page through
`Halogen.Query.Event.Window.keyDown`, subscribed while the slides are shown,
rather than by a listener on the view that needed the focus inside it; a key
that is one of theirs still has its default prevented as the browser
dispatches it. Over the server's backend the shell listens to
`Window.online`: while the browser is offline a notice in the corner says
the wiki cannot be reached, and when it comes back what the shell failed to
load for want of the network is loaded again. The shell's and the slides'
components now ask for `MonadUnliftIO` (the emitters are lowered to `IO`).

An open or closed wiki (WP3.5). The header offers "Create account" beside
"Sign in" in an open wiki; a closed one shows someone not signed in its name,
the way to sign in and a word on why, at every route, and reads nothing else
for them (`Wiki.App.Backend.shutOut`). A new route, `Invite` at
`/invite/<secret>/`, shows an invitation's form (`Wiki.App.View.Invite`),
which makes the account and signs its maker in. The administration gains a
section "Who may come in" (`Wiki.App.View.Access`): open or closed, whether
new accounts may create spaces, and in a closed wiki the invitations with
"Invite" and "Revoke", the link shown once to copy when it was not mailed.
`MonadAdmin` gains `wikiSettings`, `setWikiSettings`, `invitations`, `invite`
and `revokeInvitation`; `MonadAccount` (and `Accounts`) gains `register`,
`invitationFor` and `acceptInvitation`. The demo implements the settings and
invitations for the tab's life only (it starts open, as its pages are
prerendered) and makes no account from a link. The backend over HTTP keeps
and preloads the settings, the invitations and an invitation's details.

Accounts and permissions in the administration and in each space.
`MonadAdmin` gains `setCreateSpaces`, `createUser`, `setPassword` and
`setDisabled`, and `MonadWiki` gains `spaceAccess` and `setSpaceGrant`, with
`MemWiki`, `HttpWiki` (and the server's `SqliteWiki`) instances and contract
cases. The administration's users table has a "Creates spaces" switch beside
the administrator's, and an "Account" column: whether the user signs in with
a password, "Set password…" or "Reset password…" (a form in place) and
"Disable" or "Enable" (not for one's own login); a "New user" form (login,
display name, password, administrator) sits under it. A space's view has a
"Permissions" action for whoever administers it, which opens
`Wiki.App.View.Permissions`: the space's public switch (moved here from the
actions' "Make public"/"Make private"), its grants with "Revoke", those it
inherits with the space they are on, and a form granting a user or a group
View, Edit or Administer; the grant one administers the space by is not
offered to revoke. `MemWiki` keeps whether each user has a password and
whether they are disabled (in IndexedDB's `meta` store, under `accounts`,
with no new database version); a disabled user is nobody there, and the
demo's switcher no longer offers them.

Signing in and out of a server's wiki. `Wiki.App.Account` is a capability
of its own, `MonadAccount` (`signIn`, `signOut`, `sessionChanges`), which
`HttpWiki` has and `MemWiki` does not, handed to the shell as a record
(`Accounts`, `Shell.Input.accounts`) as the demo's controls are. The header
over a server shows "Sign in" (a small form: login, password, why it failed)
or the user's name and "Sign out" (`Wiki.App.View.SignIn`, in `hh`); the
operator, who is the administrator without signing in, gets neither. Both
empty the backend's cache, keeping only the new session, and the shell
reloads everything. A refusal while someone is signed in makes `HttpWiki` ask
who is asking; if the session has ended, the cache goes and the shell opens
the sign-in form, saying so. `Session` gains `standing`. Every request
carries `X-Wiki-Request`, set by the request builders so that every
transport sends it. The administration's refusal no longer tells a reader of
a server's wiki to switch users at the top right.

The administration has the wiki's people. A new class beside `MonadWiki`,
`Wiki.App.Backend.Admin.MonadAdmin` (`directory`, `setAdministrator`,
`createGroup`, `renameGroup`, `deleteGroup`, `addMember`, `removeMember`),
with instances for the in-memory backend (its groups and global grants were
records of the demo's IndexedDB database already, so the database keeps its
version) and for `HttpWiki` over the API's `admin/…` endpoints, whose
directory is cached and carried in the server's preload (`DirectoryOf`) like
every other read. Every method needs the global administer and refuses anyone
else before it looks for what they named. Its contract is
`Wiki.App.Backend.Contract.Admin` in `wiki-app:contract`, run by every backend
and, for the demo, against a reload from IndexedDB after every step.

The administration page gains two sections after the wiki's data
(`Wiki.App.View.Admin`): Users, a table of every user with a switch for
whether they are an administrator, disabled on one's own row (the backend
would allow it; the panel does not, since it would lock its user out at
once), and Groups, each with its members to remove, a choice of the other
users to add, and Rename and Delete (asking first, in place), with a form
for a new group. The shell asks its monad for `MonadAdmin` besides
`MonadLoad`.

Every page has a history. `MonadWiki` gains `listVersions`, `getVersion` and
`restoreVersion` (view to read, edit to restore; a restore is a save of the
version's title and body, through the same conflict check, discarding the
restorer's draft), in the contract and on every backend. The in-memory
backend keeps each version, with its author's id, in its state and, for the
demo, in an IndexedDB store `versions`, one record per version written once
(the database is now version 3; a version-2 database, and an imported
archive, start each page's history with the page as it is). `HttpWiki` keeps
the two reads in its cache, and the server's render carries them in its
preload (`VersionsOf`, `VersionOf`).

A page's actions gain History, for every reader: the route
`PageHistory space page version against` (`…/p/<page>/history/`, with
`?version=<time>` and `&against=current`; `history` is a route word now, so a
slug that is one is written `~history`) lists the versions, the latest first,
with their times (the time island) and authors, and shows the chosen one's
changes as a table of numbered lines, words changed marked with `<del>` and
`<ins>`, against the version before or the page as it is now. An editor may
restore any but the latest, after confirming in place. The demo prerenders
each page's history at its latest version.

The program starts from the page the server rendered. `wiki-server` renders
each route's page with `Wiki.App.Static.renderServed`: the application over
`HttpWiki` with a transport that answers at once (`newImmediateHttpEnv`, under
which `atOnce` asks the transport rather than give up), so every view loads in
its initial state. What the render read is written into the page
(`Wiki.App.Backend.Http.Preload`: `encodePreload`, in the API's own JSON, a page
already in its space's list left out) and read back by `Main.hs`
(`embeddedCache`) into the backend's cache (`newHttpEnvWith`), so the
program's first render is that page, which `hydrateUI` adopts with nothing to
repair, and nothing is fetched again. A payload that cannot be read is said
on the console (`Wiki.App.Browser.consoleWarn`) and the program loads as
before.

The cache keeps more, so that everything a rendered page shows is there at
once: refusals the wiki decided (`NotFound`, `Forbidden`; never `Unreachable`),
which go stale and are let go as answers are, and searches by their query.
`Cache`'s maps hold `Either WikiError`; `withDraft` and `cachedPage` follow,
and `cachedSearch`, `withSearch` and `kept` are new.

`wiki-app-prerender --server` writes `template.html` besides `index.html` and
`404.html`: the server's page with its mount point empty, which the server
renders into. `withBase`, `withTitle` and `escapeHtml` moved from the prerender
to `Wiki.App.Static`, for the server's pages too.

A moment in time is an island (`Wiki.App.Islands.LocalTime`, rendered as an
empty `<time class="wiki-time" datetime=…>`, `MonadIslands.renderTime`), which
the browser writes in the reader's zone and natively holds UTC: the editor's
notices of a draft used one, and a page rendered by a server in another zone
would differ from the program's first render. `Found` holds `UTCTime`s.

The importer offers a zip export from its first render, and the demo's data
once the browser has said it keeps some: the server renders the
administration without knowing what the reader's browser keeps, and the
program adopts that page as it is.

The application runs over the wiki's server too. `Wiki.App.Backend.Http` is
`HttpWiki`, a `MonadWiki` over the server's HTTP API (`wiki-api`): every
address from `Wiki.Api.Links`, relative to the page's `<base href>`; saves
with the version they started from in `If-Match`; attachments uploaded as a
multipart form it writes itself (`Wiki.App.Backend.Http.Request`); a refusal
read from its `ApiError` body, or its status, as the `WikiError` of the same
name. It goes through a `Transport`: the browser's `fetch` (one call, which
waits for the whole answer and gives up after 30 seconds, six minutes for an
upload), or anything else that answers a request (the server's tests call
its application in process). What it reads it keeps, per entity
(`Wiki.App.Backend.Http.Cache`), until the client next writes; a draft's
writes keep the rest. `wiki-app` now depends on `wiki-api`, which puts
servant's link types in `app.wasm` (248 KiB more, 57 KiB brotli'd).

`WikiError` has a fifth constructor, `Unreachable`: the backend could not be
asked, or failed to answer (no network, no answer in time, a 5xx, an answer
that is not the API's). The three reads that have no `Either` (`session`,
`listSpaces`, `searchPages`) throw it, and `attempt` catches it. The in-memory
backend never gives it. `Wiki.App.View.Common.failureView` shows an error with
a "Try again" button when trying again may help.

A new class, `MonadLoad` (`atOnce`, `attempt`), says how a backend answers.
The shell and the views that load what they show in their initial state (the
page, its source, the editor, the search results) do so only when the backend
can answer at once (`atOnce`): the in-memory backend always, `HttpWiki` from
what it has kept. Otherwise they render "Loading…" (shown only after 0.4 s, so
a quick answer does not flicker) and load in their initializer, on a worker,
so that the tree's loop never waits on the network. The demo's first render,
and so its prerender and hydration, are unchanged. Components ask for
`MonadLoad m` where they asked for `MonadWiki m`.

The shell no longer needs `MonadDemoUsers`: the demo's controls come with its
input (`Shell.Input`'s `demo`, a `Demo` record of `Wiki.App.DemoUsers`,
`demoControls` of the class), and `Wiki.App.input` gives them while
`Wiki.App.serverInput` does not. Without them the header shows who is signed
in rather than the switcher, and the administration's "Wiki data" exports the
server's wiki (`api/v1/export`). Before
the session and the spaces have loaded, the shell is the same at every
address (no breadcrumbs, no spaces, "Loading…").

Over the server, the administration's "Wiki data" also imports another wiki
into the server's, merging it with what is there rather than replacing it
(`Wiki.App.View.Import`, a child of the shell, given a `Migration` record by
`Shell.Input`'s new `migration` field, which `Wiki.App.serverInput` fills and
`Wiki.App.input` leaves empty). The source is a zip file of an export, or the
wiki the demo left in this browser's IndexedDB, offered only when it is here
(`Wiki.App.Backend.Mem.memWikiFound`, which asks without opening the
database, since opening it would make it) and read without being written to
(`readMemWiki`, unlike `openMemWiki`). The server's preview is shown as the
dialog "What to migrate", whose boxes and choices are worked out by the pure
`Wiki.App.Import`; the import is applied with them, and its summary shown.
`HttpWiki` gains `previewImport` and `applyImport`, and
`Wiki.App.Backend.Http.Request` a multipart form of several parts
(`multipartForm`, `Part`), file or text, which `multipart` now writes its one
file through, byte for byte as before. `HttpWiki` passes `MonadIndexedDB`
through, and `serverInput` now asks for `MonadIndexedDB` and `MonadUnliftIO`
of the base monad and gives a `Shell.Input (HttpWiki m)`;
`serverInputWith` looks for the demo's wiki in another database.

`Main.hs` picks the backend from the page's `<meta name="wiki-backend">`
(`Wiki.App.Browser.pageBackend`): `server` runs `HttpWiki`, anything else the
demo. `wiki-app-prerender --server` writes the server's two pages
(`index.html`, `404.html`), the application before it has loaded anything
(`Wiki.App.Static.renderLoading`), with that meta saying `server`; the
template, `web/index.html`, says `demo`.

The backend's contract, the hspec spec every `MonadWiki` passes, is a public
library of this package, `wiki-app:contract` (`Wiki.App.Backend.Contract`),
so that the server's storage runs the same spec as the in-memory backend. Its
`spec` takes an `around`-style action rather than an `IO` fixture, so that a
fixture holding a database or a directory lets go of it after each example.

The in-memory backend keeps each page's title and text prepared for the
search beside the page (`searchText`), made when the page is made or saved,
or the wiki read back or imported, dropped with the page, and evaluated at
the first search that needs it; so typing in the search box no longer
reparses and refolds every page on every keystroke. It is derived data: it
is neither in an export nor in IndexedDB, and a wiki read from either makes
it again.

A file pasted into the editor (a screenshot, an image copied in a browser,
files copied in a file manager) is attached and referred to at the cursor as
a dropped one is: an image embedded, anything else linked. The paste is
decided in its listener on the panes, beside the drop's, so it is taken
whether CodeMirror or the textarea before it has the focus, and the browser
is kept from putting in anything of its own (a file manager's copy of the
file's name, or an image); a paste of both files and text attaches the files
and drops the text. A paste of text alone is the editor's, as before.
`Wiki.App.Editor.Browser` gains `pastedFiles`. The HTML menu's `<mark>` is
now called "Mark", as the palette's row of highlights is "Highlight".

The editor's text is CodeMirror 6, which shows the Markdown as it will look
while it is typed: emphasis in italics and strong in bold, headings larger by
level, inline code and fenced blocks in monospace on a background of their
own (fenced code coloured by highlight.js, as the page is), links, quotes and
lists set off, and every marker (`**`, `#`, `>`, a fence) kept but dimmed.
It looks like the textarea it replaces (the same font, colours, padding and
dark theme, no line numbers or gutter) and behaves like it: Enter is a line
break, Tab indents, the toolbar and its shortcuts, drops, the preview, the
drafts and Ctrl+S are the component's as before, and a toolbar command is
one step of the undo. CodeMirror is bundled into `islands/editor.js`, which
`islands.js` imports the first time an editor opens (`wikiIslands.attachEditor`),
so a reader's page never fetches it (296 KiB, 97 KiB gzipped). The editor is
still rendered with a textarea holding the Markdown, which a page rendered
ahead shows and which is typed into until CodeMirror has loaded; CodeMirror
then takes its place, text, selection, focus and scroll, in the same box. The
Markdown is never normalised: what is saved is what was typed, byte for byte.
`Wiki.App.Editor.Browser` gains `attachEditor`, `detachEditor`, `typedText`
and `focusText`, and its text functions now take the element CodeMirror is
put in rather than the textarea.

Two things that went wrong in the editor before are fixed with it. A notice
that came or went above the Markdown (a conflict on save, Cancel's question,
a draft found) moved the elements after it, and Halogen, which matches
unkeyed children by their place, made the textarea anew with the text the
page was loaded with, so that what had been typed was no longer shown (the
work still held it); the notices now sit in a holder that is always there.
And after "Reload and lose my changes" the toolbar's commands and the way
back from the preview found no textarea, because a keyed element that is
replaced clears the ref the new one has just set; the component now holds
the element CodeMirror is put in, which is not replaced.

The editor's toolbar has a "Colour" button, which opens a palette of
eight text colours and five highlights, with "No text colour" and "No
highlight" to take one away. The colours are classes (`c-red`, `h-yellow`,
listed in `docs/markdown.md`) that `web/style.css` draws in the light and
the dark theme; a page still cannot have a `style`. The toolbar's menus
share one state, `menu :: Maybe Menu`, so opening one closes the other.

Export, import and reset have moved from the foot of the user menu, where
nobody looked for them, to an "Administration" page at `/admin` (the route
`Admin`), linked from the header for whoever holds the global `Administer`
permission. Its first section, "Wiki data", has the note on whether this
browser keeps the demo's changes, "Export the wiki", "Import a wiki…" and
"Reset the demo content…", with the same confirmations and messages, and a
reset now says that it is done, since nothing else on the page shows it.
The page has a heading per section, so that later sections (users and
groups) go beside it. Anyone else at `/admin`, signed in or not, is told
that the page is for administrators and how to switch to one; the controls
are never shown to them. The user menu only switches users. The page is not
prerendered: its address gets `404.html`, as an editor's does, because what
it says about the browser keeping the demo is known only in the browser.

A space's subspaces and pages are listed in an order its administrators
choose under "Order" in the space's view, one for each: by name (natural
order, so "Part 2" before "Part 11"; the default), by date, newest or oldest
first, or by hand. By hand, whoever may edit the space has buttons beside
each page and subspace in the space's view that move it to the top, up, down
or to the bottom; a new page or subspace goes last, and a space switched to
by hand keeps the order it showed. The sidebar, the space's view, the front
page and the backend's lists all order with `Wiki.Core.Order`; `listSpaces`
and `listPages` now give a tree in order, each space or page followed by
those under it, rather than one list sorted by name. `MonadWiki` has
`setSpaceOrder` (`AdministerSpace`), `shiftSpace` (`Edit` on the parent) and
`shiftPage` (`Edit` on the space), with contract tests; `createSpace` stamps
the space's `createdAt`, and the demo's spaces have times of their own.
`pageTree` takes the space's order and a function for what follows each
link. Records kept in IndexedDB before read as by name, at position 0, and a
space as made with its first page; the database's version is unchanged.

A new page is made before it is edited: `NewPage` is a small form for the
title (`Wiki.App.View.NewPage`), which creates the page with an empty body
and opens the editor on it, so files can be attached before anything is
saved. The editor edits pages that exist only: `Editor.Input` has the
page's `path` in place of `Target`, and the "save the page first" state is
gone. Its buttons are "Save", which saves and stays (Ctrl+S and Enter in
the title too), showing a green "Saved" notice in a corner for three
seconds as a `role="status"` live region, and "Save and close", which saves
and shows the page; each save moves the version the next is checked
against. `Wiki.App.Browser.localTime` writes a time as the reader's
browser does.

Drafts. `MonadWiki` has `getDraft`, `saveDraft` and `discardDraft`, the
signed-in user's draft of a page (`Wiki.Core.Draft`), needing `Edit` on the
page's space; `savePage` discards the saver's draft, deleting a page or a
space discards its drafts, and the contract tests say so. The editor saves a
draft two to four seconds after the typing stops and says "Draft saved"
quietly; it takes up a draft of the page's current version when it opens,
saying so, with a button to discard it, and only offers one of an older
version. Cancel with unsaved work asks whether to keep the draft. The demo
keeps drafts in `MemState` and in IndexedDB, in a new store `drafts`, so the
database is now version 2 (a database of version 1 is upgraded and read
back as it was). Drafts are not exported, and an import discards them.

Formulas are set with macros, and with chemistry. KaTeX comes with mhchem
(`\ce`, `\pu`) and the wiki's built-in macros, `web/src/katex-macros.tex`
(`\C`, `\Q`, `\abs`, `\norm`, `\floor`, `\ceil`, `\dd`, `\E`, `\Var` and
more), which `web/bundle.sh` bundles as text after checking that KaTeX reads
every line. Over them come a space's macros and its ancestors', and the
definitions of the formulas before a formula on its page: `Island`'s
`MathInline` and `MathDisplay` carry these as `Macros`, and `MonadIslands`'
`renderMath` takes them, so a formula is set again when a definition before
it changes and is set the same whatever order the islands are drawn in.
`web/src/macros.mjs` reads each block over the ones before it, a
`\newcommand` of a macro defined farther away replacing it rather than
failing; a block KaTeX cannot read keeps what it defined and the page is
drawn regardless. `MonadIslands` has `checkMacros`, KaTeX's error for a
block. `islands.js` is 35 KiB larger (8 KiB with brotli).

`MonadWiki` has `setSpaceMathMacros`, which takes `AdministerSpace`. A space
offers its administrators "Math macros": the block in a textarea, KaTeX's
error under it as it is typed, a formula to try it on, and Save, which a
block KaTeX cannot read does not pass. Every reader sees the macros a
space's pages have under "Math macros" on the space. The demo's Docs has
three macros, which its Mathematics page uses with a definition of its own
and with `\ce`; the Markdown guide has a `\ce` line. (A demo kept in a
browser from before shows them after "Reset the demo content".) Records
kept in IndexedDB use the export's codecs, so a space kept before reads as
one with no macros, and the database's version is unchanged.

TikZ pictures are drawn in the browser. A `tikz` fence is an island,
`Island`'s new `Tikz`, rendered as an empty `<div class="wiki-tikz">` by the
program and with its source by the prerender, as a Mermaid diagram is, and
drawn by `MonadIslands`' new `renderTikz` with TikZJax (npm's
`@drgrice1/tikzjax` 1.0.0-beta24): TeX compiled to WebAssembly, run in a
worker, its DVI turned into SVG. `web/bundle.sh` copies TikZJax's worker,
TeX, its format, the TeX files of the packages and libraries it has and the
Computer Modern fonts into `tikzjax/`, and bundles `web/src/tikz.js`, which
drives the worker, into `islands/tikz.js`; `islands.js` imports it the first
time a page has a picture, so no other page fetches any of it, and nothing is
fetched from anywhere but the page's own origin (the worker,
`web/src/tikz-worker.js`, refuses TeX any other address). A first picture
fetches about 6.4 MB; later ones are drawn in a few hundred milliseconds, one
at a time, and a picture drawn once is kept, so a preview does not run TeX
again for a picture that did not change. The SVG is copied into the page
element by element through an allowlist, never set as HTML; black is drawn
in the page's text colour, so pictures show in the dark scheme. A picture
TeX cannot draw shows its source with TeX's error under it, its line counted
as the author's; one that takes TeX more than 30 seconds is given up on. The
editor's toolbar has a TikZ button, the Markdown guide a picture, and the
Diagrams page a commutative diagram and a plot. (A demo kept in a browser
from before shows the new pages after "Reset the demo content".)

`renderMermaid` and `renderTikz` start the drawing and return, and the
island component calls them with `liftEffect`: islands.js fills the element
when the drawing is done. They used to wait for it, from a `lift`, and in
the built page a link followed while a page's diagram or picture was still
being drawn then left the page as it was; the smoke test now follows links
from a page whose picture is held back.

Code is highlighted in many more languages: on top of highlight.js's common
set, every language of the TIOBE index's top 20 it has (Fortran, Delphi and
Object Pascal, Ada, MATLAB, assembly for x86, ARM and MIPS, Prolog, Lisp,
Scheme, Dart, Julia, Groovy, SAS, among others), and batch files, Awk,
VBScript and Tcl, with the fence names authors use (`asm`, `m`, `f`, `jl`,
`vba` and others added as aliases). `docs/markdown.md` lists them.

The demo's whole wiki can be exported and imported as one zip file, from the
foot of the user menu. "Export the wiki" downloads `wiki-<date>.zip`, an
archive in `wiki-core`'s `Wiki.Core.Export` format (see `docs/export.md`): a
manifest, a JSON file per kind of record and each attachment's bytes as a
file. "Import a wiki" reads such a file, checks all of it, says how much it
holds and asks before it replaces the wiki, in memory and in the browser in
one transaction; what it refuses, it refuses with the reason. The zip files
are made and read in the browser with fflate, bundled into `islands.js` as
`globalThis.wikiArchive` (`web/src/archive.js`); `Wiki.App.Browser` has
`zipFiles`, `unzipFiles` and `download`. The browser's records are now that
format's records too, and the people, the groups and the global grants are
kept with the rest, since an import replaces them (stores `users` and
`groups`; the global grants under `meta`). `MonadDemoUsers` gains
`exportDemo` and `importDemo`; `Wiki.App.Backend.Mem` has `memArchive` and
`importMemWiki`, and `Wiki.App.Backend.Mem.Archive` turns the wiki into an
archive and back.

The demo starts signed in as `admin`, Ada Admin, so that a newcomer sees
everything it has at once: `Wiki.App.Demo.demoState` has `admin` as its
current user, the prerendered pages show the admin's view (Edit and the
private spaces among them), and a reload or "Reset the demo content" starts
there again. The tour says so, and walks through being nobody from there.

The program adopts the page it arrives in rather than replace it: `Main.hs`
mounts the shell with haskell-halogen's `hydrateUI`, which keeps the
prerendered elements and text, attaches the listeners and sets what HTML
cannot carry, so the page no longer flashes as the program starts, and focus,
selection and scroll survive it. For that the program's first render has to be
the prerendered page, so the shell, the page, source, search results and editor
views now load what they show in their `initialState` (through `MonadWiki`, at
once) instead of in `Initialize`, which only tells the shell they are done; the
results view and the editor lost their `Loading` state, which nothing reached
any more. `Wiki.App.Static` has `prerenderedRoutes` (the list `wiki-app-prerender`
writes) and `startRoute`, which starts the application at a route either way,
building or adopting. An island's prerendered source is taken out as the
program adopts it, and its library draws it as before.

Forms, the search box and links in a page now keep the browser from their
defaults in the event's listener (`HE.preventingDefault`), not from the action
afterwards, which ran too late whenever the component was busy as the event
arrived: the space, page and new-space forms; the search box's arrows and
Enter, and a press on its list; a click on a link in a page's Markdown, which
`Wiki.App.Browser.articleLink` now decides, pure, in the listener (it replaces
`followArticleClick`; the action then calls `followArticleLink`). Escape in the
search box is still also the browser's (a search input clears its text).

The demo keeps its content in the browser. `Wiki.App.Backend.Mem.openMemWiki`
reads the wiki back from an IndexedDB database (haskell-halogen's
`Web.Storage.IndexedDB`), or writes the seed out into it the first time, and a
`MemWiki` run with `runMemWikiWith` and the store it gives writes through to
it: after every successful write, the records that write changed, in one
transaction, before the write returns. `Wiki.App.Backend.Mem.Persist` says what
is kept and how: the stores `users`, `groups`, `spaces`, `pages`,
`attachments` (an upload's bytes, as bytes, under its blob's id), `grants` (a
space's grants, under the space's id) and `meta` (the id counter and the
global grants), each record JSON in the export's format. Who is signed in is
not kept, so a reload starts as the demo does, nor is an attachment's object
URL, made again when the attachment is first shown. A
database that cannot be read (a record that does not decode, one a newer
version wrote, or one without every store this version keeps) is deleted and the demo's content written out in its place; a
browser with no IndexedDB runs the demo in memory as before. Either way the
console says why. Nothing is shared between tabs: the last to write a record
wins. `newMemWiki` and `runMemWiki` are unchanged and keep the wiki in memory
only, as the prerender and most tests want.

The user menu ends with "Reset the demo content…", which asks in place and
then puts the demo back as it was, in memory and in the browser (the
database is deleted and written out again), signed in as the demo starts. It
says whether changes are kept in this browser. `MonadDemoUsers` gains
`resetDemo` and `demoKept` for it. The demo's page loads the wiki from the
database `wiki` (`Wiki.App.Demo.demoDatabase`) before it mounts the
application; the prerendered pages still show the demo's own content, so
after an edit the first render differs from them, and adopting the page
repairs what differs.

The shell's router links are written as `<a>` elements in its `hh` quotes with
haskell-halogen's `Router.linkProps`, and the holes that were kept on one line
for the quoter's old whitespace rule are on lines of their own; what is
rendered is unchanged.

Anyone who may read a page may read its Markdown: a page has a source view on a
route of its own, `PageSource`, at `…/p/<page path>/source/`, which shows the
page's title, a "Back" link to the page and the Markdown as written, in a
monospace block that wraps long lines, with a "Copy" button that puts it on the
clipboard (and says whether it could; where the browser will not, the text is
left selected to copy by hand). The view is `Wiki.App.View.Source`; it asks for
the page as the page view does, so it is refused where the page is, with the
same message, and whether the reader may edit the page plays no part. Every
page's actions now start with a "View source" link, for every reader, after
"Edit" for those who may edit. `source` is one of the route's own words, like
`edit`: a page or space whose slug is `source` is now written `~source` in its
address (`/s/docs/p/~source/`), where before it was `source`. The prerender
writes each page's source as well, so a static host serves it at its address.
`Wiki.App.Browser` has `copyText`, the clipboard behind the button.

The editor has a toolbar above the Markdown: bold, italic, strikethrough,
heading (each press a level smaller, then none), bulleted, numbered and task
lists, quote, inline code, code block, link, image or attachment (the
upload, for a page that can have attachments), table, inline and display
math, a Mermaid diagram, a horizontal rule, and a menu of HTML elements
(highlight, keyboard key, superscript, subscript, underline, small print, a
collapsible section). A button wraps the selection, unwraps one already
wrapped, or puts in a placeholder selected for the typing; the edits are
`wiki-core`'s `Wiki.Core.Markdown.Edit`, and the browser's undo takes each
back as one step. Shortcuts: Ctrl/Cmd+B, I, K and E, Ctrl/Cmd+Shift+8 and 7
for the lists, Ctrl/Cmd+Alt+P for the preview; each button's title names
its own. The editor's keys, its drag-over and its drop are handled in their
listeners with haskell-halogen's `HE.preventingDefault`, so Ctrl+K and
Ctrl+E no longer reach the browser and nothing depends on the component
being free when the key arrives.

The editor shows the Markdown alone at every width. "Show preview" replaces
it with the draft as readers will see it, "Back to editing" returns to the
Markdown with its text, cursor, undo and scroll as they were, and Save and
Cancel are there in both. A "Side by side preview" checkbox brings back the
two panes on a wide screen and is remembered by the browser (local storage,
under `editor-side-by-side`); the narrow screen's Markdown/Preview switch is
gone. The editor and the shell now ask for `MonadBrowserDOM`. `kbd`, `mark`
and `details` in a page have a look of their own.

`Wiki.App.Editor.Browser` changed with it: `takeFiles` is now
`droppedFiles` (pure, for a drop's listener) or `chosenFiles`, then
`pickedFiles`; `editorKey` is pure and gives `Maybe EditorKey`; new are
`applyCommand`, `focusElement` and `clickElement`.

haskell-halogen is pinned at `a889566`.

Every page ends with a footer, "Built with haskell-halogen", the name a link to
haskell-halogen's repository; the prerendered pages have it too.

The views are written as HTML: the markup of the shell, the space, page, new
space, editor, search and search results views and the islands is in
haskell-halogen-th's `hh` quotes rather than nested `Halogen.HTML` calls, with
the same elements, attributes and handlers, so what is rendered is unchanged.
What has no markup of its own stays Haskell: a `Router.link`, a child
component's slot, and the editor's keyed title and textarea (a keyed element
and a textarea with text in it cannot be written in a quote); the Markdown is
still rendered by `wiki-core`. The library now depends on
`haskell-halogen-th`, and natively on `haskell-halogen-th-plugin`, whose GHC
plugin reports an error inside a quote at its line and column. Building it
compiles `ghc-lib-parser` once per compiler; the wasm build needs native
`alex` and `happy` below 2.2 on `PATH`, which `toolchain/bootstrap.sh` installs.

Presentations. A page written as slides (`Wiki.Core.Slides`) has "Present"
among its actions, for every reader, which opens it at
`…/p/<page>/slides/` (`Route.PageSlides`, the slide shown as `?slide=N`;
`slides` is a reserved word in addresses now, so a page or a space slugged
`slides` is written `~slides`). `Wiki.App.View.Slides` covers the window
with one slide at a time, scaled to it, a progress line and controls: the
arrow keys, Space, PageUp, PageDown, Home and End move, `f` toggles the
browser's full screen, `n` (or `s`) the speaker's notes under the slide,
`o` an overview of every slide to pick from, and a swipe moves on a touch
screen; moving replaces the address, so a reload or a link keeps the
slide. Every slide is rendered, its islands drawn, and hidden by the style
sheet; printing (or "Save as PDF") lays one slide to a page of the slide's
shape, or with "with notes" each slide on an A4 page above its notes.
`Body.slides` and `Body.followingLinks` render a deck as `Body.article`
renders a page. The demo's Docs has a "Presentations" page that is a deck,
prerendered as slides too, as is every page written as one.

## 0.1.0 - 2026-10-22

The interface the application talks to the wiki through, and the in-memory
backend the serverless demo runs on.

`Wiki.App.Backend` is the class `MonadWiki`: who is signed in (`session`, with
the user, their groups and the grants given to them, so that the client can run
`wiki-core`'s permission rules itself), spaces (`listSpaces` gives every space
the user may view with the ancestors of each, a whole tree; `getSpace` by path,
`createSpace`, `renameSpace`, `setSpacePublic`, `moveSpace`, `deleteSpace`),
pages (`listPages`, `getPage` by path, `createPage`, `savePage`, `movePage`,
`deletePage`) and attachments (`uploadAttachment` with the file's bytes,
`deleteAttachment`, `attachmentUrl`). What can go wrong is returned as a
`WikiError` (`NotFound`, `Forbidden`, `Invalid`, `Conflict`), never thrown.
`savePage` takes the `updatedAt` the edit started from and refuses with
`Conflict` to save over a newer version. Slugs are made from names and titles
when something is created and kept when it is renamed, so addresses last.
`HalogenM` is an instance, so a component's handlers call the methods
directly. Each write is checked by the rules of `wiki-core`'s
`Wiki.Core.Permission`, including its rules for writes (creating a space at
the top level takes `CreateSpaces`, under a parent `CreateSpaces` or
`AdministerSpace` there; moving one takes `AdministerSpace` on it and on its
new parent, or `CreateSpaces` for the top level), which the server will
enforce too; whoever creates a space administers it.

`Wiki.App.Backend.Mem` is `MemWiki`, the whole wiki in an `IORef` under any
base monad, deriving the DOM classes so that components run in it over
`BrowserDOM`. `switchUser` and `memUsers` let the demo show the wiki as each of
its users without passwords. Uploaded files are kept as bytes and served from
object URLs in the browser (`data:` URLs natively). `Wiki.App.Demo.demoState`
is the demo's content: users `admin`, `editor` and `reader`, a public `Blog`,
a private `Team` with `Team / Projects`, and a public `Docs` with a `Tour`
and pages that use every Markdown feature.

- Islands: `Wiki.App.Islands.component` draws a formula (KaTeX), a diagram
  (Mermaid) or highlighted code (highlight.js) into an element Halogen renders
  empty and holds by ref, and draws it again when its input changes. Its input
  is an `Island` (`MathInline`, `MathDisplay`, `Mermaid`, `CodeBlock`), so a
  page renders all its islands through one slot type. The component's monad
  needs `MonadIslands` (instances for `BrowserDOM`, natively `MemDOM`, and
  `ReaderT` over either) and `MonadUUID`. Natively an island holds its source
  as text, which is what the prerendered page shows until the program loads.
- The page loads `islands.js` and `islands.css`, which `web/bundle.sh` builds
  from npm's `katex`, `mermaid` and `highlight.js`; Mermaid is fetched only
  when the first diagram is drawn.
- A browser test suite, `wiki-app-browser-test`, runs in headless Chromium with
  that bundle loaded.

The shell and the pages, read: the serverless demo without its editor.

- `Wiki.App.Route` is the application's routes and their addresses, read and
  written by `haskell-halogen-router` by path under the page's `<base href>`:
  `/` (`Home`), `/s/<space path>/` (`Space`), `/s/<space path>/p/<page path>/`
  (`Page`), `/s/…/p/…/edit/` (`EditPage`, reserved for the editor),
  `/new-space/` and `/new-space/<space path>/` (`NewSpace`), and `Unknown` for
  any other address. Every address ends in a slash, as a directory on a static
  host does, and is read without it too; a slug that is `p` or `edit` is
  written `~p`, so that every route has an address of its own. `routeOfHref`
  reads a link's `href` back into a route, and `resolvePageLink` says where a
  link written in a page leads: a relative path from the page's parent, as a
  browser reads it, a path from `/` from the top of the wiki, a title for a
  wiki link.
- `Wiki.App.Shell` is the frame: a header with breadcrumbs, a place for the
  search box and the demo's user switcher, a sidebar with the tree of spaces
  (collapsible, the current space marked, a space the user may only pass
  through greyed out) and the current space's pages, and the content of the
  route. The views are components of their own: a space's pages and
  subspaces with the actions the rules allow (`Wiki.App.View.Space`: a new
  page, a new subspace, renaming, making public or private, moving,
  deleting), a page rendered from its Markdown with its islands, links and
  attachments (`Wiki.App.View.Page`: editing, renaming, moving, deleting),
  and the form for a new space (`Wiki.App.View.NewSpace`). Deleting asks
  first; what the backend refuses is shown in place. A link in a page that
  leads into the wiki is followed without loading a page, and one to a place
  on the page scrolls there.
- `Wiki.App.DemoUsers` is `MonadDemoUsers`, switching between the users of a
  wiki without passwords, with an instance for `MemWiki`; `MemWiki` also
  passes `MonadIslands` and `MonadUUID` through, so the application runs in
  `MemWiki BrowserDOM`.
- `Wiki.App.Static.renderRoute` renders the application natively for a route,
  once it has loaded what the route shows. `wiki-app-prerender` writes a page
  for every route the demo starts with and a `404.html`, under the base path
  in `HALOGEN_BASE_PATH`.
- `Wiki.App.Backend.Rules` is gone: its rules are `wiki-core`'s, in
  `Wiki.Core.Permission`.

The editor, with a live preview.

- `Wiki.App.View.Editor` edits a page's title and Markdown side by side with
  the page as it will read, rendered in the browser about 200 ms after the
  typing stops; formulas and diagrams the edit did not touch are not drawn
  again. Save (or Ctrl+S, Cmd+S) saves against the version the edit started
  from, so that a save over someone else's newer one is shown as a conflict
  in place, with the draft kept and a button to reload and lose it. Cancel
  goes back to the page. Tab indents by two spaces. On a narrow screen one
  pane shows at a time, with a switch between them.
- Files dropped onto the editor, or chosen with its *Attach files*, are
  uploaded to the page and referred to at the cursor (`![name](attachment:name)`
  for an image, a video or audio, `[name](attachment:name)` otherwise), and
  listed below with a button that inserts the reference again. A new page
  takes files once it has been saved.
- Leaving the editor with unsaved changes by a link or the back button asks
  first, in the page; a reload or closing the tab gets the browser's own
  warning.
- A new route, `NewPage`, at `/s/<space path>/new-page/` and
  `/s/<space path>/new-page/<parent page path>/`, opens the editor on a page
  not yet written; saving creates it. A space's *New page* and a page's new
  *New subpage* lead there. A slug that is `new-page` is written
  `~new-page`, as `p` and `edit` are.
- `Wiki.App.View.Body` renders a page's Markdown for both the page view and
  the editor's preview, so that the two agree.

Searching pages.

- `MonadWiki` has `searchPages`, which takes a `wiki-core` `SearchQuery` and
  gives the `SearchHit`s among the pages of the spaces the current user may
  view: of every such space, or of one space with or without its subspaces. A
  query with no words, or for a space that is not there, finds nothing rather
  than failing. `MemWiki` runs `wiki-core`'s `searchPlain` over the pages
  `listPages` would show; the server will answer the same query from an index.
- The shell's header has a search box (`Wiki.App.View.Search`): what is typed
  is searched for once typing pauses, in every space or in one chosen with the
  selector beside it (and its subspaces, unless unticked), and the best hits
  are listed under it with their space and a snippet, the matches marked. `/`
  anywhere outside a field focuses it; the arrows choose a hit, Enter opens it,
  or with none chosen the page of all results; Escape closes the list.
- A route for the page of all results, `Search`, at
  `/search/?q=…&space=…` (`&only` when a space's subspaces are left out),
  shown by `Wiki.App.View.SearchResults`, and prerendered with nothing searched
  for at `/search/`.

The demo, ready to show.

- The demo's *Tour* (`Wiki.App.Demo`) walks through what the demo shows: the
  three users and what each may do, public and private spaces, the Markdown
  guide, the editor, search, what is not there yet, and that edits are lost
  on reload. Its links to other spaces are absolute (`/blog`, `/docs`).
- Staying in the editor after its back-button question goes back to the
  editor's entry of the session history (`Wiki.App.Browser.historyEntry`
  numbers the entries in their state), rather than writing the editor's
  address over the entry left for, which had left two editor entries behind.
- A route in a space the reader may not see is titled *Private · Wiki*, or
  *Not found · Wiki* for a space that is not there, rather than just *Wiki*.

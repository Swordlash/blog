# Changelog

## Unreleased

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

# Changelog

## Unreleased

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

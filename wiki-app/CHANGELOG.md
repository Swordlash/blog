# Changelog

## Unreleased

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

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

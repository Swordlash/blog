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

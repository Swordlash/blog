# Plan: a Confluence-style wiki in Halogen

A wiki of spaces, subspaces and pages, written in Markdown, built on
[haskell-halogen](https://github.com/Swordlash/haskell-halogen). This document is the
working plan: the decisions taken, the phases, and the work packages each phase is cut
into. Each work package is delegated to one agent with the brief in its section; the
"Delegation protocol" at the end says how.

## What it has to do

- Spaces and subspaces (a tree), each holding a tree of pages.
- Pages are Markdown, the native format, with: Mermaid diagrams, LaTeX (inline and
  block), code (inline and fenced, with syntax highlighting), images, video and other
  attachments.
- Live preview rendered in the browser, not by a server.
- Users and groups; permissions on spaces for users or groups; global permissions
  (create spaces, administer); public (anonymous) read for a space, since this is also
  a blog.
- Deliverables in order: a spike that reaches an MVP as a serverless demo with no
  persistence (deployable as static files), then a server with persistence, then
  authentication and authorisation, then the rest.

## Decisions

Each of these is a recommendation with the reason; the first task of each phase
confirms it against reality and the plan is amended if it does not hold.

1. **Markdown engine in the browser: `commonmark-hs`, not pandoc.** The preview and the
   page view run in the wasm binary, so the parser must compile for wasm and stay
   small. `commonmark` + `commonmark-extensions` (John MacFarlane's, the same core
   pandoc's CommonMark reader is built on) are pure Haskell, support GFM tables, task
   lists, footnotes, strikethrough, autolinks, `$…$` / `$$…$$` math, attributes and
   fenced divs, and render through a typeclass, so the output can be Halogen `HTML`
   directly, with no HTML string and no `innerHTML`. Pandoc itself is kept for the
   server: import from other formats and export to PDF/DOCX in a later phase. (Pandoc
   does build for wasm, but it is tens of megabytes and would dominate the download;
   revisit only if commonmark's extensions prove insufficient.)
2. **Mermaid, KaTeX and highlighting are JavaScript libraries, bundled with esbuild and
   called through the JSFFI.** They render into *islands*: elements Halogen creates
   with a `RefLabel` and does not look inside, filled by a JS call from the
   component's initializer or a hook effect, re-run when the source text changes. The
   same pattern the material package uses for Material Components. Highlighting starts
   with highlight.js; `skylighting` (pure Haskell, pandoc's) is a possible later swap if
   consistency with server-side rendering matters.
3. **Depend on haskell-halogen through `source-repository-package` pinned to a commit.**
   Only `haskell-halogen-core` 0.9.0 is on Hackage; `hooks`, `router`, `th` and `jsbits`
   are not, and the app needs the router and `jsbits`. The `th` quoters (`hh`, `clay`)
   are available from the same pin and so far unused (WP1.5 chose plain combinators and
   one CSS file). The owner's rule: **use the quoters where they simplify the code, and
   for HTML they usually do**, so a package that writes a view of any size should reach
   for `hh` rather than nest combinators, and say so in its report; the first use adds
   `th` to `wiki-app`'s dependencies and native `alex` and `happy < 2.2` to the wasm job
   (a one-off `ghc-lib-parser` build on both backends, accepted). `clay` is optional:
   `web/style.css` stays the home of the stylesheet. The pin is bumped deliberately, in
   its own commit.
4. **Targets: native GHC and wasm.** Not the JavaScript backend: `th` does not build
   there and nothing here needs it. Native builds everything that can be built natively
   (domain, markdown, server, tests, the prerender), wasm builds the browser app.
5. **Toolchain pins follow haskell-halogen exactly**: GHC 9.14.1, cabal 3.16.1.0,
   `wasm32-wasi-ghc-9.14.1.20260731` from the ghc-wasm-meta revision haskell-halogen
   pins. Cloud sessions have no GHC installed, so Phase 0 adds a `SessionStart` hook that
   bootstraps the toolchain and warms the cabal store.
6. **The backend is an interface, with two implementations.** The app talks to a
   `MonadWiki`-style class (list spaces, read/write pages, attachments, permissions
   checks). Phase 1 implements it in the browser over an `IORef` with seeded demo
   content (the serverless demo); Phase 2 implements it over HTTP. Components never
   know which one they run on, as haskell-halogen's "don't hardcode a monad" rule
   requires.
7. **Server: servant over SQLite** (`sqlite-simple`), attachments on disk, one binary
   that also serves the wasm bundle. SQLite fits a personal wiki/blog and keeps
   deployment to one file plus one directory; the storage layer is behind its own
   interface so Postgres can come later if ever needed.
8. **Authentication: local accounts with argon2 passwords and cookie sessions first;
   OIDC (GitHub/Google) as a later work package.** Authorisation is enforced on the
   server; the client only uses the same rules to hide what the user cannot do.
9. **Permission model (Confluence-like, kept small):**
   - Global: `administer` (everything), `create-spaces`.
   - Per space: `view`, `edit`, `administer` (permissions, delete, move), granted to a
     user or a group. A subspace inherits its parent's grants and may add its own;
     a space may be `public`, which grants `view` to anonymous readers.
   - No page-level permissions in the first versions.
   - Pure functions over plain data in `wiki-core`, with native tests, shared by server
     and client.
11. **Administration is bootstrapped from the machine the server runs on.** `wiki-server`
    listens twice: on the public address, and on a loopback-only *admin listener*
    (default `127.0.0.1:8081`, never published by the `docker-compose.yml`) that serves
    the administration panel without a login: being able to reach the machine is the
    credential, as with a database's local socket. The panel marks a user as an
    administrator (the global `administer` permission of decision 9) or takes it away,
    and an administrator then has the same panel, and everything else, remotely over
    the public listener through an ordinary session. So there is no admin password in
    the configuration and no first-run token to lose: the first administrator is made
    from the console, and locked-out installations are recovered the same way. One
    Halogen component serves both listeners; only the server's idea of who is asking
    differs (the local operator on the admin listener, the session's user on the
    public one). The admin listener is not restricted beyond loopback: a remote
    operator reaches it through an SSH tunnel.
12. **The serverless demo persists in IndexedDB, through an API added to
    haskell-halogen.** haskell-halogen has Web Storage (`Web.Storage.Storage` over
    `MonadBrowserDOM`: synchronous, text, a few megabytes) and nothing for IndexedDB,
    which is what pages, versions and attachments (bytes, tens of megabytes) need:
    asynchronous, large, bytes kept as bytes. Rather than JavaScript of this
    repository's own, haskell-halogen gets a key-value store over IndexedDB in `core`,
    in the shape of `Web.Storage`: a class with the browser instance over the JSFFI,
    an in-memory instance natively for tests, lifted defaults for transformers, typed
    reads and writes through `StorageSerialize`, tested in hspec-halogen on both
    browser backends. `MemWiki` then writes through to it, record by record, and
    reloads from it at start, so the demo keeps its edits across reloads with no
    server. The same store is where an offline cache would go later.
13. **The editor is for people who do not know Markdown, and HTML in a page is
    rendered through an allowlist.** The textarea stays the source of truth (decision
    10), but a toolbar above it writes the Markdown for the author: a button wraps the
    selection or inserts a template, with keyboard shortcuts, and the editing commands
    are pure functions over text and a selection, tested natively, so the JavaScript
    only moves the selection in and out. Raw HTML in Markdown (inline and block) is
    rendered, not shown as text, by parsing it in Haskell and keeping only the elements
    and attributes of an allowlist, turned into Halogen `HTML` values; never
    `innerHTML`, so the rule that a page is always Halogen elements holds, and a script,
    an event handler attribute or a `javascript:` link written into a page by a user
    never runs. The allowlist is in `wiki-core`, shared by the preview, the prerender
    and the server's render.
10. **Markdown stays the source of truth.** The editor is a split view: a textarea with
    the Markdown on the left and the rendered page on the right, re-rendered on each
    change (debounced through `hooks`' debouncer). No WYSIWYG.

## Repository layout

```
cabal.project            native build: every package, -Werror for our own, tests: True
cabal-wasm.project       wasm build: imports cabal.project, pins the compiler
wiki-core/               domain types, Markdown → Halogen HTML, permission rules; native+wasm
wiki-api/                request/response types (aeson), shared by client and server
wiki-app/                the Halogen application (components, MonadWiki, in-memory backend)
wiki-server/             servant server, SQLite, attachments, serves wiki-app; native only
web/                     index.html, index.js, bundle.sh (esbuild: mermaid, katex, highlight.js), CSS
toolchain/               build/test scripts adapted from haskell-halogen's
docs/                    this plan, ADRs as decisions get revisited
.claude/                 SessionStart hook, settings
.github/workflows/       CI (native build + tests, wasm build + browser tests, Pages deploy of the demo)
```

Conventions are haskell-halogen's: fourmolu formatting, `-Wall -Wextra` in each
`.cabal`, `-Werror` only in `cabal.project`, Haddocks that explain why, polymorphic
components with class constraints, `RefLabel`s from `newRefLabel`, a `CHANGELOG.md`
per package once there is a release to speak of.

## Phases

### Phase 0: foundation

Goal: an empty Halogen app builds natively and for wasm, in CI and in a cloud session.

- **WP0.1 Scaffold.** `cabal.project` with `source-repository-package` pins for
  haskell-halogen (core, jsbits, hooks, router, th, hspec-halogen), the four packages
  above with placeholder modules, `web/` with `index.html` + `index.js` (from
  haskell-halogen's examples), `toolchain/` scripts adapted from haskell-halogen's
  (`build-wasm.sh`, `serve-wasm.sh`, `test-wasm.sh`, the test wrappers, the
  hspec-halogen builder), `package.json` with the same npm scripts, a `README.md`.
  A "hello" component mounts into `#app`. Acceptance: `npm run build-native`,
  `npm run test-native`, `npm run build-wasm` succeed; the page shows the component.
- **WP0.2 Cloud-session bootstrap.** A `SessionStart` hook (see the `session-start-hook`
  skill) installing ghcup, GHC 9.14.1, cabal 3.16.1.0, the ghc-wasm-meta toolchain at
  the pinned revision, Node 24, Chromium for Playwright, then `cabal build all --only-dependencies`
  for both projects; idempotent and quiet when already done. Acceptance: a fresh session
  can run the three commands above.
- **WP0.3 CI.** `build.yml` (native build + tests; wasm build + tests + the Chromium smoke
  test; a fourmolu check; caches for the cabal store and the wasm toolchain, copied from
  haskell-halogen's workflow). The repository is private, so there is no GitHub Pages
  deploy: the wasm job uploads the built page as a workflow artifact instead, and the
  demo of Phase 1 is run from that artifact or locally with `npm run serve-wasm`.
  Acceptance: green CI on the PR.

### Phase 1: spike to MVP, serverless demo

Goal: the full editing and reading experience, in the browser, over in-memory state
seeded with demo content, deployed to Pages. Reloading loses the edits; that is the
point of this phase.

- **WP1.1 Domain model (`wiki-core`).** `SpaceId`, `PageId`, `Space` (name, slug, parent,
  public flag), `Page` (title, slug, parent page, markdown body, attachments), `Attachment`
  (name, media type, size, a `Source`: URL now, blob id later), `User`, `Group`, grants.
  Slug rules and path resolution (`/space/sub/page`). Pure, with native tests.
- **WP1.2 Markdown to Halogen HTML.** A `commonmark` renderer instance producing
  `HH.HTML`: headings with ids, lists, tables, task lists, footnotes, links, images,
  inline code, fenced code with language, `$…$`/`$$…$$` math nodes, `mermaid` fences,
  and relative links to pages/attachments resolved through a callback. Video and other
  attachments through a small directive syntax (`![video](…)` by media type, or a
  fenced `attachment` div; the agent proposes and documents it). Native tests on the
  rendered tree (golden-ish, through `Halogen.Static`/`MemDOM`).
- **WP1.3 Islands.** `web/bundle.sh` bundling mermaid, KaTeX (+ its CSS and fonts) and
  highlight.js with esbuild into one script exposing a tiny API on `globalThis`;
  `wiki-app` FFI through `browserJS`; components (or hooks) `MathBlock`, `MathInline`,
  `Mermaid`, `CodeBlock` that render into a ref'd element and re-render when their text
  changes; inert natively so the prerender still works. hspec-halogen browser tests
  that each island fills its element.
- **WP1.4 `MonadWiki` and the in-memory backend.** The class (spaces, pages, attachments,
  current user, permission queries) and `MemWiki`: `ReaderT (IORef State) BrowserDOM`
  with demo content (a few spaces, a subspace, pages showing every Markdown feature,
  a sample image and video by URL). Attachments uploaded in the demo live as object
  URLs. Native tests of the backend's laws against the in-memory implementation (these
  become the contract the HTTP backend must also pass).
- **WP1.5 Shell and navigation.** Routes (`/`, `/s/<space path>`, `/s/<space path>/p/<page path>`,
  `/s/…/edit`, `/new-space`, …) through `haskell-halogen-router`; the frame with a
  space tree sidebar, page tree, breadcrumbs; create/rename/delete/move for spaces and
  pages; HTML and CSS through the `th` quoters where it reads better. Prerender of the
  shell per route for Pages (as haskell-halogen's `all` does).
- **WP1.6 Editor with live preview.** Split view, debounced re-render, attachment
  drag-and-drop/upload inserting the right Markdown, save/cancel, unsaved-changes
  guard. Browser tests: type Markdown, see the preview update, save, read back.
- **WP1.7 Demo polish and release of the MVP.** Seeded tour page, README saying how to run
  the demo (`npm run serve-wasm`, or the CI artifact), the Playwright smoke test grown
  into a gallery-style test of the built page (every route mounts, back/forward/reload
  work). Tag `v0.1.0-demo`.
- **WP1.8 Search bar.** A search box in the shell's header that searches pages by title
  and body, with a filter by space (one space and, by default, its subspaces; "all
  spaces" otherwise), showing results as title, space path and a snippet around the
  first match, each a link. It goes through a `searchPages :: SearchQuery -> m [SearchHit]`
  method of `MonadWiki`, so the UI does not change when the server takes over the work:
  `MemWiki` scans the pages the current user may view (case-insensitive substring match
  on the Markdown source, or the AST's plain text), ranked by title match first. Keyboard:
  focus with `/`, arrows and Enter to pick a result. Browser tests: typing narrows the
  results, the space filter excludes the other spaces, a result navigates.
- **WP1.9 Quoter pass.** After everything of Phase 1 is on `main`: one agent reads every
  view module of `wiki-app` (and `wiki-core`'s Markdown renderer) and decides, module by
  module, where `hh` makes the HTML simpler and where the combinators stay (dynamic trees
  such as the rendered Markdown, the search results, the space tree), and whether any of
  `web/style.css` reads better as `clay` next to its component. It rewrites what it chose,
  behaviour unchanged (the browser tests and the prerendered pages are the oracle: a
  prerender diff before and after must be empty or explained), adds `haskell-halogen-th`
  to `wiki-app` and `alex`/`happy < 2.2` to the wasm job, records the build-time cost of
  `ghc-lib-parser` on both backends, and reports the rule it applied so later packages
  follow it. It also adds the shell's footer, the first view written with `hh`: one line
  at the bottom of every page, "Built with haskell-halogen", with the name linking to
  https://github.com/Swordlash/haskell-halogen, styled quietly in `web/style.css`,
  present in the prerendered pages too (the smoke test checks it is there).
- **WP1.10 Hydrate the demo and take HH-2's fix.** One pin bump (its own commit) to
  haskell-halogen's `master` once the owner has merged haskell-halogen#50 (IndexedDB)
  and #51 (listener-side `preventDefault`); the bump must cover `jsbits` as well as
  `core` (`Value.hs` changed). Then two things. First, HH-2's API: wrap the form submits
  in `View/Space.hs`, `View/Page.hs`, `View/NewSpace.hs` and `View/Editor.hs` in
  `HE.preventingDefault` and drop their `H.liftEffect (preventDefault ev)`; move the
  editor's key decision (Ctrl+S, Tab) and the search box's (arrows, Enter, mousedown
  `KeepFocus`) into the handler functions as pure reads so the property can be wrapped;
  do the same for `followArticleClick` in `Page.hs` and `Preview.hs` (the `js_clicked_href`
  decision into a pure handler); for the editor's `DragOver`/`Dropped`, prevent in the
  listener and read `dataTransfer` files there too, since they are gone once the dispatch
  is over (report what that needs); remove the 300 ms `settleAfterSwitch` pause from the
  smoke test, which then guards the fix. Second, hydration: `7c78cfb` adds `hydrateUI`, with `runUI`'s signature, which
  adopts the HTML `Halogen.Static` prerendered instead of emptying `#app` and building it
  again: text and elements are kept, listeners attached, every mismatch repaired. Bump
  the `source-repository-package` pin to it (its own commit; `MonadDOM` gains
  `firstChild`, `nodeKind`, `nodeToElement` and takes `nextSibling` from
  `MonadBrowserDOM`, all with lifted defaults, so the app's transformer instances need
  nothing), mount with `hydrateUI` in `Main.hs`, and make sure the prerender and the
  program agree on the first render, which the mismatch repair would otherwise hide: the
  islands render as empty ref'd elements both ways, and the demo's seeded `MemWiki` is
  the same on both sides so no state needs embedding (`Halogen.Static.embed` and
  `readEmbedded` are for WP2.6). The smoke test does what haskell-halogen's test-gallery
  does: mark a prerendered node before `app.wasm` is let through and check it is still
  the one on the page after the program started and after navigating. Browser tests use
  the harness's new `htmlContainer`/`hydrate` for the shell and a page view. Report
  anything the repair had to fix, since each such case is HTML the server-rendered page
  of WP2.6 would also get wrong.
- **HH-1 IndexedDB key-value store, in haskell-halogen** (a pull request there, not
  here). In `core`, `Web.Storage.IndexedDB`: a `Database` descriptor (name, version,
  the object stores it has; stores are created on the upgrade event, so adding one is a
  version bump), and a class `MonadIndexedDB m` with `get`, `put`, `delete`, `keys`,
  `getAll` and `clear` on one store, keys `Text` and values `ByteString` (kept as a
  `Uint8Array`, never base64), plus `writeMany :: Database -> [(StoreName, Text, Maybe
  ByteString)] -> m ()` as one read-write transaction, so a backend can save a page and
  its attachments atomically. Typed `getItem`/`setItem` over `StorageSerialize`, as
  `Web.Storage.Storage` has. Instances: `BrowserDOM` for both browser backends (jsbits
  shared by both, `safe` imports on wasm so the thread waits on the request; a cached
  connection per database name), `MemDOM` natively over an `IORef`, and lifted defaults
  so `ReaderT`/`IdentityT` instances are empty. Errors (a blocked upgrade from another
  tab, quota exceeded, a version lower than the one on disk) surface as a documented
  exception or `Either`, the implementer's choice, reported. Tests: the native suite
  against `MemDOM`, hspec-halogen in Chromium on wasm and JS (write, read back, keys,
  clear, `writeMany` all-or-nothing, a value that is not text), and the CHANGELOG entry.
  haskell-halogen's conventions and its three-backend gate apply; the JavaScript backend
  is not installed in the blog's sessions, so that build is reported as not run and
  left to haskell-halogen's CI.
- **HH-2 Router links followed by the browser, in haskell-halogen.** Found by WP1.7: a
  router link clicked right after a user switch is sometimes followed by the browser (a
  full page load) instead of the router: 1 click in 20 made at once after the switch, none
  100 ms later, none of 126 without a switch. `Halogen.Router.follow` calls
  `preventDefault` from the action handler, and a handler is work for the tree's loop
  (AGENTS.md: one piece of work at a time, by whichever thread brings it while it is
  idle), so when the loop is busy with the render the switch caused, the handler runs as a
  later task and the browser has already navigated. Reproduce it in hspec-halogen (a
  component whose render is slow, a link clicked while it renders), then fix it where it
  belongs: `preventDefault` must run synchronously in the DOM callback, before the handler
  is queued, so either the router's link handler asks for it at the listener (an `HE`
  combinator or event-handler option that calls `preventDefault` in the callback and then
  dispatches), or core's listener does it for handlers that declare it. The implementer
  chooses, with the reason, and keeps `H.liftEffect`'s contract. Report what else in the
  examples relies on `preventDefault` from a handler (forms, keyboard shortcuts), since the
  same race applies.
- **WP1.11 Persist the demo.** After HH-1 and WP1.10: bump the pin to HH-1's commit (its
  own commit). `MemWiki` writes through to IndexedDB after every successful write, the
  records it changed in one `writeMany` (spaces, pages, attachments with their bytes,
  grants, each under its id in its own store), and `main` loads the records before
  mounting; an empty database is seeded with `demoState` and written out. A "reset the
  demo content" action in the user switcher clears the database and reseeds it. Object
  URLs for attachments are made when they are loaded, as now when uploaded. The
  prerendered page shows the seeded demo; when the store holds edits the first render
  differs and `hydrateUI` repairs it, which is accepted for the demo (a flash of the
  seeded content; the server of Phase 2 renders the real state). No cross-tab sync: the
  last writer of a record wins. Tests: native, `MemWiki` over `MemDOM` with the in-memory
  store (write, start a fresh `MemWiki` from the store, same state); browser, save a page
  in one mounted application, mount another from the same store, the page is there.
- **WP1.12 Editor toolbar.** A toolbar above the editor's textarea, written with `hh`:
  bold, italic, strikethrough, heading (cycles H1 to H3 and off), bulleted list,
  numbered list, task list, quote, inline code, code block (fenced, cursor on the
  language), link, image or attachment (opens WP1.6's upload), table (a three-column
  template), inline and display math, a Mermaid block, a horizontal rule. A command on a
  selection wraps it (`**text**`); on no selection inserts a placeholder and selects it
  (`**bold text**` with the words selected, so typing replaces them); on a selection
  already wrapped, unwraps it; a line command (lists, quote, heading) applies to every
  line the selection touches and toggles off when every line already has it. The commands
  are pure, `Wiki.Core.Markdown.Edit`: `apply :: Command -> Text -> Selection -> (Text,
  Selection)`, with native tests per command (wrap, unwrap, placeholder, multi-line,
  cursor position afterwards). The browser side reads the selection, applies, writes
  with `setRangeText` and dispatches `input`, so the browser's undo stack and the preview
  debounce both see one edit. Shortcuts: Ctrl/Cmd+B, I, K (link), E (code), Shift+7/8
  (lists); the title of each button names its shortcut; buttons are inline SVG icons with
  `aria-label`s and the toolbar wraps on a narrow screen. Browser tests: select a word,
  click bold, the textarea has `**word**` and the preview a `<strong>`; a list button on
  three lines; Ctrl+B with no selection leaves the placeholder selected.
- **WP1.13 HTML in pages.** Render `RawHtml` and `RawHtmlBlock` instead of showing them
  as text: `Wiki.Core.Markdown.Html` parses the HTML (`tagsoup`, pure Haskell, so it
  builds for wasm; `html-parse` if tagsoup's HTML5 handling falls short, reported) and
  keeps what an allowlist admits, as Halogen elements. Elements: formatting (`b`, `i`,
  `em`, `strong`, `u`, `s`, `sub`, `sup`, `mark`, `small`, `abbr`, `kbd`, `code`, `span`,
  `br`), structure (`div`, `p`, `details`, `summary`, `blockquote`, `pre`, `hr`, `ul`,
  `ol`, `li`, `dl`, `dt`, `dd`, the `table` family, `figure`, `figcaption`), media (`img`,
  `video`, `audio`, `source`). Attributes: `class`, `id`, `title`, `alt`, `width`,
  `height`, `colspan`, `rowspan`, `open`, `controls`, `poster`, `start`, `href` and `src`
  only with `http:`, `https:`, `mailto:` or a relative address (an attachment's);
  everything else dropped, so `script`, `style`, `iframe`, `on*` attributes, `javascript:`
  and `data:` URLs never reach the page. Unclosed tags close as a browser would; what
  CommonMark hands over as one raw block is parsed as one document, and Markdown inside an
  HTML block stays as CommonMark defines it (not parsed). Native tests: the allowlist on
  each element and attribute class, and the classics (`<script>`, `<img onerror>`,
  `<a href="javascript:…">`, `<svg onload>`, nesting that never closes). `docs/markdown.md`
  gains the HTML section with the list. Why an allowlist now, in a demo of one user: Phase 3
  brings other editors and the renderer is shared with the server (WP2.6), so the rule has
  to be in `wiki-core` from the first page that uses it.

### Phase 2: server and persistence

Goal: the same app, with pages that survive a reload, served by one binary.

- **WP2.1 API (`wiki-api`).** Servant API type and aeson types for everything
  `MonadWiki` does, versioned under `/api/v1`; attachments as multipart upload and
  streamed download; ETags/`If-Match` on page saves for conflict detection.
- **WP2.2 Storage.** SQLite schema (spaces, pages, page versions, attachments, users,
  groups, grants), migrations run at start, a storage interface with the same contract
  tests as `MemWiki` (WP1.4) run against a temporary database. Attachments on disk under
  a content hash.
- **WP2.3 Server.** The servant handlers, static serving of the wasm bundle with the
  prerendered shell, configuration (public and admin listen addresses, data dir, base
  path), structured logging, a `Dockerfile`, a `docker-compose.yml` for a one-command
  run that publishes the public port only. The admin listener (decision 11) exists
  from here: bound to loopback (the server refuses any other address unless
  `--admin-listen-unsafe` says so), serving status (version, data dir, counts) and the
  same wasm bundle under `/admin/`; the panel's content comes with Phase 3.
- **WP2.4 HTTP backend in the app.** `HttpWiki`: `MonadWiki` over `fetch` (JSFFI), with
  errors surfaced in the UI (not found, conflict, offline). The app picks `MemWiki` or
  `HttpWiki` at start from a flag in `index.html`, so Pages keeps serving the demo.
- **WP2.5 Page history.** Every save is a version; a history view with diff (a pure
  Markdown diff rendered in Halogen) and restore.
- **WP2.6 Server-side rendering with hydration.** Hydration itself is in since WP1.10;
  this is the server's side of it. `wiki-server` renders each route's page per request
  with `Halogen.Static` against the store, as the principal of the request (so a public
  space's page is complete before `app.wasm` loads, readable without JavaScript and
  crawlable, and a private one renders nothing it may not show), and writes the data the
  render used into the page with `Halogen.Static.embed` (a JSON script by id; every `<`
  escaped) so that `HttpWiki`'s `initialState`, through `readEmbedded`, starts from the
  same data instead of fetching it again and re-rendering through the empty state, which
  `hydrateUI` would otherwise do. Which data to embed (the page, the space tree, the
  user) and its encoding are this package's to decide; `wiki-api`'s types are the
  obvious ones. The serverless demo keeps its build-time prerender.
- **WP2.7 Server-side search.** `HttpWiki.searchPages` calls `/api/v1/search`, backed by
  SQLite FTS5 over title and body (a contentless or external-content table kept in step by
  triggers on page saves), with the same space filter and snippets from FTS5's `snippet()`,
  ranked by `bm25`. Hidden from users who may not view a space. The contract tests of WP1.4
  gain search cases that both backends pass.

### Phase 3: authentication and authorisation

Goal: who you are decides what you see and may do, on both sides.

- **WP3.1 Accounts and sessions.** Users with argon2id password hashes, login/logout,
  HttpOnly cookie sessions, CSRF protection, rate-limited login. No admin account from
  the configuration: administrators are made in WP3.3.
- **WP3.2 Authorisation.** The permission rules of `wiki-core` enforced in every handler
  (space view/edit/admin, global create-spaces/administer, public spaces for
  anonymous), with tests per rule. Anonymous read of public spaces so the site works
  as a blog. The principal of a request is either the session's user or, on the admin
  listener only, the *local operator*, who passes every check; a handler never knows
  which listener it serves, the principal does.
- **WP3.3 Administration panel on the admin listener.** The panel of decision 11, at
  `/admin/` on the loopback listener: the list of users with whether each is an
  administrator; mark and unmark a user as administrator (the global `administer`
  permission); create a user, reset a password, disable a login; the status page of
  WP2.3. A Halogen component over an `MonadAdmin`-style interface, implemented over
  the admin API (`/api/v1/admin/…`, served only to the local operator or an
  administrator) and in memory for the demo and the browser tests. Tests: the server's,
  that the admin API answers on the admin listener without a session and on the public
  listener only to an administrator's session, and refuses the loopback bind check;
  hspec-halogen for the component.
- **WP3.4 Administration UI for administrators, remotely.** The same panel served on
  the public listener to users with global `administer`, extended with what needs an
  authenticated user: groups and membership; per-space permissions (grant/revoke to
  user or group, toggle public); `create-spaces`. The UI hides what the current user
  cannot do, using the same pure rules. An administrator who demotes themself is
  refused in the UI and allowed by the server (the admin listener can always undo it).
- **WP3.5 OIDC login** (GitHub, Google) as an alternative to passwords; account linking.

### Phase 4: beyond the MVP

Candidates, ordered by likely value; each becomes a work package when it comes up.

- Export (PDF, DOCX, HTML) and import (Confluence XHTML/HTML, DOCX) with pandoc on the
  server.
- Comments on pages, labels, favourites, recently viewed.
- A table of contents panel and anchors; page templates; a "blog" view listing a
  space's pages by date with RSS.
- Skylighting instead of highlight.js if server-side rendering of code is wanted.

## Delegation protocol

Each work package goes to one agent (Opus 5.5, high effort), one at a time within a
phase unless two packages are independent (then in parallel, on separate branches).
The brief is written from this plan and contains:

1. The goal and the acceptance criteria of the work package, verbatim from above.
2. The files and docs to read first: this plan, haskell-halogen's `AGENTS.md`, and the
   haskell-halogen modules the package builds on (named explicitly, e.g.
   `router/src/Halogen/Router.hs`, `examples/all/Gallery.hs`, `hooks/.../Extra/Hooks.hs`).
3. What is already decided (the relevant items of "Decisions") so the agent does not
   re-open them, and what it is free to choose, which it must document in its report.
4. The verification gate before it reports done: `npm run build-native`,
   `npm run test-native`, `npm run build-wasm` (and `npm run test-wasm` once there are
   browser tests), fourmolu clean, no warnings on either backend.
5. The branch to commit on and the commit-message style (short imperative subject, body
   says why), one PR per work package, as a draft.

The agent reports back with: what it built, the decisions it took, what it could not
do and why, and what the next package should know. The plan is updated after each
package (decisions confirmed or amended, acceptance criteria met or carried over),
in the same PR.

## Open questions for the owner

These do not block Phase 0 or 1; defaults are stated so work can proceed.

- Hosting of the server (Phase 2): a VPS with Docker is assumed. A base path other than
  `/` is supported either way.
- Blog view: is the public face a plain Confluence-style space, or a dated post list
  (Phase 4 item)? Assumed: both, with the post list later.
- Attachment size limit and storage budget: assumed 50 MB per file, local disk.
- Admin listener: assumed a second TCP port on loopback (`127.0.0.1:8081`); a Unix
  socket with file permissions would be stricter on a shared machine and is a small
  change in WP2.3 if wanted.

## Progress

Amended by the planning session after each work package's report.

- **WP0.2 done** ([#2](https://github.com/Swordlash/blog/pull/2)). `toolchain/bootstrap.sh`
  installs the pinned toolchain idempotently; two `SessionStart` hooks (toolchain
  synchronously, cabal store in the background). Cold bootstrap: about 10 minutes. Not
  yet verified inside a fresh cloud session, only by hand with the same variables.
  Carried over: `fourmolu` is not installed by the bootstrap (GitHub release downloads are
  refused by the session proxy; `cabal install fourmolu-0.21.0.0` works but takes about
  15 minutes), so add it to the bootstrap, and the hspec-halogen executable's
  dependencies are not covered by `cabal build all --only-dependencies`, so the first
  `test-wasm` builds them.
- **WP0.1 done** ([#3](https://github.com/Swordlash/blog/pull/3), stacked on #2). The four
  packages build and test on both backends, `wiki-app` is prerendered into the page and
  mounts in Chromium (`npm run smoke-test`). Decision 3 confirmed: the pinned commit is
  `77444712fc605d0ed939feb9dbabbaad79b1db56`, nothing got in the way. Choices accepted:
  `license: NONE` in the `.cabal` files, the wasm reactor's `Main.hs` is a stub natively,
  `wiki-app-test` checks `Halogen.Static` output natively only. Carried over to WP0.3: CI's
  wasm job needs the host GHC too (prerender and the hspec-halogen executable); the deploy
  artefact is `dist-newstyle/wasm/public/app/`; the page uses relative URLs and ignores
  `HALOGEN_BASE_PATH` until WP1.5 adds the router and a `<base>`; the page imports
  `@bjorn3/browser_wasi_shim` from jsDelivr as haskell-halogen does. Carried over to
  WP1.3: `npm` did not run esbuild's postinstall script, check that `npx esbuild` works;
  `dev-test.sh` was left out until the first browser suite exists. Carried over to WP1.5:
  nothing depends on `th` yet, so its first use adds a long one-off `ghc-lib-parser`
  build on both backends.
- **Phase 1 started** with WP0.3, WP1.1, WP1.2 and WP1.3 in parallel, each in its own
  worktree and branch, since none depends on another; WP1.4 follows WP1.1, WP1.5 follows
  WP1.4, WP1.6 follows WP1.2, WP1.3 and WP1.5.
- **Owner's note (2026-10-22):** haskell-halogen is about to gain SSR with hydration; it is
  planned as WP2.6 rather than a Phase 4 item.
- **WP0.3 done except the run** ([#6](https://github.com/Swordlash/blog/pull/6)). `build.yml`
  with `native`, `wasm` (toolchain cached as haskell-halogen's, host GHC alongside, Node
  suites, browser suite, Chromium smoke test, `app` artifact) and `format` (fourmolu
  0.21.0.0 from its release); fourmolu added to the bootstrap with a Hackage fallback; a
  new `npm run format-check`. GitHub never started the jobs: "The job was not started
  because an Actions budget is preventing further use", which the owner fixes under
  Billing → Budgets. Carried over to the first real run: pin `FOURMOLU_SHA256` in the
  workflow and the bootstrap from the format job's log, confirm the asset name, record the
  cold run time. Carried over to WP1.5: add native `alex` and `happy < 2.2` to the wasm
  job when `th` is first used.
- **WP1.1 done** ([#7](https://github.com/Swordlash/blog/pull/7)). `Wiki.Core.{Id, Slug, Path,
  Space, Page, Attachment, User, Permission}`, 145 tests on both backends. Decision 9
  confirmed and sharpened: `public` is a `View` grant for everyone and inherits, so a
  subspace of a public space cannot be private (no denials); rules are pure functions over
  the chain of spaces from the root. `slugify` folds Latin letters, drops apostrophes, and
  gives `Nothing` for a title with no foldable letters. Found and handed to WP1.3:
  `build-wasm.sh` fails once on a fresh build directory at `cabal list-bin`.
- **WP1.2 done** ([#8](https://github.com/Swordlash/blog/pull/8)). `Wiki.Core.Markdown` (own
  AST from commonmark + GFM, math, wikilinks, fenced divs, attributes), rendered through an
  `Options` record; `docs/markdown.md` is the authors' guide. Decision 1 confirmed: both
  packages build on wasm (dependencies about 2.5 minutes native, 3.5 minutes wasm).
  Amendment accepted: each island callback takes an `IslandKey {source, occurrence}`, unique
  in a document, which WP1.6 uses as the slot index for island components. Syntax decided:
  `![caption](attachment:name)` embeds by media type, `[label](attachment:name)` downloads,
  external embeds by extension; raw HTML shown as text; `href` limited to http(s), mailto,
  tel, blob. Carried over to WP1.6: heading and footnote ids are unprefixed, so preview and
  page view on one screen need a prefix or a single rendered copy.
- **Rules decided for WP1.4** (added to Decision 9): a root space needs global
  `CreateSpaces`; a subspace `CreateSpaces` or `AdministerSpace` on the parent; moving a
  space needs `AdministerSpace` on it and the right to create at the destination; rename,
  delete and `public` need `AdministerSpace`; page and attachment writes need `Edit`.
  Attachments cross the backend interface as bytes; `MemWiki` is polymorphic in its base
  monad (`IO` in tests, `BrowserDOM` in the page) and has a demo-only `switchUser`.
- **Owner's note (2026-10-22):** a search bar for pages with a filter by space is wanted;
  planned as WP1.8 (client-side over `MonadWiki`) and WP2.7 (SQLite FTS5 behind the same
  method).
- **WP0.3b** ([#6](https://github.com/Swordlash/blog/pull/6)): the workflow runs on a
  self-hosted runner when the repository variable `CI_RUNS_ON` says so (the owner has one;
  hosted jobs are refused by the Actions budget), with the toolchain from
  `toolchain/bootstrap.sh` in the runner user's home and no cache steps; the README lists
  the Debian packages the runner needs. Still unverified on a real runner.
- **WP1.3 done** ([#10](https://github.com/Swordlash/blog/pull/10)). One parameterised
  island component behind a `MonadIslands` class (`BrowserDOM` draws, `MemDOM` writes the
  source for the prerender); `web/bundle.sh` bundles KaTeX and highlight.js (455 KiB,
  141 KiB gzip) and lazy-loads Mermaid on the first diagram; the first hspec-halogen
  browser suite runs in Chromium through `test-wasm.sh`. Decision 2 confirmed. Fixed on
  the way: `build-wasm.sh` on a fresh build directory, esbuild's postinstall approval.
  Carried over: cloud sessions preset `NODE_PATH`, which hides ghc-wasm-meta's `ws` from
  browser GHCi (`dev-test.sh` works around it; the bootstrap could too); non-ASCII in a
  jsbits file breaks the wasm build (worth an upstream report to haskell-halogen).
- **WP1.4 done** ([#11](https://github.com/Swordlash/blog/pull/11)). `MonadWiki` with
  `Either WikiError` results and lifting defaults, `MemWiki` polymorphic in its base monad,
  demo content with `admin`, `editor`, `reader`, 64 contract tests for the HTTP backend to
  reuse. Amendment accepted: `savePage` takes the `updatedAt` the edit started from and
  answers `Conflict` (WP2.1's `If-Match`). Creating a space grants its creator
  `AdministerSpace`; uploads replace by name and do not bump `updatedAt`.
- **WP1.5 done** ([#12](https://github.com/Swordlash/blog/pull/12)). Path routing with a
  hand-built codec (`~` escapes slugs that collide with route words, trailing slashes for
  static hosts, `Unknown` as the fallback), the shell with space tree, breadcrumbs, user
  switcher behind `MonadDemoUsers`, page view with islands as slots, create/rename/move/
  delete, a prerendered `index.html` per demo route plus `404.html`, 21 browser tests.
  The write rules moved into `Wiki.Core.Permission`. Decision: no `th` quoters in the app
  (plain combinators and `web/style.css`), so no `ghc-lib-parser` build. `app.wasm` grew
  to about 5.6 MB (1.3 MB brotli) with commonmark's Unicode tables; WP1.7 looks at it.
- **WP1.6 done** ([#13](https://github.com/Swordlash/blog/pull/13), stacked on #12). Editor
  at `/edit/`, a `NewPage` route, shared `View.Body` for page view and preview, a 200 ms
  forked debounce (not hooks' debouncer: the editor is a plain component; Decision 10
  amended), islands kept by `IslandKey` while typing, versioned saves with `Conflict` in
  place, uploads through `browserJS` with `attachmentReference` in `wiki-core`, a leave
  guard in the shell plus `beforeunload`. Uploads wait until a new page is saved.
- **WP1.8 done** ([#14](https://github.com/Swordlash/blog/pull/14), stacked on #12).
  `Wiki.Core.Search` (query, hit with marked snippets, matcher folding diacritics the way
  `slugify` does, every query word must match, titles rank first), `searchPages` on
  `MonadWiki` with contract cases, the header box with `/`, arrows, Enter, Escape, a space
  filter, and a `/search/` route with a `Bool` for "without subspaces". Found: a controlled
  input loses a keystroke when a render lands between the key and its handler, so inputs
  that take typing are uncontrolled; the editor is checked for the same race in the
  integration before WP1.7.
- **Integration and WP1.7 started:** #13 and #14 conflict in ten files; the integration
  merges `wp1.6-editor` into `wp1.8-search` and restacks #14 on #13, then WP1.7 branches
  from there. Merge order once CI runs: #6, #9, #10, #11, #12, #13, #14, then WP1.7 (#16).
- **Integration done, WP1.7 done** ([#16](https://github.com/Swordlash/blog/pull/16),
  stacked on #14, which now targets #13). The editor's controlled-input race was real:
  the preview's forked update re-rendered the editor and `HP.value` dropped keys (1 run
  in 3); fixed by making the title's `value` and the textarea's text the loaded content
  only, keyed by a load counter so a reload after a conflict makes fresh elements; a
  30 s browser test types against a long page. `textField` (rename, new space) is still
  controlled and does not race today; it must become uncontrolled with `HttpWiki`
  (WP2.4). WP1.7: the tour rewritten as a guided walk, README "What works" and "Running
  the demo", the smoke test grown into a gallery-style test (every prerendered page with
  `app.wasm` held back, one long walk through tour, spaces, editor, search, 14 history
  entries, the leave guard, a reload, `404.html`; dark and light schemes; a 390 px phone),
  no network needed; Stay no longer duplicates the editor's history entry (the shell
  numbers entries in `history.state`); private pages titled "Private · Wiki"; CHANGELOGs
  cut as 0.1.0. Tag `v0.1.0-demo` goes on the merge of #16. Bundle: `app.wasm` 5928 KiB
  (1385 KiB brotli); commonmark and its extensions are 44% of the code, `wasm-opt
  --converge`, `-O3`, `split-sections` and dropping emoji save nothing worth having, so
  the remaining options are a lighter Markdown parser or serving brotli; parked. No view
  added, so `hh` is still unused. New haskell-halogen defect, planned as HH-2: a router
  link clicked right after a user switch is sometimes followed by the browser. For Phase
  2: the shell reloads session, users, spaces and every page body after each change,
  so the API wants page summaries or the client a cache; `attachmentUrl` over HTTP is
  the download endpoint's address; `MonadDemoUsers` must become optional or be replaced.
- **Quoters, owner's rule:** use `hh` (and `clay`) wherever they simplify the code,
  which for HTML is usual; decision 3 amended. WP1.9, after the Phase 1 merges, is one
  agent's pass over the existing views deciding where `hh`/`clay` go and where not;
  until then a new view in WP1.7 uses `hh`, and later packages follow WP1.9's rule.
- **Hydration landed in haskell-halogen** (`7c78cfb`, after our pin `7744471`):
  `hydrateUI`, `Halogen.Static.embed` with `Halogen.IO.Util.readEmbedded`, hspec-halogen's
  `htmlContainer`/`hydrate`; its examples adopt the prerender. Planned as WP1.10 (pin bump
  and hydrating the demo, right after the quoter pass) and WP2.6 recut to the server's part:
  per-request render as the principal plus embedded data so the client starts from it.
- **Persistence of the demo in IndexedDB (owner's request):** decision 12. haskell-halogen
  has Web Storage only, so HH-1 adds `Web.Storage.IndexedDB` to its `core` (delegated now,
  independent of the Phase 1 merges) and WP1.11 makes `MemWiki` write through to it after
  WP1.10's pin bump.
- **Phase 1 merged, MVP demo released.** #6, #9, #10, #11, #12, #13, #14 and #16 are on
  `main` in that order, each after a green run on the self-hosted runner (about 4 minutes
  warm; the first run installed the toolchain in 22 minutes). Tag `v0.1.0-demo` belongs on
  the merge of #16 (`d62a857`); pushing a tag from the planning session is refused (HTTP
  403: its credentials push branches only), so the owner tags it:
  `git tag -a v0.1.0-demo d62a857 -m "The MVP demo" && git push origin v0.1.0-demo`. What remains of Phase 1 is the owner's additions: WP1.9, WP1.10,
  WP1.11, WP1.12, WP1.13, with HH-1 and HH-2 in haskell-halogen.
- **HH-1 done** ([haskell-halogen#50](https://github.com/Swordlash/haskell-halogen/pull/50),
  branch `indexeddb-store`, head `d2ce06d`; the owner merges there). `Web.Storage.IndexedDB`:
  `Database {name, version, stores}`, `MonadIndexedDB` with `get`, `put`, `delete`, `keys`,
  `getAll` (a `Map`), `clear`, `writeMany` (one transaction, all or nothing, resolves on
  commit) and `deleteDatabase`; typed `getItem`/`setItem`/`getAllItems` over
  `StorageSerialize`, `itemWrite`/`itemDeletion` for batches; `BrowserDOM` and `MemDOM`
  instances in the class's module (no orphans, no CPP), lifted defaults. Errors are the
  exception `IndexedDBError {database, failure}` with `Unavailable`, `UpgradeBlocked`,
  `VersionTooLow`, `StoreNotFound`, `QuotaExceeded`, `NotBytes`, `OtherFailure`. No handle:
  `Database` goes to every call, the first opens a cached connection per name, reopened on a
  version change, dropped on `versionchange`. Upgrades create missing stores and never
  delete one. FFI: unsafe bindings build an operation object, one awaited `halogen_idb_run`
  runs it and never rejects (the JS backend's awaited bindings may only return `()`), the
  outcome is read back; `jsbits` gains `toJSBytes`/`fromJSBytes` (bytes copied in one call,
  the only new CPP, in `Value.hs`). Tests: 14 native on `MemDOM`, 9 in Chromium (2 MB
  values, 20 concurrent writers, version bumps, a component finding an earlier mount's
  data), jsbits byte round trip. JS backend not built here. Found: an awaited import in a
  wasm *command* module (a `main` run by `wasi.start` under Node, like core's suite) hangs
  rather than fails, so `BrowserDOM` IndexedDB is never tested under Node. For WP1.11:
  one `Database {name = "wiki", version = 1, stores = ["spaces", "pages", "attachments",
  "grants"]}`, calls through `lift` from `HalogenM` or plain IO before mounting, never
  `H.liftEffect`; `MemDOM`'s store is process-global per database name (two `MemWiki`s on
  one name see each other, which is the reload test; distinct names isolate tests); the pin
  bump must cover `jsbits` as well as `core`; `VersionTooLow` on an old on-disk version is
  the demo's to handle (reset).
- **HH-2 done** ([haskell-halogen#51](https://github.com/Swordlash/haskell-halogen/pull/51),
  branch `router-prevent-default`, head `3347986`; the owner merges there). Cause,
  corrected: on wasm a render never yields midway; a trusted click's listener is a sync
  export that, while waiting for its own thread, runs whatever Haskell threads are
  runnable (the rest of the switch's work, a render), and when one takes the loop first
  the click's action is queued past the browser's default. Measured on the built demo
  (fresh page, tour, switch to admin, click at once): 25 of 60 loaded a page before,
  0 of 60 after. API: `HE.preventingDefault` and `HE.stoppingPropagation` wrap any
  handler property; the listener applies them while the event is dispatched, only when
  the handler makes an action; `Router.link` uses it by default; `follow` still prevents
  for a hand-made `Follow`; `H.liftEffect` unchanged. Breaking: `Prop`'s `Handler` gains
  `HandlerOptions` (`Core.withHandlerOptions`), `buildProp` needs `MonadIO`. Deterministic
  reproduction in hspec-halogen (`Busy`: a child created during a render clicks the link
  from `initialState`), 3 of 6 examples failed before, all pass after; one example states
  that an action-side `preventDefault` is too late. The th and hooks examples' forms
  fixed; hooks' `Extra.Actions.Events` helpers documented as action-side. Blog places with
  the same race listed under WP1.10. Possible core follow-up, not done: `continueAsync`
  running the listener's own thread before other runnable threads.
- **Footer (owner's request):** "Built with haskell-halogen" linking to the repository,
  on every page; added to WP1.9 as the first `hh` view.
- **Toolbar and HTML in pages (owner's request):** decision 13, WP1.12 (toolbar over pure
  editing commands) and WP1.13 (raw HTML rendered through an allowlist in `wiki-core`).
  WP1.13 touches `wiki-core` only and can run beside WP1.9; WP1.12 waits for WP1.9's rule
  on `hh`.
- **Administration from localhost planned (owner's request):** decision 11 adds a
  loopback-only admin listener to `wiki-server`, where a user is marked as administrator
  without a login; an administrator then has the panel remotely. WP2.3 gains the listener,
  Phase 3 is recut into WP3.1 to WP3.5 (the panel on the admin listener is WP3.3, the
  remote one WP3.4, OIDC moves to WP3.5), and WP3.1 no longer creates an admin from the
  configuration.

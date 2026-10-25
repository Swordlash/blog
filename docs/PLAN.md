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
    operator reaches it through an SSH tunnel. Addition (2026-10-25, Phase 3): the
    console also has `wiki-server users …` (list, add with a password read from a
    prompt or stdin, set a password, make or unmake an administrator, disable), run on
    the data directory like `backup`, so that the first administrator can be made before
    the panel exists and a locked-out installation recovered without a browser.
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
14. **Anyone who may read a page may read its source.** A page has a "View source"
    view on its own route (`…/p/<page path>/source`), which replaces the page with its
    Markdown and a "Back" link to the page, for every reader, signed in or not; it is
    gated by the permission to view the page, not to edit it. Until now the source was
    reachable only through the editor.
10. **Markdown stays the source of truth.** (Amended by WP1.20: the textarea becomes
    CodeMirror 6, still editing the Markdown itself.) The editor is a textarea with the Markdown;
    the rendered page is a preview of it, re-rendered on each change (debounced). No
    WYSIWYG. Amended by the owner after the MVP demo: the split view is no longer the
    default. The editor shows the source alone at every width; "Show preview" replaces
    the whole editing view with the rendered draft and a "Back to editing" button, a
    change of the editor's state, not a route (the draft is not in the URL). A "Side by
    side preview" checkbox, off by default, brings back the two panes on a wide screen.
15. **The server is hosted first on the owner's machine, as the demo is** (2026-10-24):
    `wiki-server` runs as a systemd user service bound to the Tailscale address, through
    `toolchain/deploy-local.sh --server`, with its data (the SQLite file and the attachments)
    in a directory of its own under the deployment. Migrations run when the server starts;
    before a deploy starts the new server, the database is copied aside with SQLite's own
    backup (`VACUUM INTO` or the online backup API, never `cp` of a live file) into
    `data/backups/<timestamp>.sqlite`, and the last few backups are kept. A `Dockerfile`
    and `docker-compose.yml` for a VPS are a package of their own (WP2.9), after the local
    variant works.
16. **The server searches with the pure matcher, not FTS5.** After WP1.23 `searchPlain`
    answers a query over 1000 pages in a few milliseconds, so the server stores each page's
    prepared text (`bodyText`'s output, or the fold) in a column kept in step by the save
    and runs the same `searchPlain` over the candidates the user may view. Both backends
    give identical hits, snippets and ranking, and the contract tests hold. FTS5 (different
    tokens, prefixes and diacritics) only if a wiki ever has tens of thousands of pages.
17. **Defaults confirmed** (the owner left them to the planning session): the admin listener
    is a loopback TCP port, `127.0.0.1:8081`; attachments are at most 50 MB each, on local
    disk under their content hash.
18. **Loading over HTTP.** A view that over `MemWiki` loads what it shows in `initialState`
    (so that the first render is the prerendered page) must not do so over `HttpWiki`,
    where that would hold the tree's loop on a fetch at every navigation. So: the first mount
    reads the data the server embedded in the page (`readEmbedded`, WP2.6), a client cache
    answers at once for data already seen, and otherwise a view renders `Loading` and
    fetches in `Initialize` (a fiber, as the plan's model requires). `MemWiki` keeps
    answering at once, so the demo's prerender and its zero-repair hydration are unchanged.
    (Resolves WP1.10's open decision.)
19. **Until Phase 3 brings sessions, the public listener has one trusted mode.**
    `wiki-server --trust-network` treats every request on the public listener as the
    administrator, for a private network such as the owner's Tailscale; it logs a loud
    warning at start and is refused with the listen address `0.0.0.0` or `::`. Without the
    flag the public listener serves an anonymous reader (public spaces only) and the admin
    listener the administrator, as decision 11 says. Phase 3 replaces the flag with
    accounts and sessions.
20. **Sessions are cookies that work over plain HTTP** (2026-10-25). The owner serves the
    wiki over http on a private network, so the session cookie is `HttpOnly` and
    `SameSite=Strict` always, `Secure` only when `wiki-server --secure-cookies` says the
    server is behind TLS (off by default: a `Secure` cookie is never sent over http and
    would make signing in silently impossible), with `Path` the base path. Writes are
    further guarded against cross-site requests by a same-origin check (`Sec-Fetch-Site`,
    or a header the browser's own `fetch` of this application sets) on every mutating
    request, login included, and login is rate-limited per login and address in memory.
    Session ids are random, kept hashed in the database, and end on sign-out, on the
    account being disabled, and after an idle time of the server's choosing.
21. **The writing assistant brings its own key; no widget, the providers' SDKs**
    (2026-10-25, checked against the providers' pages). Neither provider offers an
    embeddable assistant for a page like this: OpenAI's ChatKit is a chat UI for an agent
    one hosts on one's own server, and Anthropic has none. Neither lets a web application
    sign its users in with their subscription: Anthropic directs third-party tools to API
    keys and forbids routing them through a Claude subscription; OpenAI's "Sign in with
    ChatGPT" grants plan usage only to open-source, locally run tools through a loopback
    redirect, and identity sign-in only to selected partners. So the assistant is
    bring-your-own-key: the user pastes an API key per provider into the assistant's
    settings, kept in this browser's IndexedDB and sent only to that provider, and the
    browser calls the provider directly (Anthropic's API requires the
    `anthropic-dangerous-direct-browser-access: true` header for that, which its SDK sets
    with `dangerouslyAllowBrowser`; OpenAI's SDK has the same option). The providers'
    official JavaScript SDKs (`@anthropic-ai/sdk`, `openai`) are bundled by `web/bundle.sh`
    and called through globals, as the material package calls its libraries, which gives
    streaming, retries and typed errors without code of ours; the Haskell side sees one
    `MonadAssistant` with a provider, a model and a streaming completion. **Shelved by the
    owner the same day: not implemented while the only way is an API key the user pays
    for.** What was found, for when it is picked up again: the "log in with Claude" that
    third-party tools offered was Claude Code's own OAuth client reused (its client id and
    `claude-code-20250219` header); Anthropic rejected those tokens server-side from January
    2026 and wrote into its terms in February 2026 that OAuth tokens of Free, Pro and Max
    accounts may not be used in any other product, so the tools (OpenCode among them)
    removed it, and only the real Claude Code CLI may draw on a subscription. OpenAI's
    "Sign in with ChatGPT" does what the owner wants (browser login, no key, the user's Plus
    or Pro plan, per-application caps set in ChatGPT), but at launch only for open-source
    tools run locally, through a loopback redirect, with a waitlist for remotely hosted
    applications; a wiki hosted on a server would apply there. The assistant returns to the
    plan when a provider lets a web application use its user's subscription, or the owner
    accepts API billing.
22. **Whoever administers a space sees the wiki's users and groups** (2026-10-25, from
    WP3.4). `spaceAccess` gives a space's administrator the grants on the space and its
    ancestors and every user and group, so that they can choose whom to grant to, as
    Confluence does; a user who merely created a space is such an administrator. Accepted
    for a wiki of this size; disabled users may later be left out of the candidates, and
    a wiki with many users would want a search instead of the list.

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

- **WP0.4 Reuse an existing developer toolchain.** Make `toolchain/bootstrap.sh`
  recognise working installations before downloading replacements. Acceptance: reuse
  compatible Node and pinned native/wasm compilers from PATH; reuse a complete wasm
  sysroot with the pinned `.paladyn-rev` without deleting it; refuse to overwrite an
  unrecognised existing sysroot; correctly detect alex and happy versions; reuse the
  project's Playwright installation and cached Chromium where possible; provide a
  read-only `check` mode listing what would be reused or installed; document the
  behaviour and verify it with isolated shell regression tests.

- **WP0.5 Check toolchain readiness before npm build and serve.** Add a read-only,
  strict bootstrap readiness check shared by npm build/serve commands. Acceptance:
  npm commands automatically source an existing `~/.wiki-toolchain/env` before the
  check; missing tools or incompatible versions stop before compilation/server startup
  with explicit bootstrap instructions; direct readiness checks still inspect the
  caller's PATH without loading it; readiness checks never install or change files; add `build`/`serve`
  aliases and cover existing `build-native`, `build-wasm` and `serve-wasm`; check npm
  dependencies used by the commands; preserve automatic wasm environment loading
  inside wasm scripts; document and test both rejection and successful delegation.
  Follow-up acceptance: managed PATH entries take precedence even when already
  present later on PATH; old generated env files work without bootstrap reinstallation;
  Chromium cache detection uses the executable path reported by installed Playwright.

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
- **WP1.10 Hydrate the demo and take HH-2's fix.** Reordered after the MVP demo: it runs
  after WP1.12 and WP1.14 have merged, the pin bump done by WP1.12 and the editor's part
  done there too; what is left is the rest of this entry. One pin bump (its own commit) to
  haskell-halogen's `master` at `08f9093`, which has #50 (IndexedDB) and #51
  (listener-side `preventDefault`) merged; the bump covers every package of the stanza
  (`jsbits`' `Value.hs` changed too). Then two things. First, HH-2's API: wrap the form submits
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
- **HH-3 Small things in haskell-halogen for the quoters and after #51's review** (one PR
  there). It starts with the three non-blocking notes of #51's review, already written as a
  patch the planning session hands over: `Example.Busy`'s click through `browserJS` over
  `hspec-halogen/test/jsbits/busy.js` instead of per-backend CPP, `preventingDefault` and
  `stoppingPropagation` as record updates on `HandlerOptions`, and AGENTS.md saying that
  "at once" in `H.liftEffect` is inside the dispatch only when the loop was free. Then two
  things for the quoters. First, `th`'s `textItems`: a line break between two holes or statements with no
  tag between them becomes a single space text node, so `{{ a }}` and `{{ b }}` on separate
  lines render `" "` between them, which the README does not promise and JSX would drop;
  make a line break between holes (and between a hole and a line's edge) vanish as
  whitespace-only text does in JSX, with a test and a README line, and check the examples
  still render the same. Second, `Halogen.Router.linkProps` (or a name of its choosing)
  returning the `[IProp]` a router link needs (`href` and the preventing click handler
  `link` uses), so a link can be written `<a {{ Router.linkProps router route }}>` inside
  an `hh` quote; `link` is then `a` applied to it. The blog's shell switches to it at
  its next pin bump after HH-3 merges (WP1.11's), not in WP1.10, which does not wait for it.
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
  Recut after the MVP demo, the whole editor package now (one agent, since all of it
  is `View/Editor.hs`): it starts with the pin bump planned for WP1.10 (its own commit,
  haskell-halogen `08f9093`, every package of the stanza), because Ctrl+K and Ctrl+E
  have browser defaults and need `HE.preventingDefault` in the listener; the editor's own
  key handling (Ctrl+S, Tab, the new shortcuts) and its drag-and-drop move to the
  listener-side API in this package, so WP1.10 no longer touches the editor. The toolbar
  also gets an inline HTML command (decision 13, WP1.13's note: an inline tag pair in the
  line, or a whole block with no blank line in it; a small menu of the allowlisted tags
  that are useful, such as `mark`, `kbd`, `sup`, `sub`, `details`). Then the preview mode
  of decision 10 as amended: the source alone at every width by default; a "Show preview"
  button (on the toolbar's end, with a shortcut the agent picks) replaces the editing view
  with the rendered draft, a "Back to editing" button and Save/Cancel still reachable; the
  textarea stays mounted while hidden (it is uncontrolled: its text, selection, undo stack
  and scroll must survive the round trip); a "Side by side preview" checkbox, off by
  default, restores today's two panes on a wide screen, and on a narrow one it has no
  effect. The checkbox is remembered per browser in local storage (`Web.Storage`); the
  agent reports how the first render stays the same as the prerender. The present
  Markdown/Preview switch for narrow screens goes, as "Show preview" covers it. While
  the preview is hidden it need not follow every pause in the typing; showing it renders
  the current draft at once. Carry-overs: delete the dead `.raw-html` rule in
  `web/style.css`, and give `kbd`, `mark` and `details` a look of their own. Browser tests
  add: show preview, back, the typed text and the cursor are where they were; the
  checkbox on, both panes visible; Ctrl+K with no selection does not reach the browser.
- **WP1.14 View source.** Decision 14: a `PageSource` route (`…/p/<page path>/source`) in
  `Wiki.App.Route`'s codec, a view `View/Source.hs` in `hh` showing the page's title, a
  "Back" `Router.link` to the page (a link, not `history.back`, since a reader may arrive
  by the URL) and the Markdown in a `<pre>` (monospace, wrapping long lines, a "Copy"
  button through the clipboard), gated on the permission to view the page (the same
  errors as the page view: not found, forbidden, sign-in hint), never on `mayEdit`. A
  "View source" link among the page's actions for every reader, next to "Edit" for those
  who may edit. Prerender: the agent checks how `Prerender`/`Static` enumerate routes and
  whether the source routes are prerendered or left to the 404 fallback, and reports it.
  Tests: native, the route round-trips through the codec and the view renders through
  `Halogen.Static`; browser, an anonymous reader of a public space opens the source from
  the page and comes back, a reader without access sees the error; the smoke test visits a
  source route, back and reload.
- **WP1.15 TikZ drawings.** After WP1.11, the last package before the tag, at the owner's
  request: Mermaid lays diagrams out by itself and cannot draw a figure at given
  coordinates, a plot with labelled axes or a drawing for a proof. A fenced ` ```tikz `
  block (the body of a `tikzpicture`, or a whole `\begin{tikzpicture}…\end{tikzpicture}`)
  becomes an island like Mermaid's: empty in the program's render, its source as text in
  the prerender, drawn in the browser to SVG by TikZJax (TeX compiled to WebAssembly),
  which is loaded only when a page or the editor's preview has such a block, so no other
  page pays for its size. Libraries the build supports (`tikz-cd`, `pgfplots` and the like)
  are listed in `docs/markdown.md`; a block that fails to compile shows TeX's error under
  the source instead of a picture; the drawing follows the page's colours in dark mode if
  TikZJax's output allows it (the agent reports). The editor's toolbar gets a TikZ block
  command. TikZJax's files are served from the page's own origin, bundled or copied by
  `web/bundle.sh`, never from a CDN at run time. Tests: hspec-halogen, a block draws an
  `<svg>`, a broken block shows the error, a page without a block never fetches TikZJax;
  native, the renderer makes the island for both fence forms; smoke test, the guide's
  TikZ example is drawn. Measure and report the bytes added and the time to the first
  drawing. In Phase 2 the server may render TikZ with a real `latex` and `dvisvgm` to
  cached SVG (all packages, no wait), keeping TikZJax for the editor's preview.
- **WP1.16 Math macros and chemistry.** After WP1.15, before the tag, at the owner's
  request. KaTeX has no `\usepackage`: what it supports is fixed, so a wiki extends it with
  macros, in three layers, nearest wins. (1) Built-in, for every page: a plain TeX file in
  the repository (`web/src/katex-macros.tex`, one `\newcommand` per line: `\R`, `\N`,
  `\Z`, `\Q`, `\C`, `\abs`, `\norm`, `\set`, `\floor`, `\ceil` and the like), bundled
  as text by `web/bundle.sh` and handed to KaTeX by `islands.js`; Haskell does not read it
  (if the server ever must, `addDependentFile` as `browserJS` does). (2) A space's: a new
  optional field of `Space`, "math macros", a block of `\newcommand` lines edited in the
  space's settings by whoever may administer the space, inherited by its subspaces (a nearer
  space overrides); it goes into the zip export as an additive field, with no
  `formatVersion` bump (the first use of `docs/export.md`'s rules; the golden v1 archive
  must still import). (3) A page's: a `\newcommand` in one formula holds in every later
  formula of the same page, as in a LaTeX document, through one KaTeX `macros` object per
  rendered page (and per editor preview). A macro block that does not parse shows KaTeX's
  error where it is edited, never breaks the page. Also mhchem (`\ce{…}`, KaTeX's contrib
  extension) bundled with KaTeX. Islands keep rendering independently and hydration keeps
  zero repairs (macros change only what the islands draw, after the first render). Docs:
  `docs/markdown.md` lists what KaTeX supports and what it does not (`siunitx`, `physics`,
  text-mode LaTeX), the built-in macros, and the three layers. Tests: native, a space's
  macros inherited and overridden through the tree, export and import keep them, the
  golden v1 archive imports with none; browser, a built-in macro, a page macro used in a
  later formula, a space macro in a subspace's page, `\ce` renders.
- **WP1.17 Order of pages and subspaces.** After the tag, at the owner's request: today a
  space lists its subspaces and pages by name (`sortByName` in `Backend/Mem/State.hs`), so a
  blog written in order needs numbers in its titles, and then "11" comes before "2". A
  space gets an order for its subspaces and one for its pages (child pages of a page follow
  the page's space's page order), each one of: by name (as today, but in natural order, so
  that a run of digits compares as a number: "2" before "11"; the default, so nothing an
  existing space shows changes but that), by creation date, newest first or oldest first
  (`createdAt`, which every page and space already has or gets), and by hand. By hand, a
  space's children carry a position; whoever may edit the space moves one up or down (and
  to the top or bottom) from the space's view, and a new child goes last. The order is set
  in the space's settings by whoever may administer the space. New `Space` fields and a
  position on `Space` and `Page` are additive fields of the export (no `formatVersion`
  bump; an archive without them gets the defaults; the golden v1 archive still imports);
  new `MonadWiki` operations, implemented in `Mem` and in the backend contract tests, so
  that Phase 2's server has a contract to meet; a moved page keeps its address. The
  sidebar or tree, the space's page list and every other place that lists children use the
  same order (one function in `wiki-core`, tested). Tests: native, natural order (`a2` <
  `a11`, case, leading zeros, ties), each mode, positions after moves, insertions and
  deletions, export round trip and old archives; browser, an administrator switches a space
  to by date, newest first, and the list follows; an editor moves a page up and the order
  stays after a reload (IndexedDB); a reader sees the order and no move buttons.
- **WP1.18 Pages made first, Save and Save and close, drafts.** After the tag, at the
  owner's request; independent of WP1.17. (1) "New page" asks for the title (and the
  parent, as now) in a small form, then creates the page with an empty body and opens the
  editor on it, so a page has an id from the start and files can be attached at once: the
  "save the page first" state and its messages go. (2) The editor's buttons become "Save"
  (stays in the editor) and "Save and close" (saves and shows the page), plus "Cancel";
  Ctrl+S is "Save" and no longer leaves. A save that stays shows a small green "Saved"
  notice in a corner, which goes by itself after a few seconds and is announced to screen
  readers (`role="status"`); a failed save shows the error as now and stays. Conflict
  detection keeps working across several saves in one editing session (each save moves the
  version the next one is checked against). (3) Autosave to a draft: a few seconds after
  the last change the editor saves a draft of the title and body, private to its author and
  never shown to readers, through new `MonadWiki` operations (save, load, discard a draft of
  a page for the signed-in user), kept by `Mem` in its state and so in IndexedDB; in Phase 2
  the server keeps them. "Save" and "Save and close" clear the draft, "Cancel" asks whether
  to keep it. Opening the editor on a page with a draft newer than the page loads the draft,
  says so ("Restored your unsaved draft from …") with a button to discard it and go back to
  the saved page; a draft older than the page (someone saved since) is offered, not loaded.
  A quiet "Draft saved" next to the buttons shows the autosave worked; no popup for it.
  Drafts are not in the export (they are per user and per browser session's work; the agent
  may argue otherwise and report). A page created and left without a save stays, empty
  (the owner's choice); "Cancel" on it does not delete it. Tests: native, the draft
  operations and their permissions in the backend contract; browser, new page then attach a
  file before any save, Ctrl+S stays in the editor and shows "Saved", "Save and close"
  shows the page, a draft restored after a reload (IndexedDB) and discarded, the
  "loses no keystroke" test still passes; the smoke test makes a page through the new flow.
- **WP1.19 Colours from the toolbar.** After WP1.18 (the same file). A colour button on
  the editor's toolbar opens a small palette: about eight text colours and four or five
  highlight colours, each wrapping the selection in `<span class="c-…">…</span>` or
  `<mark class="h-…">…</mark>` (an existing class is replaced, not nested), and a "no
  colour" entry that removes the wrapper. The colours are classes, never `style`: the HTML
  allowlist keeps refusing `style` (WP1.13), and the palette is defined in `web/style.css`
  for the light and the dark theme, readable in both. `docs/markdown.md` lists the classes.
  The commands are pure, in `Wiki.Core.Markdown.Edit`, with native tests (wrap, replace,
  remove, a selection across a line break); a browser test colours a word and the preview
  shows it.
- **WP1.20 Formatting shown while typing (CodeMirror).** After WP1.18 and WP1.19, at the
  owner's request: the editor's text area shows the Markdown as it will look while it is
  typed: emphasis in italics and strong in bold with their markers kept but dimmed,
  headings larger by level with their `#` dimmed, inline code and fenced blocks in
  monospace on their own background (fenced code highlighted by language if it is cheap),
  links, `==mark==` if the renderer has it, quotes and lists set off. The textarea becomes
  CodeMirror 6 (`@codemirror/view`, `state`, `lang-markdown`, bundled by `web/bundle.sh`
  and loaded only by the editor, never by a reader's page; bytes reported), styled to look
  like today's editor: the same fonts, colours, padding, dark theme, no line numbers or
  other chrome. Everything else stays Halogen's and behaves as now: the toolbar and its
  commands (applied through CodeMirror's transactions, so the browser's undo still takes a
  command back), the shortcuts (Ctrl+B, Ctrl+K, Ctrl+S, Tab), drag and drop and pasted
  files, the preview modes, autosave, hydration (the prerendered editor shows the Markdown
  as text until CodeMirror takes over, without a jump) and the "loses no keystroke"
  guarantee, whose test may type through CodeMirror differently but must still check that no
  key is lost while the preview catches up. Browser tests: the formatting classes appear on
  `**bold**`, `_it_` and `# h`; every existing editor test passes, adapted only where it
  reached into the textarea directly.
- **WP1.21 Administration page.** At the owner's request: export, import and reset sit at
  the foot of the user switcher's menu (`demoControls` in `Shell.hs`), where nobody looks
  for them. A new route `Admin` (`/admin`) shows an "Administration" page, linked from the
  header ("Administration") for whoever holds the global `Administer` permission (the demo
  starts signed in as one). Its first section, "Wiki data", holds what the menu held: the
  note on whether this browser keeps the demo's changes, "Export the wiki", "Import a
  wiki…" and "Reset the demo content…", with the same confirmations in place and the same
  messages; the user menu keeps only switching users. Someone without `Administer` who
  arrives at `/admin` (or nobody signed in) sees that the page is for administrators, with
  the demo's hint that the user menu switches to one, never the controls. The page is laid
  out to take further sections (Phase 3's users and groups) without a redesign: a heading
  per section. The route goes through the codec (round trip tested) and is left to the 404
  fallback or prerendered as the agent finds simplest (reported); hydration keeps zero
  repairs on the prerendered routes. Tests: native, the route round trips; browser, an
  administrator opens the page from the header and exports (a download), imports with the
  confirmation, and resets; a reader sees no link and, at `/admin`, the refusal; the
  existing persistence tests move from the menu to the page; the smoke test visits
  `/admin`.
- **WP1.22 Pasted files, and "Mark".** Two small items from WP1.19's and WP1.20's reports.
  (1) A file pasted into the editor (an image copied from a screenshot tool or a browser, a
  file copied in a file manager, where the browser exposes it as `clipboardData.files`) is
  attached and referenced at the cursor exactly as a dropped one is (WP1.5, WP1.12: an
  image as `![name](attachment:name)`, anything else as a link), through a listener-side
  `paste` handler beside the drop's, which leaves a paste of plain text or HTML to the
  editor (CodeMirror turns pasted line endings to LF; nothing else changes). The paste
  reaches the component whether CodeMirror or the fallback textarea has the focus (WP1.20
  already tells CodeMirror to leave paste events with files alone). Browser tests: paste a
  PNG and the Markdown gets the image reference and the attachment list the file; paste
  text and it is inserted unchanged. (2) The HTML menu's `<mark>` entry, labelled
  "Highlight" (`htmlTagLabel Mark` in `Wiki.Core.Markdown.Edit`), is renamed "Mark", since
  the colour palette's highlight row (WP1.19) also says "Highlight"; its title and
  `aria-label`, `docs/markdown.md` and any test that finds it by label follow.
- **WP1.23 Search prepared once per page, not once per keystroke.** Prompted by
  haskell-halogen `2b54363` (native HTML built with a text builder, escaping without a
  `Text` per character; `core/bench/README.md` there has the method and the numbers). The
  blog's own HTML serialisation goes through halogen's `renderToText` (`Static.hs`,
  `fillMountPoint` in the prerender), so it gains from the pin bump with no change here.
  The blog code with the same shape, whole texts handled a character at a time and work
  repeated that could be done once, is the search: `searchPlain` is handed every page the
  user may view and, for each query (every keystroke, since each narrows the hits),
  reparses the page's Markdown (`bodyText`), folds it (`folded`: `T.unpack` to a list, a
  list cell and a `Seq` element per character) and only then looks for the words. (1)
  `wiki-core`: `Folded` built without per-character lists: the fold as one `Text`
  (`T.concatMap`, or a builder if it measures better) and `origins` kept only where a
  character folds to other than one character (`ß` to `ss`), so the common case indexes the
  original directly; `Folded` stays abstract to its users (`occurrences`, `marked`,
  `snippetOf`). Results unchanged: the search tests pass as they are, and QuickCheck
  properties check the new `folded` against the old definition (same fold, same origin of
  every folded character) over arbitrary Unicode text, multi-character folds included. (2)
  A page's text and its fold are made once per page version, not per query: `Mem` keeps
  them beside the page in memory (made on save and import, dropped with the page; never
  exported nor stored in IndexedDB, as derived data rebuilt on load), and `searchPlain`
  takes each candidate with its prepared `Folded` title and body, so the server of Phase 2
  can hand it an index's output the same way. (3) A Criterion benchmark in
  `wiki-core/bench` (native only, `-O2`, as haskell-halogen's: time and bytes allocated
  per run, a README with the command and a table) over a wiki of 1000 pages of a few KiB,
  one word and three words, before and after, with the numbers in the PR and the README.
  The search view and its browser tests are unchanged.
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
  a content hash. Amended 2026-10-24: the schema covers everything `MonadWiki` has gained
  since (drafts, positions and the two orders per space, `mathMacros`, `createdAt` on
  spaces) and a column of prepared search text per page (decision 16); migrations are
  numbered SQL files applied in order inside a transaction at start, with a
  `schema_version` table, and a backup step the deploy script calls (decision 15); the
  contract tests move where both `Mem` and the SQLite storage can run them (a test
  library, or a module of `wiki-core`), so one suite proves both. The principal of a call
  is a parameter (anonymous, a user, or the administrator), as Phase 3 will need.
- **WP2.3 Server.** The servant handlers, static serving of the wasm bundle with the
  prerendered shell, configuration (public and admin listen addresses, data dir, base
  path), structured logging, a `Dockerfile`, a `docker-compose.yml` for a one-command
  run that publishes the public port only. The admin listener (decision 11) exists
  from here: bound to loopback (the server refuses any other address unless
  `--admin-listen-unsafe` says so), serving status (version, data dir, counts) and the
  same wasm bundle under `/admin/`; the panel's content comes with Phase 3. Amended
  2026-10-24 (decisions 15, 19): the first deployment target is the owner's machine, so
  this package extends `toolchain/deploy-local.sh` with `--server`: it builds
  `wiki-server` natively at `-O2` and the wasm application in its `HttpWiki` mode, installs
  the binary, the bundle and a `data/` directory under the deployment, backs the database
  up before starting the new server, writes the unit with `--data`, `--listen
  <tailscale address>:<port>`, `--admin-listen 127.0.0.1:8081` and, when asked,
  `--trust-network`; `undeploy-local.sh` keeps `data/` unless told `--purge-data`. The
  `Dockerfile` and `docker-compose.yml` move to WP2.9.
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
  gain search cases that both backends pass. Amended 2026-10-24 by decision 16: no FTS5;
  `/api/v1/search` runs `searchPlain` over the prepared text stored per page (WP2.2), for
  the pages the principal may view, so the hits are the same as the demo's. Most of it is
  done by WP2.2 and WP2.3; this package is the endpoint, `HttpWiki.searchPages` and the
  shared search cases.
- **WP2.8 Bringing the demo's pages into the server.** At the owner's request
  (2026-10-24): what was written in the serverless demo must move to the server. On the
  administration page's "Wiki data" section, over `HttpWiki`, "Export the wiki" downloads
  the server's content as the same zip (`Wiki.Core.Export`), and "Import" takes a source:
  a zip export, or this browser's demo data (the IndexedDB database the demo left in this
  origin, read through the `Mem` backend's store and turned into an archive; offered only
  when such a database exists here, which it does when the server took the demo's address
  and port, since IndexedDB is per origin; otherwise the demo's own export is the way).
  Then a dialog "What to migrate" lists the source's spaces as a tree with their pages,
  each with a checkbox, all checked; against the server's content it marks what is new,
  what exists in both, and the conflicts. A space present on both sides (same path) is
  merged: its pages are added, its settings (public, math macros, orders) stay the
  server's unless the server's is empty. A page present on both sides (same path) is a
  conflict: a row with "keep the server's" or "take the imported" (the owner asked for
  this simple choice for now), "keep the server's" by default. Attachments follow their
  pages by content hash; positions follow the source's order after the server's. The
  server applies the import in one transaction through a two-step API (`/api/v1/import`:
  preview, which returns the plan with the conflicts, then apply with the choices) and
  answers with a summary, shown afterwards. The demo keeps its replace-everything import.
  Tests: native, the merge on archives (new space, merged space, page conflict either
  way, attachments by hash, orders) and the API round trip; browser, the dialog over a
  fake server; the smoke test imports the demo's export into a fresh server.
- **WP2.9 Docker.** A `Dockerfile` (multi-stage: the native build of `wiki-server` and the
  wasm build of the application, then a small runtime image with the binary, the bundle
  and a volume for `data/`) and a `docker-compose.yml` that publishes the public port only
  and keeps the admin listener on the container's loopback (reached with
  `docker compose exec`); the same `--trust-network` flag applies. After WP2.3 works on
  the owner's machine.

### Phase 3: authentication and authorisation

Goal: who you are decides what you see and may do, on both sides.

Recut on 2026-10-25, when the owner confirmed decisions 8, 9 and 11. Phase 2's server
already enforces the rules of `wiki-core` in every storage operation and serves public
spaces to an anonymous reader, so the WP3.2 of the first cut is mostly done; what is left
of it (the principal of a request from a session, tests per rule over HTTP) goes into
WP3.1. The administration panel is split by what needs a password: WP3.3 is the panel
with users, administrators, groups and membership, and needs nothing from WP3.1, so the
two run in parallel; the account forms (create a user with a password, reset one,
disable a login) and per-space permissions follow in WP3.4, on both.

- **WP3.1 Accounts and sessions.** Users with argon2id password hashes, login/logout,
  HttpOnly cookie sessions, CSRF protection, rate-limited login. The principal of a
  request is resolved per request, not per listener: on the public listener the
  session's user (nobody for no session, a stale one or a disabled user), or the
  administrator under `--trust-network`, which stays until the owner has made an
  administrator and signed in; on the admin listener the *local operator*, who passes
  every check; a handler never knows which listener it serves, the principal does. The
  server renders each page and embeds the session as that principal, with
  `Cache-Control: private` where the answer depends on the cookie. No admin account from
  the configuration: a user is made and made an administrator from the console
  (decision 11's addition: `wiki-server users …`) or, from WP3.3 on, the panel. The
  account operations of the admin API (create a user with a password, set a password,
  disable a login) and the sign-in and sign-out of the application over HTTP, through a
  capability class the demo has no instance of (as `MonadDemoUsers` is the demo's), the
  client cache cleared on both. Tests per rule over real HTTP: anonymous reads a public
  space and nothing else, a user writes where granted and gets 403 elsewhere, the
  administrator on the admin listener needs no cookie, a disabled user's session ends,
  the preloaded page of a signed-in user says so.
- **WP3.2 Authorisation.** Folded into WP3.1 (see above): the rules are enforced by
  `SqliteWiki` since WP2.1, with the contract tests of `wiki-app` running against it.
- **WP3.3 Administration panel.** The panel of decision 11, at `/admin/` on the
  loopback listener and on the public one to users holding the global `administer`:
  the list of users with whether each is an administrator; mark and unmark a user as
  administrator (the global `administer` permission); groups and their members (brought
  forward from WP3.4); the status page of WP2.3 and the data section of WP2.8 as they
  are. A Halogen component over an `MonadAdmin`-style interface, implemented over the
  admin API (`/api/v1/admin/…`, served only to the local operator or an administrator)
  and in memory for the demo and the browser tests. The UI hides what the current user
  cannot do, using the same pure rules; an administrator who demotes themself is refused
  in the UI and allowed by the server (the admin listener can always undo it). No
  migration, no passwords, no change to how a request's principal is found: those are
  WP3.1's. Tests: the server's, that the admin API answers on the admin listener without
  a session, on the public listener to the administrator (`--trust-network` until WP3.1
  lands; the session case is carried to WP3.4) and not to an anonymous reader; hspec-halogen
  for the component.
- **WP3.4 Accounts and permissions in the panel.** After WP3.1 and WP3.3: the account
  forms (create a user with a password, reset a password, disable and enable a login) over
  WP3.1's endpoints; per-space permissions (grant and revoke to a user or a group, toggle
  public) and the global `create-spaces`; the admin API refused to an anonymous reader and
  granted to an administrator's session, tested over HTTP. Once the owner has an
  administrator account, `--trust-network` is retired: the flag goes, the deploy script
  stops passing it, and the smoke test signs in instead.
- **WP3.5 Open or closed wiki** (the owner, 2026-10-25). A wiki-wide setting in the
  administration, kept on the server (a `settings` table, migration `0003`), with two
  values. *Open*: anyone may read the public spaces and create an account themself (a
  "Create account" form beside "Sign in": login, display name, password; rate-limited like
  the login; the new user holds no grant until given one, and may be given `create-spaces`
  by default through a second setting). *Closed*: accounts come only by invitation; an
  administrator makes an invitation for an e-mail address in the panel, the server mails a
  link with a single-use token that expires (SMTP from the configuration: host, port, user,
  password, sender; without SMTP the panel shows the link to copy), and the invited person
  chooses their login and password on that link; a visitor who is not signed in sees the
  sign-in prompt and nothing else (no spaces, no search, no pages, the server answers 401 or
  the sign-in page for every route, the API 401 for everything but the session), and public
  spaces are public only to signed-in users. The prerendered demo stays open. The setting
  is read per request from the storage (cached, invalidated on write), the pure rule that
  decides what an anonymous reader may see takes it as an argument and lives in
  `wiki-core`, and the UI hides the account form or the invitation list accordingly. Tests
  over HTTP for both modes and the switch between them, the invitation's whole flow, the
  expiry; browser tests for the forms. Comes before OIDC, which must obey the same rule (an
  OIDC sign-in by someone unknown creates an account in an open wiki and needs an
  invitation in a closed one).
- **WP3.6 OIDC login** (GitHub, Google, Apple, and any other OpenID Connect provider the
  configuration names) as an alternative to passwords; account linking; obeys WP3.5's
  setting. Confirmed by the owner on 2026-10-25, apart from the shelved assistant: this is
  how the wiki's users sign in, and has nothing to do with the providers' subscriptions.

### Phase 4: beyond the MVP

Candidates, ordered by likely value; each becomes a work package when it comes up.

- Export (PDF, DOCX, HTML) and import (Confluence XHTML/HTML, DOCX) with pandoc on the
  server.
- Comments on pages, labels, favourites, recently viewed.
- A table of contents panel and anchors; page templates; a "blog" view listing a
  space's pages by date with RSS.
- Skylighting instead of highlight.js if server-side rendering of code is wanted.
- **WP4.3 Pin bump and the browser's network through haskell-halogen** (the owner asked
  on 2026-10-25 what of his recent merges would help). Bump the pin to haskell-halogen's
  `master` (#60 to #65 and after: `Halogen.JSBits.Promise`, the `net` package, the window's
  emitters, a listener that finishes the loop's preempted work inside the dispatch). Then:
  `HttpWiki`'s transport over `Halogen.Net.Fetch` instead of `wiki-app/jsbits/fetch.js`
  and the `js_fetch` bindings (a killed wait aborts the request, so a navigation during a
  load leaves nothing running; `start`/`response` where a request must begin in an event's
  dispatch), `net` added to the `source-repository-package` subdirs; the window's emitters
  where they replace code of ours: `keyDown` for the slides' keys (WP4.2), `online` to say
  the server is unreachable before a request fails, `interval` for the draft's autosave,
  `visibility` if anything polls. Watch for the new export lists of
  `Web.UIEvent.KeyboardEvent` and `MouseEvent` (`key`, `code`, `clientX`, `clientY`)
  clashing with names of ours. After WP4.2 and WP3.5 are merged, so that neither rebuilds
  everything mid-flight. `Halogen.Net.EventSource`/`WebSocket` are for a later "someone
  else is editing this page" feature, not this package.
- **Presentations from a page** (the owner, 2026-10-25: "Beamer or something like it").
  Not Beamer itself, which needs a TeX installation and renders to PDF; a page becomes a
  slide deck in the browser: `---` (a thematic break) splits the slides, `::: notes` (the
  fenced divs the Markdown already has) holds speaker notes, the first heading of a slide is
  its title, and everything a page renders today renders on a slide (math, Mermaid, code,
  images, raw HTML through the allowlist). A "Present" view on the page's own route
  (`…/p/<page>/slides`) shows one slide at a time full-screen, with keyboard, touch and
  the browser's fullscreen API, a progress line and the notes in a second window or below;
  themes are CSS classes chosen in the page's front matter or the space's settings, with a
  Beamer-like default (title bar, footer with the page's title and the slide number). A
  print stylesheet lays one slide per page, so "Print to PDF" gives the deck as a file
  with no server work. All of it is our Halogen rendering and CSS, no reveal.js (which
  wants to own the DOM the way Halogen does). Later, if ever wanted: pandoc on the server
  turns the same Markdown into Beamer PDF or PPTX (the export item above), which needs TeX
  on the owner's machine. Independent of Phase 3; the owner's decision (2026-10-25): it
  runs as **WP4.2 Presentations** beside WP3.4, both started once WP3.1 and WP3.3 are
  merged.
- A writing assistant in the editor, backed by an LLM (Claude or ChatGPT), **in the
  browser, with the user's own account** (the owner, 2026-10-25: the user signs in to the
  provider, not the server): draft a page from an outline, rewrite or shorten the
  selection, suggest a title and a summary, fix a formula, a Mermaid or a TikZ block from
  the error shown, translate. Each suggestion lands as one edit through the toolbar's
  machinery (`Wiki.Core.Markdown.Edit`, `execCommand`), so the browser's undo takes it
  back, and streams into the preview first. The credential is the user's: first their own
  API key, pasted once into the assistant's settings and kept in this browser only
  (IndexedDB, never sent to the wiki server), with the browser calling the provider
  directly (Anthropic's API allows it with its direct-browser-access header; OpenAI's
  too); "sign in with Claude / ChatGPT" (OAuth) replaces the key where a provider opens
  it to third-party applications. One provider interface in the app, a provider chosen in
  the settings. So the server holds no key, keeps no budget and sees no prompt, and the
  serverless demo on Pages gets the assistant too; a space's administrators may still
  switch it off for their space (a private space's text leaves the wiki only where they
  said so). Needs nothing from Phase 3. **Shelved** (the owner, 2026-10-25, after the
  findings under decision 21): not worth building while the user has to pay API rates for
  it; revisited when "Sign in with ChatGPT" opens to web applications or Anthropic offers
  an equivalent.
- The wiki as a tool for an assistant, the other way round (also from 2026-10-25): an
  MCP server over the same API, so that Claude or ChatGPT can search, read and, where the
  session's user may, write pages, with the session's permissions and a log of what was
  done; sign-in through the Phase 3 accounts, so it comes after them too.

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

- Hosting of the server (Phase 2): answered 2026-10-24, decision 15: the owner's machine
  first, as the demo; Docker as WP2.9. A base path other than `/` is supported either way.
- Blog view: is the public face a plain Confluence-style space, or a dated post list
  (Phase 4 item)? Assumed: both, with the post list later.
- Attachment size limit and storage budget: assumed 50 MB per file, local disk.
- Admin listener: assumed a second TCP port on loopback (`127.0.0.1:8081`); a Unix
  socket with file permissions would be stricter on a shared machine and is a small
  change in WP2.3 if wanted.

## Progress

- **WP0.5 implemented locally.** `bootstrap.sh ready <target>` checks the caller's
  PATH, the pinned toolchain, effective wasm environment and command-specific npm
  packages without installing. Five npm build/serve entry points share one guard;
  they automatically source an existing `~/.wiki-toolchain/env` before checking,
  so the owner need not load it manually. The direct readiness command stays strict.
  Follow-up fixes managed PATH precedence even with old env files and uses
  Playwright's registry to locate Chromium. Eighteen isolated cases pass; the
  owner's installed toolchain reports `ready for serve-wasm` without reinstalling.
  failures name bootstrap, environment loading and `npm ci` as appropriate.
  Sixteen isolated regression cases pass, including blocked startup, successful
  delegation, argument forwarding and unloaded PATH. Real `npm run build` and
  `npm run serve` correctly stop before compilation on missing prerequisites.
  Full application verification remains pending the missing toolchain/npm packages.

- **WP0.4 implemented locally, full gate pending.** Bootstrap reuses compatible
  PATH tools and a complete sysroot carrying the pinned `.paladyn-rev`, refuses an
  unknown or incomplete existing sysroot, detects alex/happy with `--version`, and
  reuses matching project Playwright and Chromium caches. The read-only `check`
  passes on the owner's environment; nine isolated shell regression cases pass.
  Native/wasm build and test gate attempts started cold dependency builds but were
  stopped at time limits, so are not passed. Formatting was checked without edits
  with installed fourmolu 0.19.0.1, not the required 0.21.0.0; it reports existing
  layout differences. No bootstrap installation was run on the owner's account.

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
  the demo's to handle (reset). Codex's three findings on #50 were real and are fixed in
  `52e4abd`: `get` reads through a cursor so a present non-byte record is `NotBytes`, not
  `Nothing`; a `SecurityError` from `open`/`deleteDatabase` (sandboxed frame, opaque
  origin) is `Unavailable`; `MemDOM`'s `keys` sort by UTF-16 code units as the browser
  does (tested natively and in Chromium), while `getAll` is a `Map` in `Text` order on
  both. Head of #50 is now `52e4abd`.
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
  the same race listed under WP1.10. Possible core follow-up, owned by haskell-halogen's
  own plan, low priority: when the loop is busy, `enterWith` queues a listener's work and
  returns (`Queued`), so the listener returns before its action runs, and an action's
  focus, DOM read or `dataTransfer` read comes too late when a user's event lands before
  the glue's `postTask` resumes the runnable loop holder. The fix waits in the `Queued`
  branch while the loop makes progress and gives up when it stops (the holder may be under
  the listener on the JavaScript stack, as in `Busy`), wasm only; `HE.preventingDefault`
  stays the only guarantee for nested dispatch and the JavaScript backend.
- **WP1.13 done** ([#18](https://github.com/Swordlash/blog/pull/18), branch `wp1.13-html`).
  `Wiki.Core.Markdown.Html`: tagsoup (already in both stores) splits the tags and the module
  builds the tree with a browser's closing rules; `parseHtml` for a raw block, `parseFragments`
  with a `Context` (`Flow`, `Phrasing`, `PhrasingInLink`) for inline tags read together with
  the Markdown between them (`<mark>a *b*</mark>` works, since commonmark hands each tag over
  alone); `renderRawHtml` is the entry point from `Render`. The allowlist as implemented:
  formatting elements, `a` (the plan's list forgot it), structure (`div`, `p`, `details`,
  `summary`, `blockquote`, `pre`, `hr`, lists, `dl`, `figure`), the table family without
  `colgroup`/`col`, media (`img`, `video`, `audio`, `source`), and `h1` to `h6` (also
  missing from the plan's list; added in a follow-up with a browser's closing rules). The
  first CI run failed the editor's "loses no keystroke" browser test on a Playwright 5 s
  limit per typing call; the preview had not slowed (3.3 ms per render of the guide on
  both `main` and the branch), so the test now types in calls of 5 words. Dropped with content:
  `script`, `style`, `iframe`, `object`, `embed`, `template`, `noscript`, `svg`, `math`,
  `textarea`, `select` and a few more; anything else unlisted loses its tag and keeps its
  content. Attributes: `class`/`id`/`title` everywhere, the rest only where they mean
  something; numeric ones digits only; first of a duplicate wins as in a browser. URLs:
  `href` relative, `http`, `https`, `mailto`, `attachment`; `src`/`poster` the same without
  `mailto`; disguised `javascript:`/`data:` (entities, tabs, case, control characters)
  rejected, and a QuickCheck property over tag soup checks only allowlisted output comes out.
  Resolution goes through `Options.resolveLink` as for Markdown, a bare relative path is also
  tried as an attachment (first for `src`, second for `href`), attachments get `download`,
  external links `rel="noopener"`, an unresolved `href` becomes `link-unresolved`. Search
  text now includes raw blocks. Decision kept: one raw block is parsed alone, so a `<details>`
  with Markdown between blank lines inside does not wrap it (the guide says so); GitHub-like
  stitching is a small change if ever wanted. Carry-overs: `.raw-html` in `web/style.css` is
  dead (delete after WP1.9 merges); `kbd`, `mark`, `details` use the browser's default look
  (WP1.9 or WP1.12 may style them); a footnote reference inside a link still nests links
  (pre-existing). `app.wasm` grew to 6225 KiB (1460 KiB brotli), probably tagsoup's entity
  table; not measured against `main` exactly. For WP2.6: the server's `resolveLink` must
  treat `attachment:` and relative paths as the client does or hydration repairs the links;
  the tree is built to read back unchanged from `Halogen.Static` (tested). For WP1.12: an
  HTML command writes an inline tag pair in the line or a whole block with no blank line in it.
- **HH-2 merged** by the owner (haskell-halogen `08f9093`), reviewed as sound with three
  non-blocking notes, carried into HH-3. #18 (WP1.13) merged after its CI went green.
- **Paused by the owner** after that, to keep the session's budget: HH-3 and WP1.10 were
  started and stopped before they committed anything, so nothing of theirs exists on a
  branch; the patch with #51's review notes went with the session and is rewritten from
  the HH-3 text (a few lines each). `main` holds Phase 1 complete plus WP1.9 and WP1.13.
  Next, when work resumes: WP1.10 and HH-3 in parallel (briefs as written in their
  entries), then WP1.11 (needs HH-3's pin), WP1.12, then Phase 2.
- **WP1.9 done** ([#19](https://github.com/Swordlash/blog/pull/19), branch `wp1.9-quoters`;
  CI's first run installs th's build: `ghc-lib-parser` cold is 11 min native and 13.5 min
  wasm, measured alone under load). The rule for later packages: `hh` wherever the element
  names are known when the code is written (forms, dialogs, headers, empty and error states,
  island elements, trees whose per-node markup is fixed, recursing through a hole);
  combinators stay where the element is chosen by data (the Markdown renderer, the snippet's
  text-or-`mark`), for helpers that make their own element (`Router.link`, `HH.slot`), for
  what the quoter cannot say (`HH.keyed`, a textarea with text content) and for code that
  only assembles other functions' results. Module by module: `Shell`, `View/Common`
  (`errorView`, `pageTree`, `button`, `textField`, new `ariaBool`), `NewSpace`, `Space`,
  `Page`, `SearchResults`, `Preview`, `Islands`, `Editor` (except the keyed title and
  textarea), `Search` (box, dropdown, `hitContents`; `snippetHtml` stays), `Body` (`heading`,
  frame); `App`, `Static`, `Prerender` have no HTML. No CSS to `clay`. `wiki-app` depends on
  `haskell-halogen-th` and natively on `th-plugin` (`-fplugin=Halogen.TH.Plugin`, errors at
  the hole); `bootstrap.sh` installs `alex` 3.5.4.2 and `happy` 2.1.7 pinned into ghcup's
  bin, the hosted CI path in a step. Oracle: the prerender of 16 pages is byte-identical but
  for `<!---->` between a literal and an adjacent hole (two text nodes, which hydration
  wants), browser tests and smoke test unchanged, `app.wasm` 5927 KiB. The footer
  `<footer class="wiki-footer">Built with <a href=…>haskell-halogen</a></footer>` is the
  shell's last element, prerendered and in `404.html`, tested natively on 5 routes and in
  the smoke test. Things to know about `hh` (also for WP1.12): a line break between two
  holes with no tag between them becomes a `" "` text node (put them on one line, or one
  hole; HH-3 fixes it upstream); `value={{ x }}` and `value="{{ x }}"` both set the
  property, so an uncontrolled input takes `{{ attr "value" x }}`; a `Text` hole that is
  not plainly `Text` needs `:: Text`; `QuasiQuotes` goes on per module, never in the
  `.cabal` (a list comprehension `[x|x <- xs]` would parse as a quote); handlers come
  from the quoter's table (`onClick={{ … }}`) or as `{{ HE.handler … }}` among the
  attributes; `aria-label` and `title` are plain attributes; `<svg>` inside `hh` is SVG with
  `viewBox` and `d` as text. Suggested upstream `Router.linkProps` is HH-3.
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
- **Resumed** after the owner's #20 (bootstrap safeguards, readiness check, the Fable
  advisor in `.claude/settings.json`). New asks from the owner: the editor's preview as a
  view of its own instead of the split view (decision 10 amended), and a source view for
  every reader (decision 14, WP1.14). The editor package WP1.12 is recut to hold the
  toolbar, the inline HTML command, the preview mode and the pin bump to `08f9093`
  (shortcuts need the listener-side `preventDefault`). Order now: WP1.12, WP1.14 and HH-3
  in parallel; then the tag `v0.1.0-demo`, which the owner pushes once the editor and
  source view are on `main`; then WP1.10 (hydration and the remaining forms and links on
  the listener-side API) and WP1.11 (IndexedDB, after HH-3's pin).
- **WP1.14 done and merged** ([#22](https://github.com/Swordlash/blog/pull/22)).
  `PageSource` at `/s/<space>/p/<page>/source/`; `source` joins the reserved route words,
  so a page or space slugged `source` is written `~source` (the demo has none). The view
  loads the page as the page view does and shows the same errors; "View source" is among
  every reader's page actions, after "Edit" for an editor. Copy goes through
  `Wiki.App.Browser.copyText` (clipboard API, then `execCommand("copy")`, then the text left
  selected). The source routes are prerendered (9 more pages) so an arrival by the address
  is not the 404 page first. For later packages: a new route word goes into `reserved` in
  `Route.hs`; for WP1.10, a `<pre>` whose text starts with a newline loses it when the
  browser parses the prerender (the demo has none); the refused editor route is still
  titled "Edit · Wiki" rather than "Private · Wiki".
- **Test commands through the readiness gate** ([#23](https://github.com/Swordlash/blog/pull/23)):
  `npm run test-native`, `test-wasm`, `test` and `dev-test` load `~/.wiki-toolchain/env` and
  run `bootstrap.sh ready` as the build and serve commands do; `test-bootstrap.sh` covers them.
- **HH-3 done** ([haskell-halogen#53](https://github.com/Swordlash/haskell-halogen/pull/53),
  branch `quoter-fixes`, head `58c7e3e`, CI green on all three backends; the owner merges
  there). #51's three review notes; `th`'s text follows JSX's rule per piece of text (a tag,
  `{{ }}` or `{% %}` ends a text; a line break next to one of them is no text, a line break
  between words is one space, the edge spaces of a text's first and last line are kept);
  `Router.linkProps router onFollow route` gives the `href` and the preventing click
  handler as properties, and `link` is `HH.a (props <> linkProps …)`. For WP1.11's pin
  bump: switch the shell's `Router.link` holes to `<a … {{ Router.linkProps … }}>`, keep
  `linkProps` after any `href` or click handler on the element, drop WP1.9's one-line
  workaround for holes, and expect the prerender to move only where a word sits directly
  above a line starting with a hole (it loses its space, as in JSX; grep before bumping).
- **WP1.12 done** ([#24](https://github.com/Swordlash/blog/pull/24), branch `wp1.12-editor`).
  Pin at `08f9093` (nothing in the app broke; `hydrateUI` not adopted).
  `Wiki.Core.Markdown.Edit.apply` with 88 native tests; inline commands wrap per paragraph
  and unwrap when already wrapped, line commands toggle and convert list kinds, block
  commands fence or unfence by counting fences, italic is `_` so it composes with bold.
  The toolbar is `hh`, memoized, with an HTML menu (mark, kbd, sup, sub, u, small,
  details). Keys and drops are decided in the listener: a pure `browserJS` import read in
  `HE.handler'` under `HE.preventingDefault`, with what is read from the event forced
  there (`Just $! …`), since `dataTransfer` is emptied when the dispatch ends. Writes use
  `execCommand("insertText")`, not `setRangeText`, because only the former is undone by
  Ctrl+Z in Chromium (`setRangeText` stays as the fallback when the textarea cannot take
  focus). Preview mode: a class change, nothing unmounted, so the textarea keeps text,
  selection, undo and scroll (tested); the preview is mounted on first show and kept; it
  follows the typing only side by side; shortcut Ctrl/Cmd+Alt+P (Ctrl+Shift+P cannot be
  prevented in Firefox); the side-by-side choice is read in `Initialize`, after the first
  render, under `editor-side-by-side` in local storage. Costs to know: `MonadBrowserDOM` is
  now required by `Editor`, `Shell` and `Mount`, so the browser specs are picked on wasm
  only; the browser test page loads `web/style.css`; "loses no keystroke" takes 42 to 48 s
  (was 37 s) and failed once in seven runs on Playwright's 5 s per typing call, a CI risk.
  `app.wasm` 6515 KiB. For WP1.10: what is left on action-side `preventDefault` is the form
  submits in `Space`, `Page` and `NewSpace` and the search box's keys and mousedown; check
  that `hydrateUI` adopts the toolbar's `HH.memoized` thunk.
- **WP1.12 merged** (`40d2230`). With WP1.14 and the test commands, `main` at `40d2230` is
  a candidate tag point (editor toolbar, preview mode, view source); the owner then chose
  to tag after WP1.10 and WP1.11 instead. HH-3 merged in haskell-halogen as `a889566`. Next: WP1.10 (hydration, the
  remaining listener-side forms and keys) and WP1.11 (IndexedDB, pin to `a889566`,
  `linkProps`) in parallel, each told what the other touches.
- **CI and merging changed** ([#26](https://github.com/Swordlash/blog/pull/26),
  [#27](https://github.com/Swordlash/blog/pull/27)). Pull requests are rebased onto `main`
  and `main` is fast-forwarded to their head (`git push origin <head>:main`); a first job
  on pushes to `main`, `tested` (`toolchain/ci-already-tested.sh`), finds the head's
  passing pull request run and skips the build, so a merge costs about a minute of the one
  runner instead of eight. The Actions runs listing lagged 2.5 minutes once, so the gate
  asks twice, 30 seconds apart; a third try is the fix if it misses again. Markdown alone
  runs no CI. Plan-only changes go straight to `main`, and are pushed when no pull request
  is waiting to be fast-forwarded (else it needs another rebase and run). Pull requests
  are opened ready for review, not as drafts (AGENTS.md, `implementer.md`).
- **WP1.10 done and merged** ([#28](https://github.com/Swordlash/blog/pull/28), `aaf941e`).
  The space, page and new-space forms, the search box's keys and press, and links in a
  page's Markdown decide in the listener under `HE.preventingDefault`; no action-side
  `preventDefault` is left. `Main.hs` mounts with `hydrateUI`. The views load what they
  show in `initialState` (through `MonadWiki`, at once) so that the first render is the
  prerendered page; `Wiki.App.Static` has `prerenderedRoutes` and `startRoute Build|Adopt`.
  Repairs, checked natively (`Test.Hydrate`, all 24 routes), in the browser
  (`Test.Browser.Hydrate`, the toolbar's memoized thunk adopted) and on the built pages
  (the smoke test records every node before `app.wasm` runs): none, but the islands' source
  text (by design: the program renders islands empty and draws them) and the demo's
  uploaded `tree.png` (`data:` in the prerender, refused by `wiki-core`; `blob:` in the
  browser). The 300 ms pause in the smoke test is gone.
  **Open decision for WP2.4/WP2.6:** loading in `initialState` runs `MonadWiki` on the
  tree's loop; over `HttpWiki` that blocks the loop on a fetch at every navigation.
  `readEmbedded` covers the first mount; later mounts need a client cache answering at
  once, or `Loading` first with the fetch in `Initialize` (a repair only on a
  server-rendered page). WP2.6 must also resolve links and attachment URLs as the client
  does (the `data:`/`blob:` case is the example).
- **WP1.11 grows** at the owner's request: export and import of the whole demo state as
  one zip (`manifest.json` with `formatVersion`, a JSON file per kind of record,
  attachments as files), validated whole before an all-or-nothing replace. The record
  JSON has named fields, in one `wiki-core` module the Phase 2 server can import from too.
  Compatibility: unknown fields are ignored and optional ones defaulted (additive changes
  need no bump, and an older app reads a newer file); a breaking change bumps
  `formatVersion` and the reader migrates older versions step by step; a newer
  `formatVersion` is refused whole. A golden v1 archive in the tests must import forever.
  The tag `v0.1.0-demo` waits for WP1.11.
- **WP1.15 (TikZ) added to the MVP** by the owner, after WP1.11; the tag waits for both.
- **WP1.11 done and merged** ([#29](https://github.com/Swordlash/blog/pull/29), `8118eaa`;
  a follow-up, [#30](https://github.com/Swordlash/blog/pull/30), `50cc881`, merged after the
  first was fast-forwarded too early, before the agent's report: wait for the report). Pin at
  haskell-halogen `a889566`; the shell's links use `Router.linkProps`; prerender byte-identical
  across both. `openMemWiki` reads IndexedDB database `wiki` (version 1, seven stores:
  `users`, `groups`, `spaces`, `pages` with their attachments' records, `attachments` as raw
  bytes, `grants`, `meta` with the id counter and global grants), seeds an empty one, and
  `MemWiki` writes the difference after every write in one `writeMany` (a failed write is
  retried by the next). An undecodable record, `VersionTooLow` or a missing store deletes and
  reseeds; no IndexedDB or a blocked upgrade runs in memory and says so in the user menu.
  The demo starts signed in as admin (in `demoState`, so the prerender shows the admin's
  view); who is signed in is not kept across reloads. Export and import: `Wiki.Core.Export`
  (hand-written aeson codecs with named fields, used by the store too; `readArchive` checks
  the whole archive first; `migrations` empty at version 1; rules in `docs/export.md`;
  golden `wiki-app/test/data/wiki-export-v1.zip`); fflate in the browser (`zip-archive` needs
  C zlib, absent on wasm), `zip-archive` natively for the tests and the Phase 2 server.
  `app.wasm` 7007 KiB (1641 KiB brotli), up 492 KiB, mostly aeson. For Phase 2: the server
  imports through `readArchive` and assigns its own blob ids; `MonadDemoUsers` (six methods
  now) must become optional for `HttpWiki`; WP1.10's open decision on loading in
  `initialState` stands.
- **WP1.16 (math macros and mhchem) added to the MVP** by the owner, after WP1.15; the tag
  waits for it.
- **WP1.15 done and merged** ([#32](https://github.com/Swordlash/blog/pull/32), `f9a995a`).
  `@drgrice1/tikzjax` 1.0.0-beta24 copied by `web/bundle.sh` into `tikzjax/` and driven by
  our own `islands/tikz.js` over its worker's message protocol, loaded only for a page's
  first picture; a worker of ours refuses TeX any fetch off the page's origin. Pictures
  drawn one at a time, cached by their TeX (64), 30 s timeout with a worker restart; the SVG
  is copied through an allowlist (DOMPurify empties TikZJax's private-use glyphs), ids made
  unique, TeX's black rewritten to `currentColor` for dark mode. `Wiki.Core.Markdown.Tikz`
  (`tikzDocument`) builds the TeX: bare commands wrapped, a whole `tikzpicture`/`tikzcd`
  kept, `\usepackage`/`\usetikzlibrary` lines moved to the preamble, `tikz-cd`/`pgfplots`
  loaded when used, TeX's error line mapped back to the author's. First picture 3.0–3.8 s,
  6.4 MiB fetched (mostly `core.dump.gz`), later ones about 330 ms. Also: many more
  highlight.js languages and aliases (TIOBE top 20, shells; `m` is MATLAB; COBOL, Fish, Zig
  not available), listed in `docs/markdown.md`. **Owner's decisions:** TikZJax is
  GPL-3.0-or-later beside a proprietary repository; it is served unmodified as a separate
  worker with `tikzjax/NOTICE.txt`, which is fine while nothing is conveyed, and needs a
  decision before any public deployment (Phase 2 may render on the server instead); the
  Computer Modern fonts came with no licence file. **Found:** following a link while a
  Mermaid or TikZ island was drawing stalled navigation for 30 s and more when the island
  awaited the drawing in `lift`; worked around (drawings start and return, `islands.js`
  fills the element), reproduced by reverting `b65ad6e` and running the smoke test; the
  cause is probably haskell-halogen's (cancelling a fiber whose worker waits on a JSFFI
  promise may wait for the promise), handed to the owner for its agent there.
- **WP0.6 done and merged** ([#31](https://github.com/Swordlash/blog/pull/31), `e3e5dd5`), at
  the owner's request: `sh toolchain/deploy-local.sh --port N` builds with
  `cabal-wasm-opt.project` (`package *` at `-O2`, own build directory
  `dist-newstyle/wasm-opt`; `build-wasm.sh` takes `WASM_PROJECT`/`WASM_BUILDDIR`; first build
  about 24 min, `app.wasm` about 14 % larger than the default build), installs into
  `~/wiki-demo` (marked, never outside `~` without `--force`), serves it with a
  dependency-free `deploy-server.mjs` (types, precompressed siblings, `404.html`, TikZJax's
  `.gz` files raw) as a systemd user service, binds to the Tailscale address, and moves a
  ufw rule on `tailscale0` from the old port to the new one; `undeploy-local.sh` takes it
  down (`--purge` deletes the files). Tested against fakes and once for real here without
  systemd; the first real run is the owner's. `test-bootstrap.sh` and the deploy tests do
  not run in CI. The tag `v0.1.0-demo` waits for WP1.16 only.
- **The island hang's cause, found in haskell-halogen** (the owner's agent there): a
  component created in the same render as an island awaits its children's initializers
  before running its own Initialize and before flushing its pending queries and outputs, as
  purescript-halogen's `handleLifecycle` does; with the island's `Fill` waiting in `lift`
  for the drawing, queries to and outputs from that subtree waited too, and the next route
  change stalled behind them. Not hooks (`wiki-app` has none), not the subscription or the
  router (both launch a fiber per value). haskell-halogen changes core: a component counts as
  initialized once its Initialize reaches its first wait or ends. The blog takes it at its
  next pin bump; `b65ad6e`'s fire-and-forget drawing stays either way.
- **WP1.16 done and merged** ([#33](https://github.com/Swordlash/blog/pull/33), `84f791c`).
  Built-in macros in `web/src/katex-macros.tex` (checked by KaTeX at bundle time; `\N`, `\R`,
  `\Z`, `\set` are KaTeX's own and left out), `Space.mathMacros` set under
  `AdministerSpace` (`setSpaceMathMacros`), inherited farthest first, and a page's defining
  formulas carried to the formulas after them in document order, never by render order;
  KaTeX is the only TeX parser (no Haskell `\newcommand` parser), a nearer `\newcommand`
  replaces a farther one; mhchem (`\ce`, `\pu`). Export: `mathMacros` is the first additive
  field, no `formatVersion` bump, the golden v1 archive imports. For Phase 2: `HttpWiki`
  must deliver `mathMacros` for a chain's hidden ancestors too; the server stores blocks
  unchecked (no KaTeX there); an endpoint for `setSpaceMathMacros` is needed; KaTeX shows an
  unknown command in red without `.katex-error`, so "no error" tests check both.
- **Phase 1 complete.** `main` at `84f791c` is the tag point for `v0.1.0-demo`, which the
  owner pushes (the session's credentials cannot push tags). Next: Phase 2.
- **haskell-halogen pinned to `05b9160`** ([#34](https://github.com/Swordlash/blog/pull/34),
  `1202e4c`): the owner's merge of haskell-halogen#54, the initialization fix for the island
  hang above. Checked here before the merge: with the islands put back to wait in Initialize,
  the smoke test hangs on `a889566` and passes on the fix; the full gate on the fix is green.
  CI on #34 green. After a pin change, a local wasm build can keep the old pin
  (`cabal-wasm.project` only imports `cabal.project`); delete `dist-newstyle/wasm/cache` and
  the fetched `dist-newstyle/wasm/src/haskell-h_-*` first. CI is unaffected (fresh checkout).
- **haskell-halogen pinned to `00dfe13`** ([#35](https://github.com/Swordlash/blog/pull/35),
  `2644dc1`): haskell-halogen#55. `crypto.randomUUID` exists only in a secure context, so
  the demo served over plain HTTP (the owner's machine, reached over Tailscale by its
  address) failed at start; core now makes a version 4 UUID from `getRandomValues` there.
  `v0.1.0-demo` was already pushed (at `1202e4c`), so this one is `v0.1.1-demo`, at
  `2644dc1`, pushed by the owner. The editor's "loses no keystroke" test timed out once on
  #35 while the runner's machine was busy with another build, and passed when re-run: it
  types against a 5 s limit per call, so it stays sensitive to a loaded machine.
- **Wasm builds read the project afresh** ([#36](https://github.com/Swordlash/blog/pull/36),
  `7485ac5`). The owner's redeploy after #35 still served the old haskell-halogen: cabal
  keeps the parsed project in `<builddir>/cache/config` and missed the change to
  `cabal.project` under `cabal-wasm-opt.project`'s two levels of imports, so the fetched
  sources stayed at the old pin through repeated builds. Every wasm build script now deletes
  `cache/config` with `cache/compiler`. The prerender is built natively at the default
  optimisation even for the `-O2` deploy.
- **After the tag, the owner's requests** (2026-10-23): WP1.17 (order of pages and
  subspaces, sort modes per space), WP1.18 (pages made before the editor opens, "Save" and
  "Save and close", a "Saved" notice, autosave to a private draft; the owner chose the
  draft over saving the page itself), WP1.19 (a colour palette on the toolbar, classes
  only) and WP1.20 (formatting shown while typing, with CodeMirror 6 in place of the
  textarea; the owner chose it for headings that are larger, over a styled layer under
  the textarea, which would have kept every heading at the text's size). WP1.17 and WP1.18
  run in parallel; WP1.19 after WP1.18, WP1.20 after both.
- **WP1.17 done and merged** ([#37](https://github.com/Swordlash/blog/pull/37), `5e2a8d2`).
  `Wiki.Core.Order`: `ChildOrder` (by name in natural order, the default; newest first;
  oldest first; by hand), one total `orderSiblings` that every list goes through, and
  integer positions renumbered on every move (a new child goes last). Spaces gained
  `createdAt` (additive; an old archive's default is its earliest page's time), `position`,
  `subspaceOrder` and `pageOrder`; pages `position`. `MonadWiki`: `setSpaceOrder`
  (administer), `shiftSpace` and `shiftPage` (edit on the parent), in the contract;
  `listSpaces`/`listPages` now return tree order. Switching to by hand keeps the order shown.
  Top-level spaces are always by name (no parent to hold an order; a global setting is a
  possible follow-up). No drag and drop, buttons only. For Phase 2: the move buttons'
  ends are computed from the spaces a user can see, the backend reorders over all
  siblings, so a move can pass an invisible sibling; `parseSpace` needs a default
  `createdAt`; endpoints for the three operations.
- **WP1.21 added** (the owner could not find export and import in the user menu): an
  `/admin` page, linked from the header for administrators, whose first section holds the
  wiki's data controls; it runs beside WP1.18.
- **WP1.18 done and merged** ([#38](https://github.com/Swordlash/blog/pull/38), `e7cd07e`).
  "New page" is a form at the `NewPage` route ("Create and edit" makes an empty page and
  opens its editor; the editor's `Target` is gone, its slot is keyed by the path). "Save"
  (the form's submit, so Ctrl+S) stays and shows a `role="status"` "Saved" for 3 s; "Save
  and close" leaves; each save moves the version the next is checked against. Drafts:
  `Wiki.Core.Draft`, `getDraft`/`saveDraft`/`discardDraft` (edit on the space, own draft
  only), `savePage` discards the saver's draft, deleting a page or space discards its
  drafts; `Mem` keeps them in an IndexedDB store `drafts` (database version 2); not
  exported, an import clears them. Autosave 2 s after the edits go quiet (2–4 s after the
  last key). A draft whose base is the page's current version is loaded; one older is
  offered. Cancel asks in place when there is unsaved work or a draft. Known limits: keys
  typed in the last 2 s before closing the tab are not in the draft (a save on `pagehide`
  would close it); Back from the new page's editor returns to the form, which would make a
  second page. For WP1.20: CodeMirror must deliver the same `Typed`/`TypedTitle` actions
  and be rebuilt (or have its document replaced) when `loads` changes. Phase 2: draft
  endpoints, a table of their own, `savePage` discarding the draft in its transaction.
- **WP1.21 done and merged** ([#39](https://github.com/Swordlash/blog/pull/39), `bcfa588`).
  `Admin` route at `/admin/`, rendered by the shell (the panel state and the handlers were
  already there), not prerendered (the "kept in this browser" note differs natively),
  served by `404.html`. A header link for `Administer` holders; a refusal for anyone else;
  sections are `admin-section`s with their own `h2`, so Phase 3's users and groups go in
  beside "Wiki data". The user menu only switches users. A reset now says so. Phase 2: the
  export, import and reset handlers do not check `Administer` (only the page hides them),
  so the server must.
- **WP1.19 done and merged** ([#40](https://github.com/Swordlash/blog/pull/40), `81c954b`).
  `TextColour`/`Highlight (Maybe Colour)` in `Wiki.Core.Markdown.Edit`, writing
  `<span class="c-…">`/`<mark class="h-…">`; a "Colour" popover with a text row and a
  highlight row, each with its "none". The selected words end in exactly the colour picked:
  a wrapper of the same kind is replaced (split around the selection, neighbours of one
  colour merged), one tag pair per line (after list, quote and heading markers), other
  elements kept whole. Contrast at least 4.9:1 in both themes. The toolbar's menus are one
  `Maybe Menu`. For WP1.20: a colour command rewrites text outside the selection, so the
  CodeMirror adapter diffs old against new text, never replaces only the selected range.
  Open: the HTML menu's `<mark>` entry and the palette's row are both called "Highlight".
- **WP1.20 done and merged** ([#41](https://github.com/Swordlash/blog/pull/41), `614f28e`).
  CodeMirror 6 (`markdownLanguage` only: no lang-html, no list continuation) in an empty
  `.editor-cm` host Halogen never renders into, before the textarea Halogen still renders
  with the Markdown (so the prerender and native HTML are unchanged); once loaded
  (`islands/editor.js`, lazily, as TikZ: 296 KiB, 84 KiB brotli, editor routes only; the
  smoke test checks no reader's page fetches it) it takes the textarea's text, selection,
  focus and scroll in one task, and `.editor-cm:not(:empty) + .editor-text` hides the
  textarea. Changes reach Halogen as `Typed` through a `wiki-input` event; toolbar commands
  are one diffed transaction with `isolateHistory "full"`. Fenced code is highlighted with
  the page's highlight.js (no extra bytes); `==mark==` is not in the renderer, so not
  styled. Two older bugs fixed: notices among the form's children rebuilt the textarea by
  position (now an always-present `.editor-notices`), and a keyed element's replacement
  cleared its successor's ref, in haskell-halogen (`renderPass`'s `RefUpdate` does
  `M.alter (const el)`, so a removal reported after the creation clears it; worked around
  by holding the host, which is never replaced; to raise upstream). Pasting a file to
  attach it never existed; a small follow-up. The keystroke test now types in three-word
  calls.
- **The owner's requests of 2026-10-23 are all merged**: WP1.17, WP1.18, WP1.19, WP1.20,
  WP1.21.
- **WP1.22 added** (pasted files attach as dropped ones do; the HTML menu's `<mark>` entry
  is "Mark"), at the owner's word on WP1.19's and WP1.20's open points. The haskell-halogen
  ref bug WP1.20 found is raised upstream as an issue.
- **WP1.23 added.** The owner merged haskell-halogen `2b54363` (text-builder HTML) and asked
  for the like here. Findings: the blog serialises HTML only through halogen's
  `renderToText`, so the pin bump brings that gain; the one place of its own with the same
  shape is the search (a reparse and a per-character fold of every page on every keystroke),
  hence WP1.23. `Edit.replace`, `Html.htmlText`, `Link`, `Slug` and `Prerender.escape`
  concatenate strict `Text` too, but over one page or a few words, and stay. The pin bump
  waits for haskell-halogen#58 (the keyed-ref fix), rebased onto `2b54363`, so one bump
  brings both.
- **WP1.22 done and merged** ([#42](https://github.com/Swordlash/blog/pull/42), `be6a60e`). A
  `paste` listener beside the drop's, `HE.preventingDefault`, acting only on a paste with
  files (read in the listener, since a clipboard's data is gone after dispatch); files win
  over text in one paste; a paste without files is left to the editor. The HTML menu's
  `<mark>` entry is "Mark". Synthetic pastes only in the tests (no OS clipboard in the
  harness); the fallback textarea's paste is tested by dispatching on it.
- **WP1.23 done and merged** ([#43](https://github.com/Swordlash/blog/pull/43), `0b3e454`).
  `searchPlain` takes `Candidate`s (ids, paths, a `Searchable`: folded title and body);
  `Folded` keeps its origins as an `IntMap` of shifts, empty for text where every character
  folds to one; the fold slices ASCII runs of the original. `Mem` keeps a `Prepared` text
  per page (`version` = `updatedAt`, used only when it matches, else prepared again;
  computed lazily by the first search, never exported nor persisted). Over 1000 pages of
  ~3.5 KiB: one word 4.95 s / 16.45 GB allocated → 3.4 ms / 389 kB; three words 4.58 s →
  4.8 ms; the fold alone 451 ms / 2.1 GB → 44 ms / 12.7 MB. `wiki-core/bench` (Criterion,
  `-O2`, README with the table). Noted for later: the first search after a load or import
  parses every page once on the loop (seconds at 1000 pages on wasm; Phase 2's index removes
  it); the commonmark parse is now the search's main cost at ~1 ms and 4 MB per KiB, which
  the editor's preview also pays on every change, a candidate for its own look; the
  benchmark is not built by CI (`cabal.project` has `tests: True`, not benchmarks), so it
  can break unnoticed, a CI step would keep it honest. Phase 2: the index stores
  `bodyText`'s output or the fold, never reparses.
- **haskell-halogen pinned to `f077e82`** ([#44](https://github.com/Swordlash/blog/pull/44),
  `d3a0ed4`): #58 (a keyed element's successor keeps its ref; the editor's workaround of
  holding the never-keyed host stays, as the simpler design) and #57 (native HTML built with
  a text builder: the prerender serialises each page once). A further fix is open upstream,
  haskell-halogen#59 (a patched element's `ref` kept in step with its prop: a changed label
  or a dropped prop updates the driver's map), to be taken at the next bump.
- **haskell-halogen pinned to `f41907a`** ([#45](https://github.com/Swordlash/blog/pull/45),
  `1b239db`): haskell-halogen#59, a patched element's `ref` kept in step with its prop. The
  blog and haskell-halogen's `master` are level again; no pull request is open.
- **Phase 2 starts** (2026-10-24). The owner's word: the server is hosted on their
  machine through the deploy script, with migrations and a database backup; a Dockerfile
  separately; the administrator keeps export and import, and can bring the demo's pages
  (from this browser's IndexedDB or from a zip) into the server through a "what to
  migrate" dialog, merging spaces and choosing old or new per conflicting page. The rest
  was left to the planning session: decisions 15 to 19 (local hosting and backups, the
  pure matcher instead of FTS5, the loopback admin port and the 50 MB attachment limit,
  loading over HTTP, the `--trust-network` mode until Phase 3). WP2.8 (the migration) and
  WP2.9 (Docker) added; WP2.2, WP2.3 and WP2.7 amended. Order: WP2.1 and WP2.2 in
  parallel, then WP2.3, WP2.4, then WP2.8 and WP2.6, WP2.7, WP2.9, WP2.5.
- **WP2.2 done and merged** ([#46](https://github.com/Swordlash/blog/pull/46), `fc8fe01`).
  `SqliteWiki` in `wiki-server/src/Wiki/Server/Storage*.hs`: one operation, one
  transaction on one WAL connection, the same `wiki-core` rules as `Mem` in the same error
  order; the principal per run, `Who = Anonymous | AsUser UserId | Administrator`.
  Schema `migrations/0001-initial.sql` (users, groups, grants, spaces with orders and
  positions, pages with `search_text`, `page_versions` a row per save, attachments by
  sha256 on disk, drafts, `schema_version`), embedded and applied in one transaction at
  open, a newer schema refused. `wiki-server backup --data DIR [--keep N]` by `VACUUM
  INTO`; attachment files are collected only when neither the database nor a kept backup
  names them. The contract is a native sublibrary `wiki-app:contract` with an `around`
  fixture, run by `Mem`, `Persist` and SQLite (120 server tests). Choices: the
  administrator has no `users` row and writes drafts and versions as `~administrator`
  (refusing would show the editor's autosave error under `--trust-network`); search text
  is `bodyText` written in the save's transaction and folded per query; times as ISO 8601
  text with the full fraction; `importArchive` fills an empty storage only (the merge is
  WP2.8). For WP2.3: `withStorage`, `runSqliteWiki storage who`, `attachmentFile`,
  `Config.attachmentAddress`; the deploy runs `backup` before the new binary starts.
- **WP2.1 done and merged** ([#47](https://github.com/Swordlash/blog/pull/47), `68cdd3d`).
  `wiki-api`: servant `NamedRoutes`, one record per resource (`SpacesApi`, `PagesApi`,
  `AttachmentsApi`, `ArchiveApi`) under `api/v1`, relative to the page's `<base href>`;
  servant 0.20.3 builds on wasm, so the type is shared. `Wiki.Api.Links` (`links.spaces.rename
  sid`, `attachmentUrl`, `searchUrl`). ETag = `PageVersion updatedAt` as quoted ISO 8601 with
  the full fraction, sent as `If-Match`; mismatch 409, missing or weak 400. Errors are an
  `ApiError` JSON body mirroring `WikiError`. Attachments download through `RawM` at
  `attachments/<id>/<name>` (media type, streaming, `Range`). Import is stateless: the
  archive goes with both `import/preview` (`ImportPlan`: spaces new or merged, pages with
  `PageConflict`) and `import/apply` (`ImportChoices`: skips and `KeepServer`/`TakeImported`
  per conflict; `ImportSummary`), matched by path. `wiki-core` gained `http-api-data`
  instances for ids and `Slug`, and `Draft`'s aeson instances; `cabal.project` three
  `allow-newer` entries. Tests: `wiki-api-test` (46, both backends), `wiki-api-server-test`
  (51, native: golden JSON, `HasServer` for every endpoint). `docs/api.md` is the table. For
  WP2.3: use `Links.attachmentUrl` as the storage's `attachmentAddress`, `ErrorFormatters`
  in the `Context` so servant's own errors are `ApiError`, `MultipartOptions` with the 50 MB
  limit, `<base href>` on every served page. For WP2.4: `wiki-app` does not depend on
  `wiki-api` yet; watch `app.wasm`'s size when it does.
- **WP2.3 done and merged** ([#48](https://github.com/Swordlash/blog/pull/48), `75f24e0`).
  `wiki-server serve` (default; `backup`, `--version`): two Warp servers in one process over
  one storage, sockets bound before either starts; the public listener anonymous, or the
  administrator with `--trust-network` (loud warning, refused on `0.0.0.0`/`::`); the admin
  listener on loopback at `/admin/` (the bundle with its `<base href>` rewritten at serve
  time, a 302 from the public base to `/admin/…` as a workaround WP2.6 should remove);
  every refusal an `ApiError` (handlers, routing, 413, 405/415); 50 MB attachments and
  `--max-import-size` (512 MiB) as two servant applications with different
  `MultipartOptions`; export/import need `Administer`; the merge is server-side in
  `Wiki.Server.Import` (`matchArchive`/`toPlan` pure; merged space keeps the server's
  settings, math macros excepted when empty; `TakeImported` sets `updatedAt` so an open
  editor gets a 409); `GET api/v1/admin/status` (new `AdminApi`); static serving as
  `deploy-server.mjs` did, its cases now run against the real server; downloads with
  `Range`, `nosniff`, a sandboxing CSP, inline only for images, video, audio and text.
  logfmt logging without query strings; SIGTERM/SIGINT close the sockets, 10 s for
  in-flight requests; search `limit` clamped to [0, 200]. Deploy: `deploy-local.sh
  --server|--static`, `--admin-port`, `--trust-network`; layout `~/wiki-demo/{bin,app,data}`;
  backup after stopping the old service, with the new binary, the old service restarted if
  it fails; no deploy deletes `data/`, `--purge` keeps it, `--purge-data` removes it;
  `cabal-native-opt.project` (`-O2` for our packages only; the real `-O2` build was not run
  here, the first is the owner's). 178 server tests, 9 new deploy cases. Until WP2.4 the
  server serves the `MemWiki` build; the switch is `build_app` in `deploy-local.sh`.
  Found on the way: `test-bootstrap.sh` has failed since WP1.20 (its fake `node_modules`
  lacked CodeMirror's packages; CI does not run it), fixed in #49.
- **WP2.4 done and merged** ([#50](https://github.com/Swordlash/blog/pull/50), `12078ca`).
  `HttpWiki` (`Backend/Http.hs`, `Http/Request.hs`, `Http/Cache.hs`): one request per method,
  addresses from `Wiki.Api.Links` relative to `<base href>` (so `/admin/api/v1` on the admin
  listener), `If-Match` on saves, `ApiError` → `WikiError`, a `Transport` (one safe JSFFI
  `fetch` in the browser; the server's WAI application in process in tests), multipart
  written in Haskell (one `fetch`, identical bytes on every transport), 30 s timeouts (6
  min for uploads). `WikiError.Unreachable Text` for network failure, timeouts, 5xx and
  non-API answers, shown with "Try again" (`Common.failureView`) in the shell and views.
  Decision 18 as `MonadLoad` (`atOnce` cache-only, `attempt`; no `HalogenM` instance on
  purpose): views load in `initialState` through `atOnce` or render "Loading…" (faded in
  after 0.4 s) and fetch in `Initialize`; the demo unchanged, 24 pages at zero repairs. Flag
  `<meta name="wiki-backend" content="demo|server">`; `build-wasm.sh` takes
  `WIKI_BACKEND`, `WIKI_PUBLIC_DIR`; the server prerender is one shell page before any data,
  as `index.html` and `404.html`. `MonadDemoUsers` optional: `Shell.Input.demo :: Maybe (Demo
  m)`, `Wiki.App.serverInput`; the header shows the user's name over HTTP; the admin data
  section over HTTP has an export link and says import comes next. Cache per entity, emptied
  by every write except a draft's; other users' changes are seen on a write or reload.
  `wiki-app` depends on all of `wiki-api`: `app.wasm` 7339 → 7587 KiB (brotli 1717 → 1775).
  Tests: the whole contract (95) over `HttpWiki` against the server's WAI app in process;
  `Test.Backend.Http` 16; browser `Test.Browser.Http` 9 with a fake `fetch`; the smoke test
  is now `smoke-test.sh`: the demo, then `smoke-test-server.mjs` against a real
  `wiki-server --trust-network` (forms, Ctrl+S, attachment byte for byte, draft after
  reload, 409 conflict UI, search, export, a fresh browser); it builds `wiki-server` natively
  in CI's wasm job (a minute or two). Limits until WP2.6: every address but `/` is served
  `404.html` with status 404; no content before the data arrives; the anonymous reader
  (without `--trust-network`) still sees the demo's sign-in hints, true from Phase 3. For
  WP2.6: seed the client cache from `readEmbedded` (needs a way to seed `HttpEnv`'s cache),
  `Static.renderLoading`/`startLoading` run the app over `HttpWiki` natively. For WP2.8:
  the admin page's server branch is `Shell.serverControls`; `Request.multipart` writes one
  file part, `import/apply` needs the archive plus a `choices` text part; the browser's
  IndexedDB demo data is read through `Backend.Mem`'s store separately.
- **WP2.8 done and merged** ([#51](https://github.com/Swordlash/blog/pull/51), `32638db`).
  `HttpWiki.previewImport`/`applyImport` over `Request.multipartForm` (`FilePart`/`TextPart`;
  the `choices` part has no file name, which servant-multipart reads as an input).
  `Wiki.App.Import` is the pure dialog logic (`planTree`, `Selection`, `choicesOf`,
  summaries; native tests); `View/Import.hs` the component, a child of the shell in
  `serverControls`, fed a `Migration m` record (`Shell.Input.migration`; `serverInput` needs
  `MonadIndexedDB m, MonadUnliftIO m`). The demo source reads the `wiki` database directly
  (`memWikiFound` without creating it; `readMemWiki` never seeds; it opens at version 2, so a
  version-1 database gains the empty `drafts` store, as the demo itself would). Unchecking a
  space disables its pages; conflicts with `sameContent` get no choice; a large zip is held
  in memory (base64) for both requests; after an apply the shell reloads. 101 browser tests
  (4 new), 362 app tests, 274 server tests; the server smoke test exports the demo at the
  server's origin, imports with a skip and a `TakeImported`, then reimports from the
  browser's demo data with nothing twice. The owner's steps are in the README ("Bringing
  the demo's pages into the server"). One intermediate commit (`34c8578`) does not build its
  test suite alone; the head does.
- **WP2.6 done and merged** ([#52](https://github.com/Swordlash/blog/pull/52), `c6a6133`).
  `Wiki.Server.Render`: with a `template.html` in the static directory (written by
  `wiki-app-prerender --server`), every page address is rendered per request by the
  application itself, over `HttpWiki MemDOM` against the API in process as the listener's
  principal (`newImmediateHttpEnv`: `atOnce` asks the transport), so the payload is the
  cache after the render and the client's `atOnce` answers every read the server made;
  one pass, polling `Settled` every 1 ms (about 3 ms for a simple page, 24–27 ms for a
  Markdown-heavy one, at -O1). Status 200, 404 for an unknown route or a missing space or
  page, 403 for a private space; a render that throws, exceeds 10 s or sees a 5xx logs
  `event=render` and falls back to the old page, never a 500. `Preload` (`wiki-preload`
  script, API JSON: session, space tree, current space and its pages, the page, the draft,
  search hits; 1.2–11.4 KB, the latter because `listPages` carries page bodies: a lighter
  list type is a candidate) seeds the backend in `Main.hs` (`newHttpEnvWith`); the cache
  now keeps wiki refusals (`NotFound`, `Forbidden`, never `Unreachable`) and searches by
  query, both needed for zero repairs. Times are islands (`renderTime`, `<time
  class="wiki-time">`; the server's UTC vs the reader's zone was a repair). The admin
  listener's 302 is gone; the importer renders its zip source from the first render.
  `Test.Hydrate` adopts every route as anonymous and administrator over a transport that
  must not be asked (436 app tests), 15 render cases on the server, the smoke test checks
  11 addresses served with content before `app.wasm`, zero repairs, no API request, and a
  page readable with JavaScript off. `app.wasm` 7637 KiB (1790 brotli). Known repairs: a
  side-by-side preview from localStorage mounts after adoption; a Markdown body starting
  with a newline in the editor's textarea (untested). For Phase 3: signing in or out must
  clear the client cache, refusals included; `renderPage` takes the request's principal.
- **WP2.7 is done by WP2.3, WP2.4 and WP2.6**: the server answers `api/v1/search` with
  `searchPlain` over the stored text (decision 16), `HttpWiki.searchPages` calls it, the
  contract's `searchPages` cases run over `HttpWiki` against the server's application, and
  search pages are server-rendered with their hits in the payload. Nothing remains.
  Remaining in Phase 2: WP2.9 (Docker) and WP2.5 (page history).
- **WP2.9 done and merged** ([#53](https://github.com/Swordlash/blog/pull/53), `7930a78`).
  `Dockerfile` in four stages (`toolchain`: the new `bootstrap.sh build` mode, no Chromium
  or fourmolu, keyed on that file alone; `build`: dependencies from the `.cabal` and project
  files, then the sources, `-O2` natively and wasm-opt in server mode, `dist-newstyle` in a
  BuildKit cache mount; `release`; `runtime`: `debian:trixie-slim` by digest, uid 10001,
  `/data` 700, `curl`+`libgmp10`, `LANG=C.UTF-8`, healthcheck on `api/v1/info`);
  `toolchain/docker-entrypoint.sh` backs up before `serve` and refuses to start if that
  fails; `docker-compose.yml` publishes 8080 only, admin on the container's loopback via
  `exec`, volume `wiki-data`, a `backup` one-off under profile `tools`;
  `docker-compose.trusted.yml` is trusted mode as a host-network override (in a bridge the
  server can only bind `0.0.0.0`, which `--trust-network` refuses, and who reaches the port
  is the host's business), the same layout `deploy-local.sh` makes; `.dockerignore`
  allowlist. Tested here: the runtime image (238 MB, 63 MB compressed) and the compose
  stack end to end (info, 403 for anonymous writes, a space surviving restart and
  down/up, 8081 unreachable from the host, backups three ways, restore recipe, SSR and
  brotli served, trusted override at the VM's IP, `0.0.0.0` refused); the from-source
  builder was not run (needs about 15 GB free; the first build is "well over an hour").
  CI does not build the image. The owner hosts with `deploy-local.sh`, not Docker; the
  files are for a VPS later.
- **WP2.5 done and merged** ([#54](https://github.com/Swordlash/blog/pull/54), `112631a`).
  `Wiki.Core.Diff` (Myers on lines after trimming the common prefix and suffix, replaced
  lines paired and compared word by word with whitespace as tokens, caps of 1000 differing
  lines and 300 words per line after which the whole text is shown replaced; a 100 KB page
  with two edits diffs in 6 ms natively), `Wiki.Core.Version` (`VersionInfo`, `Version`,
  `Author`). `MonadWiki`: `listVersions` (metadata), `getVersion`, `restoreVersion pid at
  base` (a `savePage` of the version, so the conflict check and the draft's discard
  apply); error order page NotFound → Forbidden → version NotFound → Conflict on both
  backends. `Mem` keeps versions in memory and in IndexedDB (store `versions`, database
  version 3, records built lazily and written once); SQLite uses `page_versions` (sorted in
  Haskell; authors resolved from `users`, `~administrator` shown as "Administrator"). API:
  `GET pages/<p>/versions`, `GET pages/<p>/versions/<time>`, `POST …/restore` with
  `If-Match`; `VersionTime` is the unquoted ISO time. Route `PageHistory` at
  `…/p/<page>/history/?version=<iso>&against=current`, `history` a reserved slug word;
  `View/History.hs`: versions newest first with the time island and the author, the diff
  against the previous version or the current page, a title change as `<del>`/`<ins>`,
  "Restore this version" for editors on any version but the latest, confirmed in place;
  "History" next to "View source" for every reader. Prerendered in the demo at the latest
  version (33 pages) and server-rendered (404 for a version the page lacks). Versions are
  not exported (`docs/export.md`). `app.wasm` 7951 KiB (1857 brotli), up 314. Tests: diff
  properties, 7 contract cases on all four backends, the IndexedDB upgrade, API goldens,
  `Test.Hydrate` at zero repairs, 5 browser cases, both smoke tests. Later decisions if ever
  needed: a limit or pruning of a page's history; attachments are not versioned, moves make
  no version. For Phase 3: version authors come from the session's user; signing in or
  out clears the client cache, `versionLists` and `versions` included.
- **Phase 2 complete** (2026-10-24). `main` at `112631a` has the server (`wiki-server
  serve|backup`, two listeners, `--trust-network`, per-request rendering with embedded
  data), SQLite storage with migrations and backups, the HTTP backend in the app with the
  demo kept for Pages, the migration of the demo's pages, page history, the local deploy
  (`deploy-local.sh --server`) and Docker for later. Tag point for `v0.2.0-server`, which
  the owner pushes. Next: Phase 3, pending the owner's word on its decisions (8, 9, 11:
  argon2id passwords and cookie sessions, the Confluence-like model, the administrator
  made from the admin listener; `--trust-network` retires once sessions exist).
- **Phase 3 started** (2026-10-25). The owner confirmed decisions 8, 9 and 11. The phase is
  recut (WP3.2 folded into WP3.1, the panel split into WP3.3 without passwords and WP3.4
  with them), decision 20 fixes the cookies for plain http, decision 11 gains the console
  `wiki-server users …`. WP3.1 (accounts and sessions) and WP3.3 (administration panel)
  run in parallel on `wp3.1-accounts` and `wp3.3-admin-panel`; whichever merges second
  rebases. `--trust-network` stays until WP3.4.
- **WP3.3 merged** (2026-10-25, PR #55, `main` at `cd61ad2`). The administration route gains
  the panel of decision 11, shown only to an administrator: "Users" (login, display name, an
  administrator switch per user, one's own disabled with a note) and "Groups" (members with
  Remove, a choice of other users to add, Rename, Delete confirmed in place, "New group").
  `MonadAdmin` (`Wiki.App.Backend.Admin`: `directory`, `setAdministrator`, `createGroup`,
  `renameGroup`, `deleteGroup`, `addMember`, `removeMember`) has instances for `MemWiki`
  (the existing IndexedDB stores, no version bump), `HttpWiki` (the directory cached and
  preloaded, `DirectoryOf`) and `SqliteWiki` (one transaction each, the global administer
  checked before any id is looked up: `Forbidden` before `NotFound`, deliberately, so a
  reader learns no ids). API: `GET admin/directory` (`Directory {users, administrators,
  groups, membership}`), `PUT admin/users/<id>/administrator`, `POST admin/groups`,
  `PUT admin/groups/<id>/name`, `DELETE admin/groups/<id>`, `PUT`/`DELETE
  admin/groups/<id>/members/<user>`; `AdminApi` is now `data`. Rules: an administrator may
  remove their own administer (the server allows, the UI refuses); deleting a group deletes
  the grants naming it; group names trimmed, non-blank, unique ignoring case; adding or
  removing a member twice changes nothing; "administrator" in the panel means a direct
  grant, not one through a group. Tests: a shared contract of 15 cases on all four
  backends, HTTP tests on both listeners (anonymous 403 everywhere), storage, a shell
  render, zero-repair hydration of `/admin/`, 5 browser cases over `MemWiki` and one over
  a fake fetch, the server smoke test makes a group. `app.wasm` 8071 KiB (1888 brotli), up
  120. Carried to WP3.4: the admin API answering an administrator's session on the public
  listener; account forms go in `View/Admin.hs` (a "New user" form under the Users table,
  reset and disable per `.user-row`, a `disabled` set in `Directory`); per-space permissions
  and `create-spaces` need a section of their own or the space view. Noted by the agent:
  `build-wasm`'s native prerender step recompiles `wiki-core` in `dist-newstyle/native`
  after `build-native`, so the two builds may invalidate each other.
- **WP3.1 merged** (2026-10-25, PR #56, `main` at `e078ded`; WP3.2 folded in). Migration
  `0002-accounts.sql`: `users.password_hash` (nullable: existing and imported users cannot
  sign in until given one), `users.disabled`, `sessions` (SHA-256 of the id, user, created,
  last seen, expiry). Passwords are argon2id from `crypton` (compiled in, no system library),
  `m=19456,t=2,p=1`, 16-byte salt, 32-byte hash, PHC strings, checked against OpenSSL's
  argon2 in a test; an unknown login is checked against a dummy hash. The principal is found
  per request (`Wiki.Server.App.findCaller`, `Finding`): admin listener → administrator,
  cookies ignored; public listener under `--trust-network` → administrator (unchanged until
  WP3.4); otherwise the `wiki_session` cookie's user, or anonymous for none, an ended
  session or a disabled user, the stale cookie cleared. Handlers take a `Caller` and never
  see the listener; pages are rendered and preloaded as the request's principal, API answers
  and pages carry `Cache-Control: private, no-cache` and `Vary: Cookie`. `POST`/`DELETE
  api/v1/session` sign in (401 `Unauthenticated`, 429 `TooManyRequests` with `Retry-After`,
  400 where everyone is the operator) and out; cookie `HttpOnly; SameSite=Strict;
  Path=<base path>; Max-Age=14d`, `Secure` only with `--secure-cookies` (decision 20);
  sessions end on sign-out, on disabling or a new password, and after 14 idle days, use
  recorded at most hourly. CSRF: every API write needs `X-Wiki-Request` (`requestMarker`),
  and `Sec-Fetch-Site`, when sent, must be `same-origin` or `none`; the check is on the API
  only (a bare POST to a page stays 405). Rate limit in memory: 5 failures per login and
  address, 30 per address, in 15 minutes. Admin API: `createUser` (`POST admin/users`),
  `setPassword`, `setDisabled` (`PUT admin/users/<id>/password|disabled`), each answering
  `Account {user, hasPassword, disabled}`; no `MonadAdmin` method for them yet. Console
  `wiki-server users list | add LOGIN [--display-name] [--admin] [--no-password] | password
  LOGIN | admin LOGIN --on|--off | disable LOGIN --on|--off --data DIR` (`Wiki.Server.Console`,
  `withStorageAside` beside a live server, password from the terminal or stdin, never argv):
  how the first administrator is made; `deploy-local.sh` prints the line. App: `MonadAccount`
  (`Wiki.App.Account`: `signIn`, `signOut`, `sessionChanges`) for `HttpWiki` only, reaching the
  shell as `Accounts` in `Shell.Input`; `View/SignIn.hs` popover form, "Sign out", the operator
  sees only the name; `Session.standing :: Standing` (`NotSignedIn | SignedIn | Operator`);
  sign-in and sign-out empty the whole client cache; a 401/403 while signed in re-reads the
  session and reopens the form when it ended; the server's admin refusal text fixed. Tests:
  server 386, app 528, api 56+75, browser 117 (4 sign-in cases), smoke test checks a write
  without the header gets 403 and no sign-in under trust, `test-deploy-local.sh` 44 cases.
  Known: a 401/403 to a signed-in client costs one extra `GET session`; crypton's argon2 is an
  `unsafe` FFI call of tens of milliseconds; the expiry sweep compares ISO text, harmless as
  `resolveSession` compares parsed times. For WP3.4: `Directory` lacks `disabled` and
  `hasPassword`; the account forms need `MonadAdmin` methods over the three endpoints; the
  admin API answering an administrator's session is tested; the smoke test needs to sign in
  once `--trust-network` goes.
- **WP3.4 and WP4.2 started** (2026-10-25) in parallel from `main` `2fc3329`, on
  `wp3.4-permissions` (account forms, `create-spaces`, per-space permissions, the admin API
  to an administrator's session, `--trust-network` retired) and `wp4.2-slides`
  (presentations from a page); whichever merges second rebases.
- **WP3.4 merged** (2026-10-25, PR #57, `main` at `71306e6`). `--trust-network` is gone:
  the public listener serves whoever signs in and everyone else as an anonymous reader; the
  first administrator is made with `wiki-server users add --data DIR LOGIN --admin`;
  `deploy-local.sh` refuses the old flags with that hint, a deployment that had the flag
  loses it on its next run and says so; `docker-compose.trusted.yml` deleted. Panel: the
  users table gains "Creates spaces" (global `create-spaces`, `PUT
  admin/users/<id>/create-spaces`) and an "Account" column (password state, "Set/Reset
  password…" inline, Disable/Enable, never one's own), and a "New user" form (login, display
  name, password, administrator). `MonadAdmin` gains `setCreateSpaces`, `createUser`,
  `setPassword`, `setDisabled`; `Directory` gains `creators`, `disabled`, `withPassword`.
  Space permissions: `View/Permissions.hs`, a child of the space view behind a "Permissions"
  action for whoever `canAdministerSpace`, closed by default (prerender unchanged, zero
  repairs): the public switch (moved here from the actions), the space's own grants with
  Revoke, inherited grants read-only with their origin, a grant form (user or group; View,
  Edit, Administer). `MonadWiki` gains `spaceAccess` and `setSpaceGrant` (`GET`/`PUT
  spaces/<id>/grants`, `SpaceGrantChange {subject, permission, granted}`), needing
  `AdministerSpace`, so on `MonadWiki` not `MonadAdmin`. `Wiki.Core.Permission` gains
  `SpaceAccess` and `keepsAdministering` (the grant one administers by is not offered to
  revoke); `Wiki.Core.User` gains `checkLogin`, `checkPassword` and the password length
  bounds, shared by the demo. Mem: `disabled` and `passwords` sets in the `meta` store, a
  disabled user is nobody and leaves the switcher. Server: `createUser`/`setPassword` check
  for an administrator before hashing; account handlers go through the storage; no
  migration. Tests: server 407 (admin API to an administrator's session on the public
  listener, 403 to anonymous and to a non-administrator; create-spaces; grants inherited
  by a subspace and ended by revocation; `--trust-network` a parse failure), app 550,
  core 570, browser 125 (13 new), the server smoke test makes "Ada Admin" on the console,
  signs in through the header, makes a user and a public space, checks an anonymous
  visitor sees only the public space, no admin link, 403 elsewhere; `test-deploy-local.sh`
  44. `app.wasm` 8278 KiB (1924 brotli). Not done: group grants of the global permissions
  are not shown or toggled (they still count by the rules). For WP3.5: `createAccount st
  login name Nothing` makes a user without a password; factor `startSession` out of
  `Accounts.signIn` and set the cookie with `Session.sessionCookie`; "signs in another
  way" needs a notion beside `withPassword`.
- **WP3.5 started** (2026-10-25) on `wp3.5-open-closed` from `main` `fa083d1`, beside the
  running WP4.2; whichever merges second rebases.
- **WP4.2 merged** (2026-10-25, PR #58, `main` at `7b8fb10`). A page is a slide deck:
  `Wiki.Core.Slides.deckOf` cuts the parsed page at its top-level thematic breaks (a `---`
  inside a list, quotation or box stays a rule), the first top-level heading is the slide's
  title (a level-1 heading makes a title slide), `::: notes` divs are the speaker's notes,
  each footnote goes to the first slide that refers to it, empty slides are dropped;
  `isDeck` holds for a page with a top-level break or a `::: {.slides theme=beamer|light|dark
  aspect=16:9|4:3}` div (shown nowhere, case-insensitive, unknown values default).
  `renderDeck` renders the deck as one document through the new `Render.renderSections`
  (island keys unique across slides, macros carry over, footnote ids unique; a footnote
  list now writes `<ol start>` when it does not start at 1). Route `PageSlides` at
  `…/p/<page>/slides/?slide=N` (1-based, left out for 1, replaced in the history so Back
  leaves the deck); `slides` is a reserved word, so a page or space slugged `slides` is
  written `~slides` and old links to `…/p/slides/` no longer resolve, as `history` did.
  `View/Slides.hs` (`hh`): the window covered, one slide shown scaled with container units,
  progress bar, controls (Back to page, ‹ n / N ›, Notes, Overview, Full screen, Print,
  "with notes"); keys ← → Space PageUp PageDown Home End Enter, `f` fullscreen (controls
  fade until hovered), `n`/`s` notes below, `o` overview (click or Enter picks, Escape
  closes), swipe; the search box's `/` ignores keys inside the view. All slides are
  rendered and their islands drawn once, the stylesheet hides all but the current, which
  is what makes print work: `@media print` puts each slide on a page of its shape, or with
  "with notes" on an A4 page above its notes. "Present" after "History" for every reader,
  only where `isDeck`. Shell crumb "Slides"; the demo prerenders the slides route of every
  deck; the server renders it with the page's 403/404. Demo page Docs › Markdown guide ›
  Presentations (7 slides: math, Mermaid, code, a table, notes); `docs/markdown.md` has a
  "Presentations" section. Tests: 20 splitting and options cases, 4 deck-rendering cases,
  route round-trip, hydration at zero repairs (prerendered and server-rendered, `?slide=4`
  and a non-deck page), server render 200/403/404, 9 browser cases, both smoke tests (the
  demo prints a 7-page PDF under print emulation). Counts: core 591+92, app 568, server
  407, browser 134. Not done, carried: the theme from the space's settings (needs a space
  field and a migration), notes in a second window; not browser-testable: swipe,
  fullscreen, the print layout beyond page count. A static host serves the slide-1
  prerender for `?slide=N`, repaired on adoption, as `history/?version=` is. For a later
  pandoc/Beamer export: build on `deckOf` (level-1 title → title page or `\section`,
  level-2 → frame title, notes → `\note{}`, theme/aspect → `\usetheme`/`aspectratio`),
  pre-split since pandoc cuts at headings; islands would need server-side rendering.

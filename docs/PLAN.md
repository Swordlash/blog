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
   interface so Postgres can come later if ever needed. **Superseded on 2026-10-29 by
   WP5.22:** one storage layer on Beam with the backend as a type parameter, PostgreSQL
   the default deployment (docker compose), SQLite the option without a second container;
   `sqlite-simple` stays only for what Beam has no form for (PRAGMAs, `BEGIN IMMEDIATE`,
   `VACUUM INTO`).
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
    accepts API billing. **Picked up on 2026-10-27**: the owner accepts API keys for both
    providers ("Zrób integrację po stronie klienta jednak Claude i OpenAI po api keys");
    nothing about the subscriptions has changed (OpenAI's "Sign in with ChatGPT" is still for
    locally run open-source tools, a hosted web application stays on its waitlist), so it
    is bring-your-own-key as decided, as WP4.19.
22. **Whoever administers a space sees the wiki's users and groups** (2026-10-25, from
    WP3.4). `spaceAccess` gives a space's administrator the grants on the space and its
    ancestors and every user and group, so that they can choose whom to grant to, as
    Confluence does; a user who merely created a space is such an administrator. Accepted
    for a wiki of this size; disabled users may later be left out of the candidates, and
    a wiki with many users would want a search instead of the list.
23. **Comments are anchored to quotes, and live over one WebSocket** (2026-10-25). An
    inline thread does not point into the Markdown source (a selection happens in the
    rendered page, and mapping it back to source offsets is fragile); it carries a
    *text quote selector* over the page's rendered plain text, as the W3C annotation model
    has it: the exact quote plus a short prefix and suffix. Highlighting is a pure pass in
    `wiki-core` over the rendered document that wraps the quote's text in `<mark>`s,
    splitting text nodes and never crossing block boundaries, so the rule that a page is
    always Halogen elements holds and no JavaScript touches the DOM; a quote the page no
    longer contains (or contains more than once without its context matching) makes the
    thread *orphaned*: still listed in the panel, without a highlight, with the quote shown.
    Page threads need no anchor. The live channel is one WebSocket per browser tab,
    authenticated by the session cookie on the upgrade, carrying typed `PageEvent`s for the
    pages the tab subscribes to; the server keeps the subscriptions in memory (one process)
    and a client that reconnects re-reads what it shows, so a lost event costs nothing. SSE
    would reconnect by itself, but the owner asked for WebSockets and the same channel is
    meant to carry what a client sends later (presence, "editing now").

24. **Public under MIT; the server binary is GPL-governed when conveyed** (proposed and
    confirmed by the owner, 2026-10-26: "Dobra róbmy"; the owner also noted that code
    written wholly by AI may not be copyrightable at all, which argues for a permissive
    licence rather than against one: copyleft would have nothing to enforce with, and the
    README says plainly that the code was written with Claude under the owner's
    direction). The repository's own code goes under the MIT licence:
    the simplest permissive one, and compatible with every dependency. The one constraint
    is `wiki-server`, which links pandoc (GPL-2.0-or-later), texmath and skylighting (both
    GPL-2 "or any later version" by their file notices and README, whatever their cabal
    field says); a binary of it is a combined work under the GPL, taken at version 3 since
    haskell-halogen (Apache-2.0) is linked too, and the GPL binds only whoever *conveys*
    binaries. Nothing conveys one today: the deploy and the Dockerfile build from source,
    and no release or image is published; the README says so, with a table of the
    third-party licences. Ruled out: Apache-2.0 (haskell-halogen's) would be the natural
    match but adds nothing and is incompatible with GPL-2-only code should a dependency
    ever be that; AGPL-3 and GPL-3 for our own code would close the door on reuse for no
    gain, since the browser side links nothing copyleft. The demo on Pages conveys TikZJax
    (GPL-3.0-or-later, served unmodified as its own worker beside its licence text) and its
    BaKoMa Computer Modern fonts, whose licence the release package must determine and
    name (the npm package ships none).
25. **Libraries over hand-rolled code** (the owner, 2026-10-29: "wszędzie używamy
    bibliotek, jak najmniej vendorowanego kodu, jak najmniej hand rolled javascriptu").
    Where a maintained library covers a need, it is used: a protocol (JWT and JWKS through
    `jose`, WebAuthn, OIDC, TOTP, multipart, HTTP), a data structure, a browser capability
    (a service worker through Workbox rather than by hand, an editor through CodeMirror).
    Hand-written code is for what is this wiki's own (the domain, the permission rules,
    the Markdown allowlist) and for the glue a library needs to be called from Haskell
    (`browserJS` bindings, a few lines around a library's call). Nothing is vendored into
    the repository when a package exists (Hackage, npm). A package is chosen for being
    maintained and building on the targets (native, and wasm where the code runs in the
    browser); a package that does not build on wasm is a reason to look for another, not
    to write the thing by hand, unless nothing exists, which the plan then records. The
    hand-written code that predates this rule is listed for review in WP5.27.
26. **Browsers: the last year of releases** (the owner, 2026-10-29, when a review found the
    platform's `Uint8Array.toBase64` raising the floor: "można zostawić te base64, nie
    musimy supportować starszych niż rok wersji"). The application supports browsers
    released within the last year (as of WP5.24: Chrome and Edge 140, Firefox 133, Safari
    18.2, or later) and uses the platform's APIs rather than polyfills or fallbacks for
    them. The README states the floor in one place; a package that raises it says so in
    its changelog.

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
- **WP4.4 Server settings from the panel** (the owner, 2026-10-25: providers "and other
  things" set up from the administration). Today the sign-in providers, SMTP and the public
  URL are options read at start, so adding a provider means a `deploy-local.sh` run and a
  restart. They move into the `settings` table (migration `0005-server-settings.sql`, or
  rows of the existing table) and into the administration, a "Server" section beside "Who
  may come in": the public URL; mail (host, port, security, user, sender, the password
  write-only); the sign-in providers (name, kind, client id, issuer, the secret write-only),
  added, changed and removed one by one, each with "Check" running discovery and showing the
  redirect URI to register. Secrets live in the database (which already holds password and
  session hashes and is as sensitive as its file; `data/` protects it) and never come back
  through the API: the panel shows "set" or "not set". The server reads them per request
  from the cached settings as it reads the access mode, so a change takes effect at once,
  discovery re-run on change, mail sent with the current settings. **No command-line
  bootstrap or override** (the owner, 2026-10-25): the panel on the admin listener is the
  only place these are set (decision 11 makes that listener the bootstrap, so nothing is
  needed before it); the `--smtp-*`, `--public-url` and `--oidc` options and their
  environment variables go, `deploy-local.sh` refuses them with a pointer at the panel and
  removes the env file it kept for their secrets, `wiki-server oidc check` reads the
  database. A secret is typed once into a password field, stored, and never shown again:
  "set" or "not set", with "Replace…" and "Clear". Tests: HTTP for the settings' endpoints
  (administrator only, secrets never returned), a provider added at run time signs someone
  in without a restart, mail with settings changed at run time, migration; browser tests
  for the forms.
- **WP4.5 Comments** (the owner, 2026-10-25: inline comments from a selection with a thread
  at the side, and comments under the page, as Confluence has them, live over WebSockets).
  Decision 23 below fixes the shape. In short: threads anchored to a quote of the page's
  text (a selection in the rendered page opens a new thread in a side panel; the quote is
  highlighted; a thread whose quote the page no longer has is kept as orphaned), and
  page threads under the article; a comment is Markdown rendered by the page's renderer
  (allowlist included), with one level of replies, edit and delete of one's own, resolve and
  reopen for inline threads; whoever may view the page and is signed in may comment, space
  administrators may delete anything. Live: the browser keeps one WebSocket to the server
  (`Halogen.Net.WebSocket` from the pinned `net`), subscribed to the page it shows; the
  server (`wai-websockets`) authenticates the upgrade by the session cookie, obeys the
  closed-wiki rule, and pushes comment events to the page's subscribers; the client
  reconnects on close and re-reads the threads then. The message type is general
  (`PageEvent`), so "someone else is editing" and "this page changed" ride the same channel
  later. Migration `0006-comments.sql`. The demo keeps comments in memory and IndexedDB, with
  no live channel. Tests: the anchoring (pure, native: found, moved, orphaned), permission
  rules per operation over HTTP, the WebSocket end to end (two clients, one comments, the
  other hears), the closed-wiki refusal of the upgrade, browser tests for selecting text and
  commenting, the side panel, the page threads, hydration at zero repairs with threads.
- **WP4.6 One space at a time** (the owner, 2026-10-25: as Confluence, the sidebar shows one
  space, each space has a home page and an image). Who may create a space stays as it is
  (the global `create-spaces`, administrators by default, as Confluence Data Center has it).
  The home route becomes a *space directory*: cards with each space's icon, name and
  description, and the recently visited ones. Inside a space the sidebar shows that space
  only: its home page, its page tree, and its subspaces as a section below (Confluence has no
  subspaces; ours stay), with the space's name and icon above and a switcher back to the
  directory or to another space; the breadcrumb reads space › subspace › page. A space gains
  a home page (the page opened on entering it; a "Home" page is made with the space, from a
  template, and any page can be chosen later), an icon (an uploaded image stored like an
  attachment, or an emoji or a colour by default) and a description, set by a space
  administrator in the space's settings (the "Permissions" section grows into "Space
  settings"). Migration for `home_page`, `icon`, `description`; the directory and the space
  view prerendered and server-rendered as today; the demo gets icons and descriptions. After
  WP4.4, WP4.5 and WP3.7, since it reshapes the shell's sidebar that the comments' side
  panel touches. Confirmed by the owner on 2026-10-25; it starts as soon as those three are
  merged.

### Phase 5: public release

The owner's ask (2026-10-26): "powoli przygotować do releasu na public": a licence, the
demo deployed on GitHub Pages from the browser's IndexedDB, and the self-hosted runner
kept for the owner's own pull requests. Three steps, in this order, since the Pages deploy
and the fork gating can only be tested once the repository is public, and the licence
must be in before it is.

- **WP5.1 Licence, runner gating, `--server` by default.** `LICENSE` becomes MIT (decision
  24, once confirmed), the four `.cabal` files say `license: MIT` and `license-file`, and
  the README's licence section says the code was written with Claude under the owner's
  direction, and lists the third-party licences: in `wiki-server`'s binary
  pandoc, texmath and skylighting (GPL, so conveying a binary follows the GPL; none is
  conveyed), haskell-halogen (Apache-2.0); in the page KaTeX (MIT), Mermaid (MIT),
  highlight.js (BSD-3), CodeMirror (MIT), fflate (MIT), TikZJax (GPL-3.0-or-later, served
  unmodified as its own worker: `web/bundle.sh` copies its `LICENSE` beside the
  `NOTICE.txt` it writes, since conveying GPL code needs the text) and TikZJax's BaKoMa
  fonts (licence found and named). The plan's own note that TikZJax sits "beside a
  proprietary repository" is answered by this. CI: the workflow chooses its runner by
  trust, `self-hosted` for a push, a dispatch and a pull request whose head is in this
  repository (only write access pushes one: the owner, and the Claude sessions acting as
  them), `ubuntu-latest` for a pull request from a fork or a bot actor, through one
  expression on `runs-on`; a `workflow_dispatch` input `runner` (`self-hosted`, default,
  or `hosted`) runs the hosted path by hand, which has not run since the runner moved to
  the owner's machine and is exercised once after the repository is public (free then).
  The README's CI section documents the two layers: this, and the repository setting the
  owner clicks (Settings, Actions, General, "Fork pull request workflows from outside
  collaborators": require approval for all external contributors), and says plainly that
  GitHub advises against self-hosted runners on public repositories, what limits the
  exposure here (the runner's own user, approved fork runs going to hosted runners, no
  secrets in the workflow) and what remains. `deploy-local.sh`: `--server` becomes the
  first run's default and `--static` the opt-in, since the demo's home is Pages; the
  state remembers the mode as before, so the owner's deployment does not move; header,
  README and the first-install test cases follow. Hygiene before the flip, listed for the
  owner in the report: the `maintainer` address in the `.cabal` files becomes public (the
  owner's call to keep or drop; kept unless told otherwise), pull request texts become public (the tailnet hostname
  appears in some; it is in Certificate Transparency logs anyway), secret scanning and
  push protection to turn on after the flip. Tests: `test-deploy-local.sh`'s first-install
  cases, a native test that every `.cabal` names the licence file, and the workflow
  expression checked by `actionlint` or by hand on a dispatch. No migration.
- **The owner's step.** Confirm decision 24, make the repository public, click the Actions
  setting above, turn on secret scanning and push protection, set Pages to deploy from
  GitHub Actions (Settings, Pages, Source), and run the workflow once with `runner:
  hosted`.
- **WP5.2 The demo on GitHub Pages.** A `deploy` job on a push to `main`, after the wasm
  build, publishes `dist-newstyle/wasm/public/app` built with `WIKI_BACKEND=demo` and
  `HALOGEN_BASE_PATH=/blog/` (the repository's name; the owner may give it a domain
  later) through `actions/configure-pages`, `upload-pages-artifact` and `deploy-pages`
  (`pages: write`, `id-token: write`, environment `github-pages`), which work from the
  self-hosted runner. The `tested` skip has to be met: on a fast-forward push the wasm
  job is skipped, so either every wasm job (pull requests too) keeps the built page as
  the run's artifact and the deploy job downloads it from the run
  `ci-already-tested.sh` found (`actions/download-artifact` with `run-id`), or the deploy
  rebuilds on `main` (another quarter of an hour on the runner); the first, unless it
  proves brittle, with the reason reported. The demo's IndexedDB database is named
  `wiki` (`Wiki.App.Demo`), and IndexedDB is per origin: `swordlash.github.io` hosts
  haskell-halogen's gallery and whatever else the owner publishes, so the name becomes
  one of the wiki's own (`wiki-demo`, or the base path in it) before the first deploy;
  the service worker's caches already carry their scope. WP4.17's manifest and worker
  under a base path are verified where it counts: `npm run smoke-test` against a build
  made with the base path and served under that prefix, and the installability check in
  Chromium; the hydration count stays at zero repairs. The README's "Running the demo"
  points at the public address. No migration.
- **WP5.3 A README for the public, with examples** (the owner, 2026-10-26: "odświeżyć
  readme i dodać jakieś więcej przykładów użycia bibliotek i prezentacji"). The README is
  written today for the people building it: it opens with how it is built and lists what
  works in the plan's order. It becomes a page for someone who finds the repository: what
  the wiki is in a paragraph, the live demo's address (`https://swordlash.github.io/blog/`,
  which WP5.2 makes real), screenshots (a page with a formula and a diagram, the editor
  beside its preview, a deck, the directory of spaces; taken from the demo in Chromium by a
  script `toolchain/screenshots.mjs` so they can be remade, committed under
  `docs/screenshots/`, each under 300 KB), then "Writing pages" with a worked example per
  library, each a fenced block of the Markdown as the author types it and a line on what
  appears: math with KaTeX (inline, display, a macro of the space, `\ce` chemistry),
  Mermaid, TikZ (with a `\usetikzlibrary`), highlighted code, GitHub's alerts, `[[toc]]`,
  attachments and images, a wiki link; then "Presentations" with a complete small deck as
  one page (the front matter or marker `Wiki.Core.Slides` reads, slides cut by `---`,
  notes, a theme and aspect, how it is shown and exported to Beamer PDF and PPTX), the
  same examples living in the demo's `Presentations` and `Tour` pages so each snippet in
  the README links to a page where it renders (the demo content changes only where a
  snippet has no page yet). The sections on running, deploying, the toolchain and CI stay,
  shortened where they repeat `docs/`; `docs/markdown.md` stays the complete reference and
  the README links to it. Nothing in `web/`, the workflow or `Wiki.App.Demo`'s database
  name (WP5.2's). Tests: the smoke test still passes with any demo page added; the
  screenshot script runs under `npm run screenshots` and is checked by CI only in that it
  parses (`node --check`). No migration.
- **WP4.19 The writing assistant, bring-your-own-key** (the owner, 2026-10-27; decision
  21; reshaped the same day: "w formie chata, z zaznaczeniem, agent robi edit", as the
  code editors do). In the editor, an "Assistant" entry in the toolbar opens a side panel
  (beside the preview, under the attachments on narrow screens) that is a chat: the
  user's and the assistant's messages, streamed, an input with Send and Stop, and
  shortcuts that fill the input (improve, fix grammar, shorten, expand, summarise,
  continue, translate). A selection in the editor at the time of sending is attached to
  the message as a chip and goes to the model with a little context around it; without
  one the model gets the body, cut to a cap the panel says. The conversation lasts the
  editing session and is sent whole each turn. The model edits the page itself through
  two tools, `replace {old_text, new_text}` and `insert {anchor, before|after, text}`
  (the texts unique in the page, or `start`/`end`), run by the SDKs' tool loop; each
  call is applied to the editor's document as a tracked change (inserted text marked,
  removed text kept visible and struck until decided) and answered to the model with
  "applied" or why not; the user accepts or rejects per change or all at once, Save with
  pending changes accepts them, Stop aborts the stream and leaves what was applied
  pending. The system prompt puts the authors' reference `docs/markdown.md` first,
  embedded at compile time and marked cacheable (Anthropic's `cache_control`, OpenAI's
  prefix cache), then tells the model it edits a page of this wiki, in its Markdown, and
  sends the page's title and the context above, never attachments nor other pages; the
  tool definitions, the prompt's assembly, finding a unique occurrence, applying an edit
  and accept/reject are pure and tested natively. Providers: Anthropic (Claude) and OpenAI, through
  their official JavaScript SDKs (`@anthropic-ai/sdk`, `openai`), bundled by
  `web/bundle.sh` as an island of its own (`islands/assistant.js`, fetched the first time
  the panel opens, as the editor's own code is), with streaming, retries and typed errors
  from the SDKs; the Haskell side sees a `MonadAssistant` class (a provider, a model, a
  streaming completion delivering chunks, cancellation) with a `BrowserDOM` instance over
  a `browserJS` binding in `wiki-app/jsbits/assistant.js` and a scripted instance for
  tests (a fake provider that replays an answer, usable from the browser tests too). The
  user's settings ("Assistant" in the account menu, a page of its own): one API key per
  provider, the provider and the model to use (a short list per provider, with the
  newest general models first, and a free field), a "Test the key" button that makes the
  smallest request, and a line that the key is billed by the provider and stays in this
  browser; the keys live in this browser's IndexedDB under the user's id (another user on
  the same browser does not see them), are never sent to the wiki's server (no API, no
  migration), never logged, and are removed by "Forget" or by signing out of the wiki
  (your call to keep them across sign-outs, say which). Direct browser calls: Anthropic's
  `dangerouslyAllowBrowser`, OpenAI's the same, over HTTPS, so the demo on Pages and the
  HTTPS deploy work; a plain-HTTP deploy shows a warning in the settings (the key would
  travel to the provider over TLS anyway, but the wiki's own page is not secure). Errors
  are shown in the panel as the provider gives them (an invalid key, a rate limit, a
  model that is not there, the network) without the key in them. Tests: the prompt's
  assembly, the cap, the tools and the change set natively; the settings' storage over
  the contract (keys per user, forgotten on request); browser tests for the chat with a
  scripted fake provider (a turn with a selection whose `replace` shows a tracked change,
  accepted and rejected; two edits in a turn; an insert at the end; a `replace` of absent
  text answered with the tool error and the model's follow-up shown; Stop mid-stream); the
  smoke test opens the settings and the chat in the demo; `licenses.txt` gains the SDKs. The hydration tests stay at zero
  repairs (the panel is client-side only). No migration, no server change.
- **WP5.4 Run on whichever runner is free** (the owner, 2026-10-26, once the hosted path
  worked and the minutes proved free for a public repository: "niech sobie chodzi na self
  hosted albo ubuntu latest, które jest wolne"). GitHub has no "first available" across a
  self-hosted runner and its hosted ones (`runs-on` with several labels is a conjunction),
  so a first job picks: `plan`, on `ubuntu-latest` (seconds, free), which takes over the
  `tested` job's work on a push and, for every event, decides the runner the build jobs
  take through `toolchain/ci-pick-runner.sh`: `ubuntu-latest` when the run is not trusted
  (a fork's pull request, a bot actor, the dispatch input `runner: hosted`; the trust rule
  stays written in the workflow and reaches the script as an input, so the YAML still
  shows it), else `self-hosted` unless the owner's machine is busy, which the script
  learns from the Actions API with the run's own token (`actions: read`): any other run of
  this workflow queued or in progress with a job whose labels name `self-hosted` and whose
  status is queued or in progress; then `ubuntu-latest`. Any API error answers
  `ubuntu-latest`, which is always there. The build jobs' `runs-on` becomes the job's
  output; the deploy job takes it too. Known and accepted: the token cannot see whether
  the self-hosted runner is online (that needs `administration: read`, which a workflow
  token cannot have), so a run picked for a machine that is off waits in its queue as
  today; the owner's way out is the dispatch with `runner: hosted`, or turning the machine
  on. Tests: `toolchain/test-ci-pick-runner.sh` against a fake API, as
  `test-ci-already-tested.sh` is: idle picks self-hosted; a queued or running
  self-hosted job of another run picks hosted; this run's own jobs do not count; hosted
  jobs elsewhere do not count; an API error picks hosted; untrusted picks hosted without
  an API call; the dispatch input wins. `actionlint` clean; the README's CI section says
  the rule and that `plan` runs on the hosted runners for everyone. After WP5.2, whose
  workflow this builds on.
- **WP5.5 Three small fixes from the owner's first days on a work laptop** (2026-10-27).
  The administration's forms (public address, mail, mail test, sign-in provider, backups,
  invitations, new user) in one column up to 30rem, scoped CSS, a browser check of the
  layout; a `field-hint` under each field of "Add a provider" in the README's words, and the
  redirect line in three states (no public address; "Type the name above and the redirect
  URI to register appears here."; the URI with how to register it); and TikZJax past a
  corporate proxy that returns 403 on `application/gzip`: `web/bundle.sh` rewrites every
  `.gz` under `tikzjax/` (173 files: TeX, the core dump and the packages `run-tex.js`
  fetches through the same pako loader) as a zlib stream named `.bin`, served as
  `application/octet-stream`, and the worker maps the `.gz` requests to them; the smoke
  test fails on any `.gz` shipped there.
- **WP5.6 No password for provider accounts; the administrator sends password links** (the
  owner, 2026-10-27, setting up Google sign-in). An account with no password that signs in
  with a provider the server still has (`Wiki.Api.Account.providerOnly`, a server-filled
  `Directory` field) has no password to set: not in its own menu, not in the Users table,
  and the server refuses it on the user's and the administrator's endpoints and in the
  public reset; an account whose last provider was disconnected or removed is "No way in"
  and gets one like any other. The administrator's button becomes "Send a password link…"
  (`POST admin/users/<id>/password-link`, 204; the same link, expiry and sign-out as "Forgot
  your password?", one a minute per account, audited as `user.password-link`) where the
  server sends mail and the address is verified; typing a password stays only otherwise,
  with the reason under the button. The account panel's two lines about a password are
  reworded for such accounts. `wiki-server users password` stays the operator's way in.
- **WP5.7 Spike: `persistent` + `esqueleto` over SQLite and PostgreSQL** (the owner,
  2026-10-27, proposed). Time-boxed: port the users, groups and grants part of
  `Wiki.Server.Storage.Rows` to entities and esqueleto over `SqlBackend`, with
  `persistent-sqlite` and `persistent-postgresql` both running the backend contract tests;
  migrations stay hand-written and versioned, with a per-database branch where SQL differs
  (the ~15 SQLite-only statements: `INSERT OR IGNORE/REPLACE`, `COLLATE NOCASE`, `rowid`,
  the PRAGMAs and the backup API, which stay the SQLite backend's); search stays in
  Haskell. The report says what the port costs in code, how joins read, what esqueleto
  cannot say, and whether to go on. Not merged unless the owner decides so.
- **WP5.8 The export as a tree** (the owner, 2026-10-27, proposed): format version 2 of
  `docs/export.md`, a zip whose spaces, subspaces and pages are directories
  (`spaces/<slug>/space.json`, `…/pages/<slug>/page.json` + `page.md`, `attachments/`,
  `comments.json`, pages' subpages and spaces' subspaces nested), comments included (authors
  by login and name, matched by login on import), histories still out; import reads
  versions 1 and 2, the demo and the server through the same `Wiki.Core.Export`.
- **WP5.10 Letters TikZJax's fonts lack** (the owner, 2026-10-27, from a page whose
  `ylabel={payoff (zł)}` showed "Cannot read properties of undefined (reading 'toString')").
  TikZJax draws with Computer Modern in OT1 only: `ó é ß –` work, `ł`/`\l` crash dvi2html on
  a glyph missing from its OT1 table, `ą ę` (`\k`) are "unavailable in encoding OT1", `ü`
  fails with "Could not find font metric for 127". So: a readable error that names the
  letter instead of the crash; Polish letters and the German umlauts drawn (the OT1 glyph
  table patched at bundle time for `ł Ł` and the accent at 127, an OT1 `\k` defined in the
  preamble for the ogoneks, or whatever draws them), each letter checked by the smoke test
  against the real TikZJax; `docs/markdown.md` says what letters a picture can hold.
- **WP5.11 The chat's liveness, its close button, the default effort** (the owner,
  2026-10-27): "Thinking…" with animated dots from Send to the first token, a status line
  while a tool runs ("Editing the page…" with the change's note), a cursor on streamed text,
  a time on each message and the answer's duration, a seconds counter when nothing has
  arrived for a while, Anthropic's `thinking.display: "summarized"` shown under "Thinking…";
  a labelled "Close" button in the panel's header instead of the ×, Esc in the message box
  closes too; an "Effort" default per provider on the settings page (`medium` on both
  providers, instead of today's `low`), the picker under the chat changing it for the
  conversation only.
- **WP5.12 Comments in plain English** (the owner, 2026-10-27, after reading `Cache`'s
  haddock: "nie mam pojęcia co to znaczy"). The convention in `AGENTS.md` now says comments
  are plain, direct English with the thing's name and ordinary words first; this package
  rewrites the haddocks and comments that fail it, module by module, `wiki-app` and
  `wiki-server` first, with no change to code; a first PR of a few modules for the owner
  to judge the tone, then the rest.
- **WP5.13 The wasm build's time: `Shell`'s slots and the `.dyn_o` objects** (the owner,
  2026-10-27: "21 GB to w pizdu, spróbujmy to i te .dyn"). Confirm that `Wiki.App.Shell`'s
  28-label `Slots` row is what the simplifier spends 75 s and 14.6 GB on, then restructure
  (the route's page as one sum-typed slot, the shell's chrome in sub-components with small
  rows), no flags; measure `shared: False` and its variants for the `.dyn_o` objects and
  apply what works; measure one `hh` view to say where its typecheck time goes.
- **WP5.14 No page cache past the first render; page lists without bodies** (the owner,
  2026-10-27). The owner found a tab can show a page without someone else's edit (the live
  channel tells a tab only about the pages it shows). Three designs were read against the
  code (a subscription window of the last 10 pages; stale-while-revalidate; no page cache
  after the preload) and the owner chose the last: `Cache` is a preload that answers reads
  until the first route change, then page content always fetches; session, spaces, own
  drafts, immutable versions and live notices stay. With it, `listPages` stops carrying
  every page's body (summaries; the body from `getPage`). Tests: an end-to-end with two
  sessions (A views X then Y, B saves X, A returns and sees B's text after one fetch),
  hydration at zero repairs.
- **WP5.15 Newtypes where `Text` carries a URL, an e-mail, a login, a file name, a token**
  (the owner, 2026-10-27, "używamy mega dużo Text zamiast newtypów"; proposed): an
  inventory of `Text` fields in `wiki-api` and `wiki-core`, a newtype with a parser at the
  boundary where the value has rules of its own.
- **WP5.16 Scalability audit** (the owner, 2026-10-27, "przejrzyj cały kod na rzeczy które
  się nie skalują na dużo userów i stron"): a read-only review, findings ranked by impact
  with evidence, each with the smallest fix; packages cut from it.
  Done the same evening: `docs/scalability-audit.md` (14 findings with code locations,
  estimates and the smallest fix each; what is fine listed too). The top of the ranking: one
  SQLite connection held for every request, backup, import and export (WAL is on, the MVar
  defeats it); every page view a full server render that reads the whole space ~10 times and
  embeds it in the HTML; every save loading every user, watch and grant and scanning the whole
  notifications table per recipient (`max(seq)` with no index); the live hub doing one
  permission transaction per event per subscriber; search folding every page of the wiki per
  keystroke; sitemap and feeds reading the whole public wiki with bodies per request; the
  bell locating up to 500 notifications with a whole-space node load each. Cut into waves,
  one agent at a time on the storage layer:
  - **WP5.16a** (findings 1, 3, 6, 4): read connections beside the one writer, the backup's
    `VACUUM INTO` and `resolveSession` off the writer; an index on `notifications (seq)` and
    `tellTx` loading only the users who could be told; the bell counting unread in SQL and
    locating 50, not 500; one permission check per user per publish, jittered reconnect.
  - **WP5.16b** (5, 7, 8, 9, 11): the fold stored at save and matched in SQL by space; a
    node-only sitemap and cached feeds; `WHERE user_id = ?` / `WHERE login IN` instead of whole
    tables, indexed path resolution, `max-age` on attachments, `pages (space_id, template)` and
    `group_members (user_id)` indexes; the first-version join instead of every version,
    `listVersions` paged; the audit log's actor query and keyset paging.
  - **WP5.16c** (10, 12, 13): streamed export, `Tmp` multipart, metrics from the table, the
    demo reading attachments and versions lazily.
- **WP5.17 Small fixes found in the night of 2026-10-27** (the owner, 2026-10-28, "zrób
  wszystko oprócz polskiego"): Anthropic's 400 "This model does not support the effort
  parameter" (Claude Haiku 4.5) makes the island resend without `output_config` and leave
  it out for the rest of the chat, as it does for `thinking`; `test-native` no longer
  needs the caller to set a UTF-8 locale (the toolchain scripts set `LANG=C.UTF-8` when
  the locale is unset or `C`/`POSIX`, and the tests that read `docs/markdown.md` read bytes
  and decode UTF-8 themselves); `withDraft`'s `Maybe (Either WikiError (Maybe Draft))`
  becomes a named type (the owner: "`Right (Just Nothing)` is just insane, this needs a
  custom datatype"); the two comments WP5.12 left as found are made true (`Cache`'s module
  comment on choosing a watch, `Backend.attempt`'s list of reads that throw); and, the
  owner's review of #93 ("Forbidden should be before NotFound; otherwise unknown user can
  extract knowledge which pages exist"): a space the principal may not view, and
  everything under it, answers `NotFound` exactly as a space that does not exist; a space
  the principal may view but may not change answers `Forbidden`. The administration's
  order (the global administer checked before any id) stays.
- **WP5.18 Accounts with a password only from the console** (the owner, 2026-10-27, "Dałbym w
  admin opcje wyłączania tworzenia password based użytkowników, zostawiając to tylko przez
  CLI serwera"): a wiki setting, on by default, "The administration may create accounts
  with a password"; when off, the administration's "New user" form is replaced by a note
  that says to use `wiki-server users add` on the console, and the API's `createUser`
  refuses; sending a password link to an existing user and the console are unaffected.
- **Flat element rows in haskell-halogen's `DOM.HTML.Indexed`** (from WP5.13's
  measurement: an element with no attributes costs 88 ms to type-check against the
  `.+`-chained row, 4.5 ms against the same row written flat; `hh` emits a bare `[]` for
  such elements): a package in the haskell-halogen repository, then a pin bump here with
  the `hh` views' type-check times before and after. The owner (2026-10-28, on seeing the
  first commit's generated modules: "rozwijanie tych rows jest ciężkie w utrzymaniu") chose
  Template Haskell at the definition site over a generator: the groups stay readable
  Haskell and each element row is one splice that expands, merges and sorts them; nothing
  generated is kept in the repository. A GHC plugin was weighed and rejected: the cost is
  at the use sites, so a plugin would have to be enabled in every consumer, and plugin
  loading on the wasm and JS cross-compilers is fragile.

- **WP5.20 Steps on a slide: `. . .`, `::: incremental`, and `\pause` in the exports** (the
  owner, 2026-10-28: "żeby prezentacje się ładnie do PDF robiły, łącznie z przejściami (mamy w
  ogóle support do \pause?)"). pandoc's own markers, so the exports get it almost for free:
  `. . .` on a line of its own cuts a slide into steps, and a box with the class
  `incremental` shows a list one item at a time; on an ordinary page both change nothing.
  Presenting: the right arrow (Space, PageDown) shows the next step before the next slide,
  the left arrow hides it or goes back a slide; the step is in the address
  (`?slide=3&step=2`); the overview and the print show whole slides, with a "each step on
  its own page" choice in the print. Exports: pandoc writes `. . .` as `\pause` in Beamer
  (one PDF page per step, which is what a "transition" in a PDF is; viewers show no
  animated transitions worth having) and as a step in PPTX, and `incremental` as
  `\item<+->`; DOCX, HTML and EPUB ignore both. Tests: `Wiki.Core.Slides` cutting steps,
  hspec-halogen for the keys and the address, the server's export test finding `\pause` in
  the Beamer source. `docs/markdown.md`'s "Presentations" says it, and the demo's
  "Presentations" deck (`Wiki.App.Demo`, the page under the Markdown guide that teaches
  presenting by being a deck) gains a slide or two that use `. . .` and `::: incremental`
  and say what they do (the owner, 2026-10-28: "zaktualizować tutorial prezentacji"); the
  README's "Presentations" section mentions steps too.

- **WP5.21 Content Security Policy for the application, and the assistant's keys in a
  passkey-locked vault** (the owner, 2026-10-28, after asking what XSS has to do with the
  keys: "Zróbmy oba naraz, jeśli to zwiększy bezpieczeństwo", one agent for both). Two parts,
  one package, one pull request.

  **A. A Content Security Policy for the application page.** Today only an attachment shown
  in the browser and an exported document carry a policy (`Wiki.Server.Api`); the page
  itself, with CodeMirror, Mermaid, KaTeX, TikZJax, highlight.js and two provider SDKs in
  one bundle, carries none. The policy makes a bug in that supply chain, or in the raw HTML
  allowlist, "does not work" instead of "works for the attacker": no script from another
  origin, no `eval` in a library, no `<base>`, no form posted elsewhere, and a stolen key with
  nowhere to go by `fetch`. It does not close every channel (a script already running can
  still navigate or load an image from anywhere, and pages may embed images from any
  `https:` address, `Wiki.Core.Markdown.Link.safeSrc`, so `img-src` stays wide); the first
  defence stays the allowlist. The policy, sent by the server as a header on the page
  (`Wiki.Server.Static`) and carried by the demo (served by GitHub Pages, which sends no
  headers) as a `<meta http-equiv>` with the same text, so the two stay one: `default-src
  'none'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self' <providers>; img-src
  'self' https: data: blob:; media-src 'self' https: blob:; style-src 'self'
  'unsafe-inline'; font-src 'self' data:; worker-src 'self' blob:; manifest-src 'self';
  object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'`, adjusted
  to what the islands and the service worker actually need (measured, not guessed: the
  browser test page carries the same policy, so a directive the islands need and the policy
  lacks fails a test). `'unsafe-inline'` for styles is what KaTeX and Mermaid need;
  `'wasm-unsafe-eval'` is what `app.wasm` needs; neither is given to scripts.
  `<providers>` is `https://api.anthropic.com https://api.openai.com` plus the addresses an
  administrator lists for the assistant's own base URLs (`ProviderSettings.baseUrl`: Ollama,
  LM Studio, a proxy), a server setting (`--assistant-hosts`, and the server settings page)
  that the server folds into the header; a base URL outside the list is refused by the
  browser, and the assistant's settings say so ("Test the key" reports that the address is
  not allowed by this wiki, with the administrator's list to extend). The sign-in pages the
  server renders itself (`Wiki.Server.Auth`) get the same policy (a provider's sign-in
  starts from a link and a redirect, which `form-action` does not govern, as the review
  found; the first head had a policy of their own for it, since removed). `X-Content-Type-Options: nosniff` already;
  add `Referrer-Policy: same-origin` and `Permissions-Policy` turning off camera, microphone,
  geolocation. Tests: the server's static test finds the header on the page and not on
  `app.wasm`; the browser suites run under the policy (`wiki-app/test/web/index.html` carries
  the meta) so Mermaid, KaTeX, TikZ, highlighting, the editor, the assistant with a test
  fetch and the service worker prove they work under it; a test that a page with `<img
  onerror>` and `<script>` in raw HTML runs nothing (the allowlist already guarantees it;
  the test keeps it). CI gains `npm audit --audit-level=high` on the lockfile, failing the
  build on a known vulnerability in a dependency that ships in the bundle (a dev-only
  finding is reported, not fatal), so the supply chain is at least checked.

  **B. The assistant's keys in a vault unlocked by a passkey** (the "later" note below,
  picked up today). The keys stay out of the server's sight; they stop lying in IndexedDB
  as text and follow the user across devices with one touch. Mechanism: a random vault key
  (AES-GCM, WebCrypto) encrypts the assistant settings (`Wiki.Core.Assistant.Settings`:
  keys, models, efforts, base URLs; not the fetched model lists); the vault key is wrapped
  with a key derived (HKDF-SHA256) from the WebAuthn PRF extension's output for a passkey
  registered with the wiki as the relying party and a salt chosen per user; the server
  stores, per user, the ciphertext, the salt, and one wrapped copy of the vault key per
  passkey (`api/v1/assistant/vault`: `GET`, `PUT`, `DELETE`, and the passkeys under it). The
  PRF output is in the client extension results, never in the signed assertion, and the
  client never sends it. On this device the vault key is kept in IndexedDB as a
  non-extractable `CryptoKey` and the plain key is deleted; at use, the settings are
  decrypted in memory. A device setting "ask for the passkey each time the wiki opens" keeps
  no vault key at all (only the ciphertext on disk; one touch per browser start). Without
  synchronisation the same vault format is used locally with a vault key kept
  non-extractable (the same code; the plain key never stored again), which is what the demo
  does too (no server; the "sync" controls are hidden there). The user's flow: in the
  assistant's settings, "Sync across devices: off" with "Turn on with a passkey" (the
  browser's own dialog; a passkey without PRF is reported, "This passkey cannot sync the
  keys", and removed); on a new device the assistant offers "Unlock with passkey" and, in
  smaller type, "or type a key here" (a key typed locally does not overwrite the vault
  until it is unlocked); a changed key on any device is re-encrypted and `PUT`, other
  devices pick the new version up at the next start by ETag and decrypt it with their
  cached vault key, no touch; "Add passkey" (on an unlocked device only), a list of passkeys
  with "Remove", "Turn off" (deletes the vault on the server, needs no passkey, the way back
  after losing every passkey; keys stay where they are locally). WebAuthn on the server is
  written here, not taken from a package: registration with attestation `none` (the
  attestation statement is not verified; the credential id and COSE public key, ES256 and
  RS256, are taken from the authenticator data, parsed with `cborg`), assertion
  verification with `crypton` (challenge from the server, origin and relying-party id hash,
  user-presence flag, signature over `authenticatorData || SHA-256(clientDataJSON)`,
  sign count kept and a decrease reported). Registration and assertion are tied to the
  signed-in session; they do not sign the user in (a passkey sign-in is a later package on
  the same table). The relying-party id is the wiki's host; WebAuthn needs HTTPS
  (localhost excepted), so the setting is hidden on plain HTTP with a sentence why. Client
  side through `browserJS` (`navigator.credentials`, WebCrypto), no SDK. Tests: pure
  (`Wiki.Core.Assistant.Vault`: the format, versioning, that a removed passkey's wrapped
  copy is gone), server (registration and assertion with a fixed ES256 key pair signing as
  an authenticator would, a wrong origin, a wrong challenge, a replayed sign count, access
  by another user), browser (hspec-halogen with `navigator.credentials` replaced by a stub
  in the test page that computes a deterministic PRF from the salt, since the harness has
  no CDP virtual authenticator: turn on, unlock on a "second device" (a fresh IndexedDB
  database), change a key, "ask each time", turn off); the real browser dialog is checked by
  hand and said so in the report. Migration for the passkeys and the vault.
  `docs/assistant.md` (or where the assistant is documented) gains "Keys across devices".

- **WP5.23 The browser's HTTP client derived from the API type: `servant-client-core` over
  `fetch`** (the owner, 2026-10-28, reviewing #108: "we are hand rolling our own request
  types, there are packages like `http-client`!"; `http-client` needs `network`, which does
  not build for wasm32-wasi, so the answer is servant's own client core; the owner: "Zleć to
  w następnym PRze"). `Wiki.App.Backend.Http.Request` (its `Request`, `Body`, `Response`,
  the hand-written multipart form) and the hand-written calls of `Wiki.App.Backend.Http`
  (`R.get links.account.email` and the ~790 lines around it) go away. In their place:
  `servant-client-core` (pure Haskell, builds on wasm; `wiki-api`'s `WikiApi` is already a
  servant type) with a `RunClient` instance for the HTTP backend's monad whose transport is
  `Halogen.Net.Fetch` in the browser, the API's WAI application in the same process in the
  server's tests (as `Wiki.Server.Test.Http` does today), and a scripted transport in the
  application's own tests; `servant-multipart-client` for the attachment and archive
  uploads. The client functions come from `client`/`genericClient` on `WikiApi`'s records,
  so an endpoint that changes in `wiki-api` changes its client at compile time, and the
  application cannot send a request the API does not declare (today `Wiki.Api.Links` only
  guarantees the path). What the hand-written code did that servant's core does not must be
  kept and is the package's real work: the session re-check after a 401/403 (`call`), the
  request time limits (`timeLimit`, `uploadTimeout`), the `If-Match`/`If-None-Match`
  headers (as API combinators in `wiki-api`, so the server declares them too), reading a
  refusal's `ApiError` body into `WikiError` and a 2xx with a wrong body into
  `Unreachable` (`answer`), the 304 answers of the vault, the `cacheOnly` mode and the
  silent transport for a prerendered page. `Wiki.Api.Links` stays for the addresses the
  application puts into the page (attachments, exports, search) and for the server's tests
  of the API, which name endpoints with `links` some five hundred times and had to pass
  unchanged (amended at the merge: the first wording said it "loses the rest"); the
  application's own requests no longer use it. The
  server's tests of the API keep passing unchanged, which is the check that the wire format
  did not move; the application's native tests of the backend (`Test.Backend.Http`,
  `Test.Server.Http`) and the browser tests (`Test.Browser.Http` with `test-fetch.js`) keep
  their coverage on the derived client. Not in scope: changing any endpoint, or the
  server's side of the API.

- **WP5.24 Transactions: a bracket, and the permission context loaded once** (merged
  2026-10-29, PR #111; see Progress) (the owner,
  2026-10-29, reading the storage: "Nie widzę żebyśmy używali bracketingu używając bazy
  danych", and "Tak" to the fix; the second part is what WP5.22's bench left for later).
  Two parts, one pull request.

  **A. `withTransaction`.** Connections are bracketed (`Data.Pool.withResource`, `bracket`
  around a backup's own connection, `withStorage`), transactions are not: the four
  wrappers (`writingEither`, `reading`, `transactThenFrom`, `readWithin` in
  `Wiki.Server.Storage`) call `begin` outside any handler and wrap the body and the commit
  in `rollBackOnError` by hand, so the invariant "a connection goes back to the pool with
  no transaction open" holds only because every exception also reaches `withResource`,
  which closes the connection. One function in `Wiki.Server.Storage.Backend`:
  `withTransaction :: Backend be => Bool -> Connection be -> IO a -> IO a`, `mask`-based
  (begin; the body under `restore` with a rollback on exception; the commit with a rollback
  on exception), and a variant for a body that returns `Either` (rollback on `Left`, as
  `writingEither` and `transactThenFrom` do); the four wrappers on it; `rollBackOnError`
  gone; `retrying` unchanged (a retryable failure is rolled back inside the bracket and the
  connection kept). Behaviour otherwise unchanged. Test: an exception in the body and an
  exception in the commit each leave the connection with no transaction open (a `BEGIN`
  right after succeeds; on PostgreSQL `pg_stat_activity` shows the connection idle, not
  "idle in transaction"), on both backends.

  **B. The permission context loaded once per generation.** Every transaction begins with
  `context`: every space, every grant, the active user and their groups (settings and
  server settings are already kept in `IORef`s). That is 15 of the 29 statements of a
  page view on PostgreSQL (WP5.22's bench) and is the same data on every read until a
  write changes it. The storage keeps a generation (`IORef Int`) that every committed
  write transaction bumps when it changed spaces, grants, users or groups (the operations
  that do are known: the storage records on the `Ctx` that the transaction touched a
  permission table, and the commit path bumps; a test enumerates the operations that must
  bump, so a new one cannot be forgotten), and a cache: the spaces and grants of the
  current generation, and the active user with their groups per (generation, user),
  bounded (an LRU of a few hundred users, or cleared on a bump). `context` reads the cache
  when its generation is current and loads from the database otherwise, inside the
  transaction, so a reader still sees one state. Writes always read fresh (the writer is
  one connection and the cache is bumped by it; the writer's own transaction loads the
  context from the database to see its own earlier writes within a `retrying` attempt).
  `readWithin` (a chain of spaces) is covered the same way or left as it is if it loads
  less than the cache would give; reported. One process only: a second server instance
  would need the generation shared (`LISTEN/NOTIFY`, noted for the multi-instance package);
  the console (`wiki-server users …`) writes in another process against the same database,
  so a running server must notice: the generation is also a row in the database
  (`permissions_generation`, bumped in the same write transaction), read with one cheap
  statement at the start of each read transaction and compared with the cached one. That
  statement is the price: a page view goes from 29 to about 14 statements on PostgreSQL,
  measured with `wiki-server-bench` on both backends before and after, numbers in the
  report and in the Progress entry. Tests: the cache is used (statement counts in the
  Scale suite drop as computed), a grant change on the writer is seen by the next read, a
  change by another process (a second `Storage` on the same database in the test) is seen
  by the next read, a user's group change is seen, a disabled user is refused at once.

- **WP5.25 (merged 2026-10-29, PR #112; see Progress) The administration as pages: a left navigation, one section per page, users
  paged with one "Manage" dialog** (the owner, 2026-10-29: "lista na adminie robi się za duża
  wzdłuż i wszerz. Niech strona ma podzakładki z lewej jak spaces, każda osobno (data,
  access, user management, etc.). Niech users ma listę z max per page i pages, i zamiast
  tych przycisków jeden przycisk 'manage' gdzie otwiera się okienko wszystkich opcji dla
  usera. Zrób to ładnie"). Today `/admin/` is one long page that mounts the people
  (`View/Admin.hs`: users and groups), the server settings (`View/Server.hs`), the global
  permissions (`View/Permissions.hs`), the backups (`View/Backups.hs`) and the activity,
  one under the other, and every user row carries every button. After: the route gains a
  section, `/admin/<section>/` (`Route.Admin AdminSection`, the first section when none is
  given, with a redirect from `/admin/`), and the administration is a two-column layout: a
  left navigation like the spaces directory's column (the same width, type and spacing as
  the rest of the application; on a narrow screen it becomes a strip of tabs above the
  content), with one entry per section, the current one marked and in the document title,
  and the section's content on the right. Sections, in this order: **Overview** (the
  status: counts, the last backup, errors; what "Status" shows today), **Users**,
  **Groups**, **Permissions** (the global grants), **Invitations** (if they are a part of
  the people page today, else under Users), **Server** (public address, mail, sign-in
  providers, the assistant's hosts), **Backups**, **Activity**. Each section is the
  existing component mounted alone, with its own loading and errors, so a slow section
  does not hold the others; nothing a section does changes in this package beyond the
  users list. Users: a table paged on the server (`GET admin/users` with `offset`, `limit`
  and `q`; the directory endpoint stays for what else needs it), a page size the reader
  chooses (25, 50, 100; remembered in `localStorage`), page numbers with first/previous/
  next/last, a search box over login and display name (debounced, in the address as `q`
  and `page` so a page can be shared), a filter for administrators and disabled accounts,
  the count ("1–25 of 312"). Each row: display name, login, how they sign in (password,
  provider, both), badges (administrator, creates spaces, second factor, disabled), the
  last sign-in if the directory knows it, and one button, **Manage**. Manage opens a
  dialog (`role="dialog"`, `aria-modal`, focus trapped, Escape and the backdrop close it,
  focus returns to the button) with everything the row's buttons did: administrator,
  creates spaces, disable, set a password, send a password link, remove the second
  factor, unlink an identity, the e-mail address, group membership (add to a group, remove
  from one), each change saved at once with a short "Saved" and the row refreshed, and
  the account's dangerous actions (disable, remove the second factor) asked once, and,
  after disabling, **Remove the account** (the owner, 2026-10-29: "after 'disable' can we
  add an option to 'remove'?"): offered only for a disabled login, never for one's own
  account, confirmed by typing the login; `DELETE admin/users/:id` ends the sessions and
  deletes the account row with what belongs to it (grants, memberships, passkeys and the
  vault, watches, notifications, invitations it sent), while the pages, versions and
  comments the person wrote stay, attributed to the login as text and shown as a former
  user (the schema's author references become nullable with the login kept beside them,
  or the equivalent the storage already has); the login is free to be taken again; the
  activity log records the removal; the console gets `users remove LOGIN`. The
  dialog is one component with its own state, reusable for the per-user settings a later
  package adds (the assistant's access, WP5.26). Design: the owner asked for it to be
  nice, so care is part of the work: consistent spacing and type with the rest of the
  application, light and dark, hover and focus states, no layout jump when a page loads,
  a quiet empty state, the dialog centred with a backdrop and a width that fits its
  content, buttons grouped by what they do, the destructive ones apart and in the danger
  style. Screenshots of the users page and the dialog (light and dark) go into
  `docs/screenshots/` through `toolchain/screenshots.mjs` and into the pull request. Tests:
  hspec-halogen for the navigation (each section mounts alone, the address changes, the
  first section opens from `/admin/`), the paging (page size, page numbers, search in the
  address), the dialog (opens with the user's state, saves one change, closes on Escape
  and returns focus, a dangerous action asks); server tests for the paged users endpoint
  (order, paging, search, filters, bounds on `limit`). The README's administration section
  and `docs/api.md` are updated.

- **WP5.26 The assistant through the wiki's own identity: Workload Identity Federation,
  per user** (not now: the owner, 2026-10-29, "federacja nie musi być teraz"; the plan text
  stays for when it is picked up) (the owner, 2026-10-29, after the question whether users signed in through
  Google or GitHub could reach Claude without a key: "to zróbmy to. Niech będzie tak że
  można to ustawić w ustawieniach admina, i każdemu userowi można włączyć opcję, czy może
  korzystać z klucza serwera"). Anthropic's Workload Identity Federation exchanges a
  short-lived JWT from a registered OIDC issuer for an Anthropic access token bound to a
  service account of the organisation that registered the issuer; the organisation pays
  and the token is as powerful as a workspace API key (`workspace:developer`). So this is
  the "organisation pays" model, in its best form: no static key anywhere, tokens that
  live minutes, per-user switching on and off, and the wiki is the identity provider. The
  wiki as an OIDC issuer: under the public address it serves
  `/.well-known/openid-configuration` and `/.well-known/jwks.json` (one ES256 key pair,
  made when federation is first turned on and kept as a `Secret` in the server settings,
  the JWT signed and the JWKS written with the `jose` package, nothing by hand;
  a "new key" button rotates it, the old public key stays published for an hour). For a
  user allowed to, `POST api/v1/assistant/token` mints a JWT (`iss` the public address,
  `sub` the user's id, `aud` `https://api.anthropic.com`, `exp` five minutes, a random
  `jti`, since Anthropic takes each `jti` once), exchanges it at
  `https://api.anthropic.com/v1/oauth/token` (`jwt-bearer` grant, with the federation rule,
  organisation, service account and workspace ids from the settings) and answers the
  browser with the access token and its `expires_in`; the server keeps no token. The
  browser's assistant gets a provider choice "Claude through this wiki" when the user is
  allowed, uses the token as the SDK's `authToken` (Bearer) and asks for a new one before
  it expires; the user's own keys and the vault (WP5.21) stay for the other choices. In
  the administration (WP5.25's Server section, or a section of its own, "Assistant"):
  turned on or off; the organisation, workspace, federation rule and service account ids;
  the issuer URL and the JWKS URL shown to copy into Anthropic's console (the console's
  "Custom OIDC" issuer with discovery, a rule matching `audience` and a `subject_prefix`);
  a "Test" button that performs one exchange and reports the result or Anthropic's
  reason; a sentence that the organisation pays for every user allowed, with a link to
  spend limits, and that a workspace of its own for the wiki is the safe setting. Per
  user, in the Manage dialog of WP5.25: "May use the wiki's assistant access", off by
  default, stored with the user (a migration per backend); the token endpoint refuses
  everyone else with `Forbidden`. The activity log records each token issued (user, time)
  so an administrator sees who uses it; usage caps per user are a later decision. The
  Content Security Policy already allows `api.anthropic.com`. OpenAI has no equivalent,
  so this is Anthropic only. Tests: server (the discovery document and the JWKS; the JWT
  verifies against the published key and carries the claims; the exchange against a fake
  Anthropic in the test that fetches the JWKS, verifies the signature and the claims, and
  answers a token; a user not allowed gets `Forbidden`; a `jti` is never reused; the key
  rotation keeps the old key published), browser (the provider choice appears only when
  allowed, the token is used as Bearer and refreshed, a refusal is shown), the admin's
  settings and the per-user switch. The README gets "The assistant through the wiki's
  identity" with the console steps; `docs/api.md` the endpoints.

  **Also in this package, the assistant's modes** (the owner, 2026-10-29: "do edytora
  asystenta dodać opcje auto-approve edits (z timeoutem), agent/ask mode - może być w tym
  samym"). Today the model edits the page through its tools as tracked changes and the
  author accepts or rejects each, or all at once. Two settings in the assistant's panel,
  kept per user with the assistant's settings: a **mode**, *Ask* (the model answers and
  may propose, with its tools off: a proposed edit is shown as a quoted suggestion with
  an "Apply" button that makes the tracked change) or *Agent* (as today: the model edits
  as tracked changes), the mode shown in the message box and switchable there; and
  **auto-accept** for Agent mode, off by default: a tracked change the author has not
  touched is accepted after a timeout the author chooses (10 s, 30 s, 1 min, 5 min),
  with a visible countdown on the change and on the panel's "n changes" line, stopped by
  the pointer entering the change or the author rejecting it; "Reject all" stops every
  countdown. Nothing is saved by auto-accept: saving stays the author's, as the editor
  says next to Save. Tests: hspec-halogen for both modes, the countdown and its stops,
  the setting kept across a reload; the mode and the timeout are part of the vault's
  settings (WP5.21) so they follow the user across devices.

- **WP5.27 Libraries over hand-rolled code: the review** (merged 2026-10-29 with WP5.24,
  PR #111; see Progress) (decision 25, the owner,
  2026-10-29; folded into WP5.24's branch and pull request the same day, "cleanup może być
  szybciej, dodaj nawet do 24 bo to taki refactor": the WP5.24 agent does it after its two
  parts, one replacement per commit). The code written by hand before the rule, each judged against a maintained
  package: `Wiki.Server.WebAuthn` (343 lines; `webauthn` 0.12 on Hackage covers
  registration and assertion with attestation formats and COSE keys), the ID token reading
  in `Wiki.Server.Oidc` (`jose` for the JWT, the discovery and the token exchange kept, or
  an OIDC client package if one is maintained), `Wiki.Server.Totp` (171 lines of RFC 6238
  over crypton; `otp-authenticator` or a maintained alternative), `Wiki.Server.Limiter`
  (109 lines; a rate-limiting package if one fits), `Wiki.Server.Address` (the proxy
  headers; `wai-extra`'s middleware), the service worker and its registration
  (`web/src/sw.js`, `pwa.mjs`, ~500 lines; Workbox), and the JavaScript under
  `wiki-app/jsbits/` and `web/src/` line by line: what is glue around a library stays,
  what reimplements one goes. For each: replaced, or kept with the reason (no maintained
  package, does not build on wasm, the package does less than the code needs), recorded
  in the Progress entry. Behaviour unchanged, the existing tests prove it; a replacement
  that changes a wire format or a stored value is not one.

- **WP5.28 (merged 2026-10-29, PR #113; see Progress) Completion for `@` mentions in the editor** (the owner, 2026-10-29: "musisz dodać
  podpowiadanie do @ mentions"). The editor (CodeMirror 6, `web/src/editor.js`) gets
  completion from `@codemirror/autocomplete` (the library; nothing written by hand beyond
  its source function and the styling of its list): typing `@` followed by letters opens a
  list of users whose login or display name starts with what was typed, display name
  first and login after it, at most ten, chosen with the arrows and Enter or Tab (Escape
  closes), which inserts `@login` and a space; the list follows the same rule as the
  renderer (`Wiki.Core.Markdown.Mention`: not inside code, links or embeds, which the
  source checks with the syntax tree). The names come from a new endpoint
  `GET api/v1/notifications/people/search?q=<prefix>` (declared in `wiki-api`'s
  `NotificationsApi` beside `people`, called through the derived client), for someone
  signed in only (a visitor gets an empty list, as `people` does), answering logins and
  display names of enabled users, prefix on either, case-folded, at most ten, ordered by
  display name; served from the storage with one indexed query (a shared `Rows` function
  with WP5.25's paged users if that has merged, else its own). The editor asks after a
  short debounce (`@codemirror/autocomplete`'s own, not ours) and the source caches the
  answers for the editor's life. Comments: the comment box is a plain textarea, not
  CodeMirror; it gets the same completion only if `@codemirror/autocomplete` can be
  attached to it cheaply, else it is noted for later. The demo's in-memory backend
  implements the search over its users. Tests: server (the endpoint: prefix on login and
  on display name, folded, a disabled user left out, the limit, a visitor's empty answer),
  browser (hspec-halogen: typing `@an` shows the matching users, Enter inserts `@anna `,
  nothing opens inside a code fence or a link, Escape closes), and the native test of the
  editor's JavaScript if the editor has one. `docs/markdown.md`'s mentions section says
  that the editor completes them; `docs/api.md` the endpoint.

- **WP5.29 (merged 2026-10-29, PR #114; see Progress) Boxes of your own, and the guide on every server** (the owner, 2026-10-29:
  "gdzie jest lista znaczników typu [!TIP]? chyba nie ma tego w guide. Da się dodać swój,
  np exercise?" and "zróbmy też by default że serwer wyświetla też guide. Na świeżym
  serwerze nie mam teraz tour/guide'a"). Two parts, one package.

  **A. Boxes.** Today `> [!NOTE]` takes GitHub's five kinds (`AlertKind` in
  `Wiki.Core.Markdown.Ast`: note, tip, important, warning, caution) and any other box is a
  fenced div `::: name` with a class and no look; `docs/markdown.md` says so under "Notes
  and boxes", the guide page in the wiki says nothing. After: `> [!KIND]` takes any kind.
  The five keep their look; another kind (`[!EXERCISE]`) is a box with the class
  `alert-exercise`, the title "Exercise" (the kind's name, capitalised), and a neutral
  look, unless an administrator has defined it: the server settings gain "Boxes", a list
  of kinds, each with a name, a label (the title shown), a colour from the theme's palette
  (the same accents the five use, by name, so light and dark both work) and an icon from
  a fixed set; the renderer gives the box the class and the label, and the colour and the
  icon come as CSS custom properties on the box, so the stylesheet needs no change per
  kind. An optional title after the marker (`> [!EXERCISE] Exercise 3`) replaces the
  label for that box, for the five kinds too. `AlertKind` becomes the five plus
  `Custom Text`; the exports: pandoc writes the five as its alerts (as today) and the others
  as fenced divs with the class, so DOCX, HTML and Beamer get a plain box with the title.
  The demo's settings and the guide: the in-wiki Markdown guide gets a "Notes and boxes"
  section (the five, an own kind, the title), and the demo defines one kind, `exercise`,
  to show it. Tests: parsing of a custom kind and of a title, rendering (class, label,
  properties), the settings' validation (a name is letters and dashes, lower case, not one
  of the five), the exports, the guide text.

  **B. The guide on every server.** The demo's Tour, Markdown guide, Diagrams, Mathematics
  and Presentations (`Wiki.App.Demo`) are the wiki's documentation, and a fresh server has
  none of it. The texts move to a module of their own that both the demo and the server
  use (`Wiki.App.Guide`: the server already depends on `wiki-app`), with two tours: the
  demo's (choosing a user, resetting the content) and the server's (signing in, your
  spaces, editing, the assistant, where the administration is). On its first start with
  no spaces, the server creates a public space "Guide" (slug `guide`, readable by everyone
  the wiki is open to, editable by administrators) with those pages and their
  attachments, in one transaction, by the same path as an import; `--no-guide` skips it.
  Afterwards: `wiki-server guide install` puts it back if it was deleted, and
  `wiki-server guide update` writes a new version of each guide page whose text differs
  from the current release's (page history keeps what was there; a page an administrator
  renamed or moved is left alone and named in the output), run by the deploy after a new
  server starts, so the guide follows the wiki's version; the administration's Overview
  shows "Install the guide" when the space is missing. The tour's first page links the
  Markdown guide and says where the administration is. Tests: the server's first start
  makes the space with the pages and attachments (and not twice; not with `--no-guide`);
  `guide update` changes only pages whose text changed and leaves a renamed page alone;
  the demo still shows its own tour; the deploy test covers the call.

- **Later, by the owner (2026-10-28, "PRF jest spoko na później"), picked up the same day as
  WP5.21 B: the assistant's API keys synchronised with a passkey.** The keys stay out of
  the server today (IndexedDB per user,
  per device; the administrator never sees them), and the owner does not want to type
  anything, so the only way across devices without trusting the server is a passkey with
  the WebAuthn PRF extension: the key material is wrapped with a key derived from the
  passkey's PRF output (the same on every synced copy of the passkey), the server keeps
  the ciphertext per user (`api/v1/assistant/vault`), a new device unwraps it with one
  touch (Touch ID, Windows Hello, a hardware key) and then caches the unwrapped key as a
  non-extractable WebCrypto key so it never asks again on that device. Rejected on the
  way: a vault passphrase (typing per device, the owner: "równie dobrze mogę wpisywać
  cały klucz"), one key for the organisation ("na pewno nie"), a secret derived from the
  sign-in provider's tokens (the server sees them and they rotate), OAuth to the providers
  (neither offers it to third-party applications), the Credential Management API (Chrome
  only). Needs passkey registration in the wiki (the wiki as the relying party,
  independent of how one signs in) and browsers with PRF (Chrome 116+, Safari 18+,
  recent Firefox).

- **WP5.30 Sign in with a passkey** (merged 2026-10-31, PR #118; see Progress) (the owner, 2026-10-29: "skoro mamy passkeys (wydaje
  się że działa) to może też dodajmy do password-based logowania"; WP5.21 left it as "a
  passkey sign-in is a later package on the same table"). The passkeys WP5.21 registers for
  the vault are already discoverable and user-verified (`residentKey: required`,
  `userVerification: required`), so the same credentials sign in: one list of passkeys per
  account, each signs its owner in, and "unlocks the vault" stays a property of those the
  vault has a wrapped key for. **Registration** moves to where sign-in lives: the account's
  Security panel gets a "Passkeys" section (add one with a name, the list with when it was
  added and last used, remove one), the same two-step registration under
  `account/passkeys/registration` with the same options (discoverable, user verification
  required, attestation none); the assistant's settings keep their "Turn on with a passkey"
  and "Add passkey", which now register into the same list and then wrap the vault key.
  **Sign-in**: the sign-in form gets "Sign in with a passkey" and conditional mediation
  (`mediation: "conditional"` on the login field, so the browser offers a saved passkey as
  the field is focused); `POST session/passkey` answers the assertion options with an empty
  `allow` (discoverable credentials; the challenge is kept server-side for five minutes,
  keyed by itself, no session yet); `PUT session/passkey` takes the browser's answer, finds
  the passkey by credential id, checks the user handle is its owner's id, the origin and
  relying-party id, the challenge, user presence **and user verification** (a passkey
  without the UV flag is refused: the sign-in rests on it), the sign count, and signs the
  user in as `signIn` does (the same `SessionInfo` and cookie, the same audit entry with
  the method `passkey`, the same refusals for a disabled user and a closed wiki). **A
  user-verified passkey is both factors** (possession and the authenticator's own
  verification), so a passkey sign-in skips the TOTP step; decision recorded here. The
  TOTP step of a password sign-in gets "Use a passkey instead": `POST`/`PUT
  session/second-factor/passkey` with `allow` = the pending user's passkeys, completing
  the sign-in like a code. Failed passkey sign-ins count against the address in
  `Wiki.Server.Limiter` (no login is known before the answer), and against the login
  once the credential names one. Provider sign-ins are unchanged. On plain HTTP (not
  localhost) the button and the section are hidden with the sentence WP5.21 uses. The
  demo has no sign-in, so nothing there; `MemWiki` implements the new `MonadSecurity`
  methods as it does the vault's (its test stub). `Wiki.Server.WebAuthn` gains nothing
  hand-written: the `webauthn` package verifies the assertion with the UV requirement set
  in its options. Tests: server (a fixed ES256 pair signing as an authenticator: a
  sign-in succeeds and sets the cookie; refused for a wrong origin, a wrong or expired
  challenge, an unknown credential, a user handle that is not the owner's, no UV flag, a
  replayed sign count, a disabled user, a closed wiki; the rate limit; the second-factor
  step by passkey), browser (hspec-halogen with the `navigator.credentials` stub of
  WP5.21: the button signs in, the second-factor alternative, the Security panel's add,
  list, remove, hidden on plain HTTP), the smoke test unchanged; a real passkey in a real
  browser checked by hand and said so in the report. `docs/accounts.md` (or where sign-in
  is documented) gains "Passkeys".

- **WP5.31 A private feed of one's notifications** (the owner, 2026-10-29: "a mamy
  powiadomienia do mentions, w rss?"; they are in the bell and in mail, feeds exist only for
  public blog spaces). A signed-in user gets an Atom feed of their own notifications at a
  secret address, `GET /me/notifications.atom?token=<token>`: the latest 50 (the bell's
  list), newest first, each entry titled as the bell words it ("anna mentioned you in
  X", "a comment on Y"), with the link the bell follows (the page, the comment's anchor),
  the actor as the author, `updated` at the notification's time, and **no body**: a feed
  read by an outside reader is a copy outside the wiki, so an entry carries the title and
  the link only (decision recorded here; the owner may want excerpts later). The token
  is a secret of the user's (32 random bytes, base64url) in a new `users.feed_token`
  column, made on first use, shown once in the account panel's notifications block with
  the feed's address and "Copy" and "Make a new address" (which replaces the token: the
  old address stops answering), and never in the API's other answers; a wrong or missing
  token is 404, not 401, so the address does not confirm a user; the operator account
  gets none. Served by `Wiki.Server.Feed` as the blog feeds are (the same Atom writer,
  validated against the same RELAX NG schema in the tests), with `Cache-Control:
  private, no-store` and outside `FeedCache` (a private answer is never cached by
  route); nothing about a page the user may no longer read (the same re-check as mail).
  The bell's "mark read" is not affected: reading the feed marks nothing. API
  `Wiki.Api.Notifications` gains `feedAddress` (`GET`, the address or none yet) and
  `renewFeedAddress` (`POST`), through the derived client; `MonadNotifications` the
  two methods, with the demo answering "no feeds in the demo". Migration `000N` for the
  column (numbered at rebase time). Tests: server (the feed validates; 50 newest; a page
  no longer readable left out; a renewed token makes the old address 404; a missing
  token is 404; the operator gets 404), contract on Mem/SQLite/PostgreSQL/HTTP for the
  two methods, browser (the block shows the address once made, "Copy", renew). Docs:
  `docs/api.md` (the endpoint and the feed), the notifications section of the user docs
  ("Your notifications as a feed"). Queued after WP5.30; not started until the owner says so (the same note).


- **WP5.34 An editable wiki front page** (the owner, 2026-10-30).
  Goal: let an administrator customise the shared front page with Markdown and
  independently show or hide the Spaces and Recently visited sections. The owner
  chose a shared Markdown page with optional sections, rather than a per-user layout
  or a redirect to an existing page.
  Acceptance: an administrator can open "Edit home page" from the front page,
  edit its title and Markdown, preview the result, toggle Spaces and Recently
  visited independently, and save or cancel. Saving persists across reloads on the
  server (SQLite and PostgreSQL) and in the IndexedDB demo. Readers, including
  anonymous readers allowed by the wiki's existing access rules, see the saved
  front page; only a global administrator or the loopback operator may write it.
  Defaults keep today's directory, including both sections. Turning off the Spaces
  section must leave a discoverable way to browse spaces through the existing shell.
  Markdown uses the existing renderer and editor, including supported islands and
  custom boxes, with no HTML strings or new editor implementation. The custom
  content is wiki-wide and public to every reader who may open the front page;
  permission-filtered space links and recent spaces remain filtered as today.
  Initial HTML and browser hydration agree; base paths work. Failed saves retain the
  draft and show an error; cancel leaves stored settings unchanged. Older settings
  without these fields keep the defaults. Full-wiki export/import preserves the
  public configuration through optional archive metadata; older and space-only
  archives leave the current front page unchanged. Server secrets are not exported.
  Native tests cover defaults, serialisation,
  persistence and write permissions; browser tests cover editing, preview, save,
  cancel, section switches, reload and a reader without edit access. Update API/user
  documentation and changelogs. The ordinary verification gate applies.

- **WP5.35 The front page uses the ordinary page editor and features** (the owner,
  2026-10-30, after merging WP5.34: "czemu nie moge edytować strony głównej normalnie
  jak inne strony? ... Usuń tylko komentarze, całą resztę zostaw").
  Goal: make the shared front page work like an ordinary wiki page, using the
  existing full page editor and page features, with comments disabled for the
  front page alone. WP5.34's separate reduced editor and its missing page
  capabilities are not the intended product.
  Acceptance: "Edit home page" opens the same editor component ordinary pages
  use, with its complete toolbar, shortcuts, Save and Save and close, side-by-side
  preview, attachments (selection, paste/drop, insertion, removal and persistence),
  automatic drafts and recovery, unsaved-navigation protection, mention completion,
  the writing assistant and tracked changes, and conflict handling. Reuse the
  components and backend operations; do not copy the toolbar or build a second
  editor. The front page keeps the ordinary page features, including source,
  history and restore, Markdown rendering/islands, contents, presentation and
  document exports where the backend supports them. Disable comments and comment
  selection/loading for this page; ordinary pages retain their comments and all
  other existing behaviour. The home page remains shared, writable only by a
  global administrator/operator, readable under the wiki's existing access rules
  with the explicit anonymous-home exception below.
  Keep the independent Spaces/Recently visited switches and shell navigation.
  Existing-home migration is optional: the owner explicitly allowed dropping
  migration of the WP5.34 home if that simplifies the implementation. Keep cheap
  compatibility already implemented, but do not build a legacy migration layer.
  This exception concerns only the old home, never ordinary wiki data. SQLite,
  PostgreSQL and the IndexedDB demo persist the page, its
  attachments, drafts and versions. Full-wiki archives preserve it; old and
  space-only archives retain their existing compatibility rules. Do not expose
  homepage content through anonymous sessions of a closed wiki unless the
  administrator explicitly enables the exception below. Keep canonical
  home navigation, base paths and server/browser hydration consistent. Native
  and browser regressions cover reuse of the full editor, representative toolbar
  commands, attachments across reload, draft recovery/navigation protection,
  save/stay and save/close, switches, source/history/restore, the disabled comment
  UI and unchanged ordinary-page comments. Update
  docs and changelogs. Run and report the ordinary full verification gate on both
  database backends. Report the storage choice and any unavoidable home-specific
  restrictions before treating acceptance as met.
  Extended by the owner during implementation: "zrób opcję 'pokaż dla
  niezalogowanych' przy prywatnej wiki." Add an administrator option on the home
  page, relevant when the wiki is private, "Show to signed-out visitors", off
  by default and decoded as off for old settings. Enabled, it makes only the
  home document, its attachments and ordinary reader features available to an
  anonymous visitor; user spaces, other pages, drafts and administration remain
  protected by Closed. Session access stays Closed; no global public-access
  relaxation. Disabled again, it revokes anonymous access through rendered home
  routes, session/preload data and direct document/attachment/export endpoints.
  Anonymous writes stay forbidden. The public home must work in the initial
  server HTML and after browser hydration, including beneath a base path. Tests
  cover the default, opt-in, attachments, access to ordinary private content,
  revocation and persistence/export compatibility.

- **WP5.36 A sidebar that folds, the editor's font size, and a preview that follows
  the text, also in a window of its own** (the owner, 2026-10-31: "z lewej na dole
  przycisk '<<' żeby schować pasek boczny", "opcję zmniejszenia czcionki w edytorze",
  "po prawej się odświeża dokument (przewinięty do miejsca, w którym aktualnie jesteśmy)
  - czy byłaby opcja 'detach window' … edytor na jednym monitorze, i podgląd na
  drugim"; one package, "ja bym nie dzielił"). Three parts. **The sidebar** gets a "«"
  button at its bottom that folds it to a narrow strip with "»" to unfold it; the
  choice is kept in the browser (localStorage), the page's content takes the width,
  and the phone's menu is unchanged. **The editor's font size**: A− and A+ in the
  toolbar (and Ctrl+− / Ctrl+= in the editor), a few steps from small to large, kept in
  the browser; the editor's text only, the preview as it is. **The preview follows the
  text**: the rendered blocks carry the source line they come from (the Markdown
  parser's source positions, `data-line` on the block elements, rendered on the server
  too and adopted without repair), and the side-by-side preview scrolls so that the
  block of the cursor's line (or, while scrolling the editor, of its top line) is in
  view. **"Detach preview"** opens the preview in a window of its own at a route of the
  page (`…/p/<path>/live-preview`), which the editor feeds through a `BroadcastChannel`
  (same origin, no server): the text as typed and the line followed; the window renders
  it with the same renderer (islands, macros, boxes) and scrolls the same way, so it
  can sit on another monitor. It says so when the editor closes or saves, takes up the
  feed again after a reload of either window, and with no editor open shows the page as
  saved. The side-by-side pane closes while a detached window is open, and comes back
  when it closes. Tests: native (the source lines on the rendered blocks, the server's
  HTML the same as the browser's), browser (fold and unfold kept across a reload; A−
  and A+ kept; the side-by-side preview scrolled to the block of the cursor's line; a
  second page in the same browser context at the live-preview route following the
  editor's text and line, and told when the editor closes). Not started; after WP5.30.
- **WP5.32 Only wasm may use the owner's runner** (the owner, 2026-10-29).
  Goal: run `native` and `format` on GitHub's hosted runners in parallel with
  `wasm`, and run `deploy` on GitHub's hosted runners after the build jobs pass.
  Only `wasm` uses the runner selected by `plan`: keep the existing trust rule,
  busy-machine fallback, scheduled hosted run and `runner: hosted` override.
  Acceptance: `native`, `format` and `deploy` use `ubuntu-latest`; `wasm` keeps
  `needs.plan.outputs.runner`; the build jobs depend only on `plan`, and `deploy`
  still waits for all three or uses the already-tested artifact. The runner
  script's trust and fallback tests pass, `actionlint` is clean, and the README
  and workflow comments explain that the runner choice applies only to `wasm`.
  No change to the build, test, artifact or Pages behaviour. The wasm job still
  builds the native prerequisites of its browser suites, prerender and smoke test.
  Extended by the owner the same day: retain `dist-newstyle` as well as the
  dependency store, so unchanged wiki modules need not compile on every run.
  Hosted jobs restore separate incremental build caches for `native` and `wasm`;
  the wasm cache includes its native prerender and test programs. Cache compatibility
  uses the runner platform/environment and compiler pins. Exact snapshots also
  record Cabal and source inputs; project, flag, module and Cabal changes may
  restore older objects, which Cabal/GHC validate themselves. The owner's runner retains
  or restores its build directories across checkout without retaining unrelated stale
  workspace files. Acceptance also requires a real warm-build check: unchanged
  modules are reused, a source edit still rebuilds its affected modules, and all
  normal build/test steps continue to run. Do not cache the generated public site as
  a substitute for rebuilding it. Report measured cache sizes and the verification.
  Extended again by the owner: the hosted native job installs XeLaTeX when
  missing, with the TeX packages required by the PDF export tests (`mhchem`,
  TikZ, `soul` and Beamer). A machine with the complete setup skips installation.
  Acceptance: CI verifies the engine and required TeX files before testing;
  the PDF export and TeX file-access tests run instead of being pending because
  the engine or its packages are missing. The test for refusing PDF without an
  engine may still be pending on a machine with XeLaTeX, as designed.


- **WP5.33 Own the server's password-reset tasks** (the owner, 2026-10-29,
  from native test logs: uncaught libpq exceptions after `wiki_test_803` was
  dropped, although hspec reported passing examples).
  Goal: keep password-reset work inside the server's lifetime and make an
  unexpected background failure observable by the test that owns the server.
  `requestingReset` currently uses an untracked `forkIO`; `withServerUsing`
  can close storage and the fixture can drop its database while that task
  still uses it. Use maintained concurrency primitives or a task-scope library
  rather than building a general concurrency framework. Keep the reset's
  immediate, identical HTTP answer and asynchronous lookup/mailing, so neither
  account existence nor timing is revealed.
  Acceptance: server shutdown stops and joins all reset tasks before storage
  closes; no reset task can start after its scope closes; unexpected task
  exceptions cannot merely print on stderr while the owning test passes.
  Add deterministic regressions for a blocked task during server shutdown and
  an unexpected task failure, with synchronization rather than sleeps. Run the
  PostgreSQL reset/rate-limit examples repeatedly and check that no uncaught
  libpq or missing-database exception remains. SQLite and PostgreSQL tests pass,
  and the ordinary verification gate is reported with exact results. Do not
  silence the runtime's exception handler, discard failures in an `Async`, or
  delay dropping databases to hide the leak. Report the production failure and
  shutdown policies chosen and any other unowned work found during the audit.

- **WP5.22 A choice of database: PostgreSQL by default, SQLite as an option, one typed storage
  layer** (the owner, 2026-10-28: "Chciałbym jednak dać możliwość wyboru backendu … Chce jak
  najbardziej typowane api. Bez ręcznego sqla, może oprócz migracji. Pod postgresem wszystkie
  featury … Pod sqlite - workaroundy, jeśli dostępne, a jeśli nie to po prostu ukryte w UI";
  and no carrying over of existing data: "na razie nic tam specjalnego nie trzymam. Więc
  migracje możemy olać"). This replaces the "later" note on PostgreSQL below.

  **One storage layer, written once.** `Wiki.Server.Storage` (and `Storage/*`, ~5200 lines of
  `sqlite-simple`) is rewritten on **Beam** (`beam-core`, `beam-sqlite`, `beam-postgres`):
  queries are Haskell, not SQL strings, typed end to end (joins, aggregates, subqueries),
  and the backend is a type parameter. A portable query compiles for both backends; a query
  that uses a PostgreSQL feature (`tsvector`, `jsonb`, `SKIP LOCKED`, `LISTEN/NOTIFY`) has
  the type `Postgres` and cannot be called from the SQLite backend, so "everything under
  PostgreSQL, a workaround or nothing under SQLite" is checked by the compiler, not by
  `if`s. Decision 7 (keep `sqlite-simple`) is withdrawn. Not two implementations of the
  storage interface (every later feature would be written twice); not persistent/esqueleto
  (looser types, `rawSql` at hand); not rel8, Opaleye, Squeal or hasql (PostgreSQL only);
  not selda (unmaintained). The storage package may enable field selectors where Beam's
  `Columnar` records need them, scoped to the modules that define tables. The storage
  contract tests (`wiki-server/test`) run on both backends: SQLite in memory as today;
  PostgreSQL in CI as a GitHub Actions service container (`postgres:17`), and locally on a
  temporary cluster (`initdb`/`pg_ctl` on a scratch directory) when the binaries are in
  `PATH`, else that half reports "not run". SQLite stays a first-class backend in CI, so it
  cannot rot.

  **Schema, not data, is migrated.** The fifteen SQLite migrations are collapsed into one
  initial schema per backend (hand-written SQL, the one place SQL stays; `Migrate.hs` keeps
  the versioning and its test), numbering restarts at `0001`. No migration from the old
  schema: a deployment with a database of the old shape is refused with a sentence that
  says so and names the way (export the archive with the old server, import it with the
  new). Existing content moves by export and import (WP5.8), not by SQL.

  **What differs by backend**, named in one place (`Wiki.Api.Info` gains the backend's
  capabilities, and the application reads them instead of guessing):
  - Search: PostgreSQL `tsvector` with ranking (`websearch_to_tsquery`, a generated column
    with a GIN index, per page version's text); SQLite keeps the folded-text search of
    today (`Wiki.Core.Search`, `search_fold`). Same results shape; the capability says
    which one answers.
  - Events between server instances, the export queue, the sign-in limiter: PostgreSQL
    `LISTEN/NOTIFY` and `SKIP LOCKED` where a later multi-instance package needs them; not
    in this package beyond leaving the door open (the schema and the storage interface do
    not assume one process). SQLite is one instance, as today.
  - Everything else (JSON settings, transactions, indexes, the audit log, notifications,
    comments, blobs on disk) is modelled portably.

  **Deployment.** `wiki-server` takes `--database postgres://…` (the password from a file
  or `WIKI_DATABASE_URL`, never on the command line in the clear) or `--sqlite <file>`; the
  data directory keeps the attachments and the backups as today. `docker-compose.yml` gains
  a `postgres:17` service with a named volume and a healthcheck, and the wiki waits for it;
  the compose file is the default deployment; `--sqlite` is the one without a second
  container. `toolchain/deploy-local.sh` (and `deploy-server.mjs`) default to PostgreSQL in
  compose and take `--sqlite`; a deployment directory with a `wiki.sqlite` of the old shape
  stops with a warning that the state is incompatible and goes on only with `--fresh` (or
  "yes" at the prompt), after moving the old file aside, never deleting it. `backup` works
  for both (`VACUUM INTO` for SQLite, `pg_dump` for PostgreSQL, into `data/backups/`), and
  `restore` likewise. The README's operator section and `docs/api.md` say all of it.

  **Tests:** the storage contracts on both backends; the migration test on both; the server
  API suite on both (a parameter of the fixture); search tested on both with the same
  cases; `test-deploy-local.sh` and `test-deploy-server.mjs` for `--fresh`, `--sqlite` and
  the refusal; the smoke test runs the server against PostgreSQL when a cluster is at hand.

- **Later, by the owner (2026-10-27, "zapisz to na potem"), picked up on 2026-10-28 as
  WP5.22 with a different shape (a choice of backend, no data migration): a migration to
  PostgreSQL.**
  Not now; when it comes, as one port of the whole storage layer (WP5.7's spike says why
  not half and half), most likely with `rel8`, migrations hand-written, SQLite kept or
  dropped as the owner decides then.

## Delegation protocol

The session the owner talks to implements every work package itself, one at a time,
without subagents (the owner, 2026-10-31: "Usuń wzmiankę o wykonywaniu zadań przez
subagentow opus, będziesz wykonywać wszystko sam"). Before a pull request merges, it is
reviewed with Codex, `gpt-6.1-sol` at high reasoning effort, with the owner's key, as
`AGENTS.md` says; the session fixes the real findings and pushes, for four rounds at
most (the owner, 2026-10-31: "4 rundy review wystarczą"). The owner merges; the
session merges only when asked ("nie merguj sam, chyba że poproszę"). Each work package
starts from its goal and acceptance criteria above, the decisions it builds on, and the
haskell-halogen modules it uses, and ends with the verification gate of `AGENTS.md`
(`npm run build-native`, `npm run test-native`, `npm run build-wasm`, `npm run test-wasm`,
fourmolu clean, no warnings on either backend), one pull request ready for review, and a
Progress entry: what was built, the decisions taken, what could not be done and why, and
what the next package should know.

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

- **WP5.35 implementation (2026-10-30, `wp5.35-full-home-page`).** The root has a
  real page in a real backing space, identified by storage-owned IDs in the
  optional `HomeDocument` reference. Ordinary page, attachment, draft and version
  storage and the existing Editor/Page/Source/History/Slides components serve it.
  Comments are disabled for the root; Rename remains available. Its singleton
  space/page cannot be moved, deleted, made a template or given children. Backing
  records are absent from the space directory/search and use canonical root
  routes. Full archives carry optional root versions and import into the one
  destination root; equal versions deduplicate and differing timestamp collisions
  move to a free microsecond. Ordinary archive records retain their semantics.
  Homepage settings change options only, preserving current content and trusted
  IDs, so stale settings cannot overwrite a newer page save. Page saves and
  restores update compatibility metadata and its cache after commit.
  The private-wiki option `showAnonymous`, off by default, exposes only the home
  document's reader routes and its own attachments; the session stays Closed and
  ordinary wiki data stays private. The administrator's checkbox names attachments,
  source and history as public too. Exact ownership checks protect the early API
  boundary as well as storage. The simple old-field initializer is retained: it
  already worked and the owner allowed omitting it only if that simplified work;
  no separate legacy migration layer or schema migration is added. Native tests
  on SQLite/PostgreSQL, the unchanged memory bound, wasm build and the focused
  home browser scenarios have passed. The full gate, smoke tests and external
  review results are recorded in the pull request before completion.

- **WP5.34 merged (2026-10-30, PR #116, `2499da3`); corrected by WP5.35.**
  The directory's "Edit home page" opens CodeMirror for a shared title and
  Markdown body, a preview and independent Spaces/Recently visited switches.
  `HomePage` lives in `wiki-core`; session data carries the public value, redacted
  for anonymous visitors to a closed wiki. `PUT api/v1/admin/home-page` changes
  only this configuration, with the existing global-administrator/operator check.
  The server stores it in the settings row `home-page`; the demo keeps it in
  IndexedDB. Defaults preserve the old directory. The existing body renderer
  supplies islands and custom boxes; links start at the wiki root, with no
  page attachments or inherited space macros. The shell keeps space navigation
  when cards are hidden. Full archives carry optional public `settings.json`
  metadata; old and space-only archives preserve the current front page. Import
  publishes refreshed settings after commit under the writer lock, preserving
  the storage's cache and scale tests. Native builds/tests and the wasm build
  pass without warnings; the separate PostgreSQL run passes 920 examples with
  no failures or pending cases. All five added browser scenarios pass, including
  draft retention after a refused save, which required a stable error container
  beside the CodeMirror host. The pull request records the full gate and external
  review results. The owner merged the package, tested it, and rejected the
  reduced editor: the front page must retain ordinary page features, with only
  comments removed. WP5.35 supersedes the limited editor and missing page
  attachment context recorded above.

- **Session consolidation (2026-10-30, owner override):** the owner requested direct
  implementation without subagents, integrating their work into main and deleting
  their worktrees. WP5.32 and WP5.33 are continued together in this checkout.
  Review #115: incremental-cache fallback is bounded by compiler/platform, not
  project, Cabal or npm configuration; Cabal/GHC validate reused objects themselves.
  Install `libxml2-utils` for native schema checks. Try Hspec parallel first on the
  independent core/API suites, retaining sequential process-environment and browser
  tests. Exercise PDF refusal by hiding the engine in that sequential test rather
  than reporting it pending. Profile the warm wasm build by stage before choosing
  further build optimisations. The ordinary verification gate still applies.
  Native verification on the consolidated tree passed: 1859 server examples on
  SQLite/PostgreSQL, no pending cases and no uncaught SQL exceptions. The reset
  regressions also passed ten repeated reset runs. An isolated 897-example core
  comparison (seed 413) took 2.905 s with `-N1`, 1.858 s with `-N2`, 1.560 s with
  `-N`; the native parallel suites use `-N` as requested.
  The current haskell-halogen pin exposes `Halogen.Static` and the in-memory DOM
  only natively. A standalone WASI prerenderer needs upstream backend support;
  changing the wiki executable's target alone cannot reuse those modules.
  The wasm script now builds the native prerenderer before sourcing the cross
  environment: the latter also replaces `ar`/`clang` through PATH. Its size-only
  report caches compression lengths by content and compression library versions.
  All public output is still generated fresh.
  The final native gate with `-N` passed, including all 1859 server examples
  without pending cases or uncaught SQL errors. The first wasm build after this
  checkout caught up with the pinned dependency revision passed: native prerender
  build 0 s, wasm compilation 252 s, wasm-opt 10 s, bundle 4 s, prerender 1 s,
  size report 31 s (initial measurement-cache fill). On the owner's instruction
  to push for CI, the remaining local wasm tests/warm timing/smoke gate was
  stopped rather than competing with the self-hosted CI. Those checks remain
  assigned to the pushed CI; no local full-gate success is claimed.

- **CI follow-up (2026-10-30):** the owner merged haskell-halogen #94 and
  requested its pin in the blog. Keep prerendering native: WASI would still
  need its own build. Use a separate `-O0` native project/build directory for
  wasm helpers and smoke servers; keep the normal native build's optimisation.
  Remove the size-only compression report (34 seconds in CI). Cache apt's
  downloaded archives while preserving dpkg setup and TeX format generation.
  Run browser specs with one `parallel` at the root, checking CSP in each
  context, and independent smoke programs concurrently through Node's test
  runner. Keep stateful steps within a smoke program in order. Deadline
  timers must not keep completed smoke processes alive. Continue
  directly without subagents and update PR #115.
  Verification: native and wasm builds/tests pass; the server has 1,859
  examples with no failures, pending cases or uncaught libpq errors. Browser
  specs pass in two contexts (150 and 149 examples). The 45 demo and three
  server HTML files are byte-identical at `-O0` and `-O1`. A warm wasm build
  takes 24.83 seconds. Smoke programs pass on SQLite and PostgreSQL: 199.01
  seconds serial, 101.69 parallel, 89.63 after unref'ing deadline timers.
  Failure checks verify the runner's exit status and database cleanup after
  exceptions and explicit process exit. Format, actionlint and all 25 CI
  script cases pass. Warm apt-cache timing still needs a seeded CI run.

- **Native test parallelism (2026-10-30):** CI #319 passed, but its server
  suite took 286 seconds and its application suite 107 seconds. Both were
  sequential; the application's test executable also lacked the threaded RTS.
  Run their whole spec trees in parallel, with four concurrent examples by
  default and `-N -A16m` for the RTS. The 16 MiB allocation area per
  capability reduces collections in the large JSON/DOM/SQL fixtures. Eight
  workers passed a randomized run but did not improve server time; keep four.
  Every independent example takes one permit from a `QSemN`; process-wide examples take all permits. Hspec's `sequential`
  does not exclude other concurrent examples. Keep PDF checks (which set TeX
  limits and sometimes hide xelatex through PATH), the inherited PGPASSWORD
  check, and the native page-size and assistant settings checks exclusive.
  IndexedDB contract fixtures delete their private databases after each example
  so the process-wide map does not retain every example's records. Fixtures
  keep their own database, directory and ports. Keep all examples and backends.
  Validation: native and wasm builds/tests and formatting pass. The full native
  command takes 218.42 seconds locally, down from 371.92 on the same machine;
  server 357.58 to 212.09 seconds, application 103.25 to 75.15. All 1,859
  server and 1,402 application examples remain, with no failures or pending
  cases. The shared assistant database passes 100 examples over 20 seeds at
  16 workers. The wasm gate also exposed two apps sharing location.hash in
  one admin test; unmount the first before restoring the second. Both browser
  contexts pass (150 and 149 examples).

- **Native CI groups (2026-10-30):** the owner requested another reduction
  after CI #320's native Test step still took 239 seconds. Use three hosted
  matrix jobs: unit (all other suites and the server's database-free examples),
  SQLite, and PostgreSQL. Each job has its own CPU and memory; all restore the
  same compiler-bounded caches. Only unit saves the Cabal store/build snapshot,
  and only postgres saves apt archives. Unit skips TeX and neither unit nor
  SQLite starts PostgreSQL. Keep the default local native command unchanged.
  `WIKI_TEST_GROUP=unit|sqlite|postgres` selects a group; invalid groups fail,
  and explicit postgres requires a URL instead of passing with pending cases.
  Compare the groups' complete Hspec paths against `all`: currently 33 + 912 +
  914 = 1,859 server examples, with no omissions or duplicates.
  Validation: the three real groups pass locally in 39.80, 60.31 and 110.71
  seconds; the unchanged full command passes in 225.75 seconds. Native and
  wasm builds/tests pass without compiler warnings, and both browser contexts
  pass (150 and 149 examples). Group manifests/default behavior, invalid groups,
  missing/blank PostgreSQL URLs, argument forwarding and failure propagation
  pass. Base/full apt profiles, 20 bootstrap regressions (including an injected
  hosted ghcup prefix), all 25 CI script cases, format and actionlint pass.

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
  Computer Modern fonts came with no licence file. (Answered by WP5.1: the repository is
  MIT, the GPL text is served beside TikZJax, and the fonts are BaKoMa's, under a licence
  that allows this; see decision 24.) **Found:** following a link while a
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
- **WP3.5 merged** (2026-10-25, PR #59, `main` at `a13a5f7`). Migration `0003-settings.sql`:
  `settings (key, value)` (no row = default, so an existing deployment stays open) and
  `invitations (id, email, token_hash, created_at, expires_at)`. `Wiki.Core.Access` (`Open |
  Closed`) is a field of `Grants`; `Permission.publicTo access who` decides whether a public
  space grants `View` to someone not signed in (never in a closed wiki), every rule follows
  with no new argument; `<>` keeps closed if either side is, `mempty` is open; exports do
  not carry it. Sessions carry `grants.access`, so the client knows the mode before sign-in.
  The storage keeps the settings in memory and replaces them under the connection lock on a
  write. Server: a closed wiki answers an anonymous caller 401 `Unauthenticated` on every API
  endpoint but `info`, `session`, `accounts`, `invitations/…`, and renders the sign-in frame
  with 401 for every page but an invitation's (404 when unusable); the admin listener is
  unchanged. API: `POST api/v1/accounts` (open wiki only, signs in, limited 5 per address per
  15 min together with invitation acceptance), `GET/POST api/v1/invitations/<secret>`,
  `GET/PUT admin/settings` (`WikiSettings {access, newAccountsCreateSpaces}`, the latter for
  self-made and invited accounts alike), `GET/POST admin/invitations` (`Invited {invitation,
  token?, mailError?}`), `DELETE admin/invitations/<id>`. Invitations: 32 random bytes, stored
  as SHA-256, single use, 7 days, inviting an address again replaces it; the link is shown
  once, when made and only if not mailed (showing it later would mean storing the secret in
  clear); expired ones stay listed as such until revoked or replaced; no secret in logs
  (`Log.redactedPath`, hiding `Show` instances). Mail: `Wiki.Server.Mail` over `smtp-mail` +
  `mime-mail` (MAIL/RCPT/DATA driven by hand so a failure message cannot quote the secret,
  30 s timeout); options `--smtp-host`, `--smtp-port` (587; 465 implicit TLS), `--smtp-security
  tls|starttls|plain`, `--smtp-user`, `--smtp-from`, `--public-url`, password only from
  `WIKI_SMTP_PASSWORD`; `cabal.project` gains `allow-newer` for `serialise` and `cborg` (tls
  2.4 on GHC 9.14). `Accounts` factors `prepared`, `makeAccount`, `startSession` out of
  `signIn` (for OIDC). App: route `Invite` at `/invite/<secret>/` (a top-level prefix, no slug
  word reserved); `View/SignIn` gains "Create account" (open wiki only), `View/Invite`,
  `View/Access` panel section "Who may come in" (open/closed radio, the create-spaces
  checkbox, invite form with the link once and "Copy link", table with Revoke, read even
  when open, shown when closed); the shell shows a closed frame to a visitor at every route
  but `Invite`; `MonadAdmin` gains `wikiSettings`, `setWikiSettings`, `invitations`, `invite`,
  `revokeInvitation`; `MonadAccount` gains `register`, `invitationFor`, `acceptInvitation`;
  the demo keeps settings and invitations for the tab's life, starts open, takes no
  invitations. Deploy: `deploy-local.sh` takes the SMTP options and `--no-smtp`, remembers
  them, keeps the password in `~/.config/wiki-demo/<name>.env` (mode 600, `EnvironmentFile=`,
  deleted by `--purge`); compose passes `WIKI_SMTP_PASSWORD`; the image adds
  `ca-certificates` (not built here). Tests: 23 HTTP cases (`Test.Server.Access`), a real SMTP
  conversation against a sink plus redaction, options, migration from 2, contract on four
  backends, hydration of the closed frame and both invitation pages at zero repairs, 7
  browser cases, the server smoke test closes the wiki, makes an account by invitation and
  reopens, 2 deploy cases; core 597, app 691, server 451, browser 141; `app.wasm` 8.77 MB.
  Not done: no e-mail on the user record; a setting changed by another process is seen only
  after a restart (nothing does that); no console `settings` command (the admin listener is
  the recovery). For WP3.6: an unknown identity becomes an account through `makeAccount`
  without a password (`insertAccount` takes `Maybe`), `register`'s path in an open wiki and
  `acceptInvitation`'s in a closed one (the invite page offering "sign in with …", the
  secret in the OIDC `state`); the callback endpoints join `App.openToAnyone`; rate-limit
  with `env.registrations`.
- **WP4.3 started** (2026-10-25) on `wp4.3-halogen-net` from `main` `49b7190`: the pin to
  haskell-halogen `5ea6dba`, `Halogen.Net.Fetch` as the HTTP transport, the window's emitters.
  Phase 3 has WP3.6 (OIDC) left; it follows WP4.3 so that it builds on the new pin.
- **WP4.3 merged** (2026-10-25, PR #60, `main` at `f999016`). The pin moves to haskell-halogen
  `5ea6dba` with `net` in the subdirs (#60–#65: `Halogen.JSBits.Promise`, the `net` package,
  the window's emitters, a listener that finishes the loop's preempted work in the
  dispatch); the toolchain pins did not move. The bump forced only test selectors (a hash
  router's `href` is now the full address: `a[href$='#/…']`) and `MonadUnliftIO` on
  `Shell.component` and `SlidesView.component` (emitters lowered to IO). Transport:
  `browserTransport = fetchTransport timeLimit` over `Halogen.Net.Fetch` (`fetch` then
  `bytes`, same-origin credentials, the marker header, `Content-Type` from the body); a
  `Left JSError` is `Unreachable (fetchFailure e)`, the 30 s / 6 min limits stay through
  `System.Timeout.timeout` and that kill aborts the request as any kill does, so leaving a
  view mid-load leaves nothing running; `cache: "no-store"` dropped (`Fetch.Request` has no
  cache field; the server's `Cache-Control: private, no-cache` covers it; worth suggesting
  upstream); `jsbits/fetch.js` and the `js_fetch*` bindings deleted; `start`/`response`
  unused (no request of ours must begin in a dispatch). Offline: over the network backend
  the shell subscribes to `Window.online` in `Initialize` (`H.liftEffect`), shows a fixed
  corner notice (`.offline-notice`, `role="alert"`) while offline, and on `online` retries a
  world or space that failed as `Unreachable`; the demo shows nothing. Slides: keys through
  a wrapped `Window.keyDown` that decides the command and calls `preventDefault` inside
  the window listener's dispatch, subscribed in `Initialize`, ended with the view; the
  `preventingDefault` prop is gone; `slides.js` stays as the decoder. Autosave stays a fork
  (`interval` cannot express "no draft after a save"); `visibility` unused. Tests: native app
  695 (+4), browser 148 (+7: a killed wait aborts, a time limit aborts, leaving a loading
  history aborts, the notice comes and goes, a failed space reloads when back online, no
  notice in the demo, slides' keys heard anywhere and prevented in the dispatch; the fake
  fetch records `aborted`, holds answers, dispatches online/offline), `test-bootstrap.sh`
  19. For later: the search box's `/` shortcut is still a hand-made document listener in
  `jsbits/search.js` (a `Window.keyDown` subscription would do); three `Safe` bindings
  (`js_database_exists`, `js_read_file`, `js_copy_text`) could return a `Promise`; the real
  30 s limit is untested. For "someone else is editing": `EventSource`/`WebSocket` are in
  the pinned `net`; open in `H.liftEffect`, subscribe to the emitters (they keep what arrives
  before the first subscriber), close in `Finalize`, import qualified; the server needs an
  SSE endpoint under the closed-wiki 401 rule; test by replacing `globalThis.EventSource`.
- **WP3.6 started** (2026-10-25) on `wp3.6-oidc` from `main` `4d87967`: server-driven
  authorization code flow with PKCE (Google, GitHub, generic OIDC, Apple if it fits),
  identities linked to accounts, the open/closed rule of WP3.5 obeyed. The last package of
  Phase 3.
- **WP3.6 merged** (2026-10-25, PR #61, `main` at `2599290`). Sign-in with Google, GitHub,
  Apple or any OpenID Connect provider, beside passwords. Configuration `--oidc
  NAME=KIND,CLIENT-ID[,ISSUER]` (kinds `google`, `apple`, `github`, `oidc` with its issuer; a
  fourth field overrides the provider's address, e.g. GitHub Enterprise), the secret only
  from `WIKI_OIDC_<NAME>_SECRET`, `--public-url` required, redirect URI
  `<public-url>auth/<NAME>/callback`; `checkOptions` rejects bad or duplicate names, `oidc`
  without an issuer, a non-https issuer off loopback, `--oidc` without `--public-url`; a
  missing secret fails start-up; `wiki-server oidc check [NAME]` runs discovery and prints
  the redirect URI. Flow (`Wiki.Server.Oidc`, `Wiki.Server.Auth`): authorization code with
  PKCE (not for Apple) and a nonce, driven by the server through `auth/<name>/start?next=…
  [&link=1|&invite=…]` and `GET`/`POST auth/<name>/callback` on the public listener only,
  dispatched before the closed-wiki check and outside `sameOrigin`; pending round trips in
  memory (10 min, at most 10 000, lost on restart), each bound to the browser by a `wiki_oidc`
  cookie (`HttpOnly; SameSite=Lax; Path=<base>auth/`; two flows at once in two tabs fail the
  first); discovery lazy and cached; ID token claims `iss`, `aud`/`azp`, `exp` (60 s skew),
  `nonce` checked without a signature check (the token comes straight from the token
  endpoint over TLS); GitHub's numeric `id` is the subject, `user`/`user/emails` give the
  verified address; the secret goes `client_secret_post` where discovery lists it and for
  GitHub, else HTTP Basic; the callback answers a page with a `meta refresh`, not a 302,
  because a `SameSite=Strict` session cookie is not sent on a redirect ending a cross-site
  navigation (Apple's `form_post` is turned into a same-site GET the same way); `safeNext`
  accepts only paths under the wiki. Rules (`Accounts.landWith`, one transaction): a known
  identity signs in (disabled → 403 page); `link=1` links to the signed-in user who started
  (refused if the identity is another's or a second at that provider); an invitation makes
  that account and uses it up; otherwise an account in an open wiki (no password,
  `newAccountsCreateSpaces` honoured) and a refusal in a closed one; logins from the
  provider's login, the verified e-mail's local part or the name, `[a-z0-9._-]`, ≤ 40,
  `-2`, `-3`… then random; an unverified e-mail is not stored; accounts made and failed
  exchanges count against `env.registrations`, known sign-ins do not. Migration
  `0004-identities.sql`: `identities (provider, subject, user_id, email, display_name,
  linked_at)`, PK `(provider, subject)`, unique `(user_id, provider)`, cascade. API: `Session`
  and `SessionInfo` gain `providers :: [SignInProvider {name, label}]` (in the session, so
  server render and first client render match); `Directory` gains `identities`; `GET`/
  `DELETE api/v1/account/identities[/<p>]` (409 when it would leave no way to sign in);
  `DELETE admin/users/<id>/identities/<p>` (may remove the last way in, ends the sessions);
  `Wiki.Api.Auth` builds the addresses. App: provider links under the sign-in, "Create
  account" and invitation forms; a signed-in user's name opens an account panel (password
  state, identities, Disconnect disabled on the last way in, "Connect X"); the admin column
  says "Signs in with GitHub" / "with a password and GitHub" with a Disconnect per identity;
  `MonadAccount` gains `identities`, `unlinkIdentity`; `MonadAdmin` gains
  `unlinkUserIdentity`; `MemWiki` stateless. Deploy: `deploy-local.sh --oidc …` (repeatable,
  `--no-oidc`), secrets in the mode-600 env file, prints the redirect URIs and an `oidc
  check` line; compose, Dockerfile, README (per-provider registration steps), `docs/api.md`.
  Tests: a fake provider (Warp, OIDC and GitHub shapes) over real HTTP with a cookie-keeping
  test browser (open, closed, invited; link, unlink, last way in; disabled; wrong `aud`,
  nonce, `iss`, expired; unknown state, state without the cookie; provider declining; the
  limit; Apple `form_post`; Basic vs post secret; nothing secret in the log), options,
  migration from 3, claims, login candidates, `safeNext`, `oidc check`, admin contract on
  all backends, 8 browser cases, hydration with providers at zero repairs, the server smoke
  test signs in through a fake provider on `localhost` against the wiki on `127.0.0.1` in
  real Chromium (different sites), `test-deploy-local.sh` 28+10+10; server 495, app 803,
  browser 156; `app.wasm` 8.92 MB. Apple implemented but tested only against the fake
  provider; it needs an https redirect URI and an ES256 JWT as the secret (≤ 6 months).
  Not done: no self-service password for an identity-only account (an administrator sets
  one); the last-way-in check counts identities at providers no longer configured; group
  grants still not shown in the panel (from WP3.4). Lessons: a new `migrations/*.sql` does
  not recompile `Storage/Migrate.hs` incrementally (`embedDir` tracks only files it saw;
  delete its `.o`); `build-wasm`'s prerender step and `build-native` share
  `dist-newstyle/native`, never run both at once; record updates on fields shared by
  several records are ambiguous under `DuplicateRecordFields`; browser tests `find` before
  `findAll` where a view loads asynchronously.
- **Phase 3 complete** (2026-10-25). `main` at `2599290` has accounts and sessions (WP3.1,
  with WP3.2's authorisation folded in), the administration panel (WP3.3), account forms,
  per-space permissions, `create-spaces` and the end of `--trust-network` (WP3.4), the open
  or closed wiki with invitations by e-mail (WP3.5) and OIDC sign-in (WP3.6); beside it,
  presentations (WP4.2) and the halogen pin at `5ea6dba` with `Net.Fetch` (WP4.3). Tag point
  for `v0.3.0-accounts`, which the owner pushes. Carried into Phase 4: group grants of the
  global permissions in the panel; the slides' theme from a space's settings and notes in a
  second window; a self-service password for identity-only accounts; disabled users out of
  `spaceAccess`'s candidates (decision 22); `/` shortcut and the three `Safe` bindings over
  the window emitters and `Promise`; the assistant stays shelved (decision 21). Next: the
  owner's pick among the Phase 4 candidates.
- **WP4.4 and WP4.5 started** (2026-10-25) in parallel from `main` `a32bb9f`, on
  `wp4.4-server-settings` (public URL, mail and sign-in providers from the panel, migration
  `0005`) and `wp4.5-comments` (inline and page threads, live over a WebSocket, migration
  `0006`); whichever merges second rebases.
- **WP3.7 Account fixes started** (2026-10-25) on `wp3.7-account-fixes` from `main`
  `723a898`, from the owner's test of the deployed Phase 3: the "Creates spaces" switch shows
  on and disabled for an administrator (the rule already implies it); a user may change or
  set their own password (`PUT api/v1/account/password`, the current one required where it
  exists, other sessions ended, the account panel always reachable); the setting "A new
  account may create spaces" reworded with a help sentence (it grants `create-spaces` to
  every account made by self-registration, invitation or a provider sign-in).
- **WP3.7 merged** (2026-10-25, PR #62, `main` at `a903a49`). `PUT api/v1/account/password`
  (`PasswordChange {current, new}` → `SignInMethods`): the current password required and
  checked where one exists (401, counted by the sign-in limiter under the user's login and
  address, 429 after 5; a right one clears the count), an identity-only account sets its
  first with `current = null`, `checkPassword` first (400, never counted), every other
  session ended and the caller's kept (matched by token hash), 409 if the hash changed
  meanwhile, the operator 400. `MonadAccount.changePassword` (`HttpWiki`); the signed-in
  user's name is always a button opening the account panel, which gains "Change password…" /
  "Set a password…" (current, new, repeat; mismatch caught in the browser). The "Creates
  spaces" switch shows what `canCreateSpaces` makes of the grants: on and disabled for an
  administrator with "An administrator creates spaces anyway", the stored grant untouched;
  tests confirm "New space" is offered to an administrator without a grant of their own.
  The setting reads "Let every new account create spaces" with the help line "Applies to
  accounts people make themselves, by invitation or by signing in with a provider. You can
  also grant it per user in Users." (README and `docs/api.md` alike). Tests: server 502,
  app 806, api 58 + 95, browser 161; the server smoke test has an identity-only user set a
  password and sign in with it. Known: a wrong current password costs one extra
  `GET session` (the 401 recheck of WP3.1). Still open: group grants of the global
  permissions in the panel.
- **WP4.4 merged** (2026-10-25, PR #63, `main` at `24847ab`). The administration's new
  "Server" section (`View/Server.hs`, beside "Who may come in") is the only place the public
  address, the mail server and the sign-in providers are set (the owner's decision: no
  command-line bootstrap or override). `--smtp-*`, `--public-url`, `--oidc`,
  `WIKI_SMTP_PASSWORD` and `WIKI_OIDC_<NAME>_SECRET` are gone from `wiki-server` and
  `deploy-local.sh` (each refused with a pointer at the panel; the next deploy deletes the
  old `~/.config/wiki-demo/<name>.env`, says so and lists what to set again; no
  `EnvironmentFile=`; `--status` no longer lists providers). API (`Wiki.Api.ServerSettings`):
  `ServerSettingsOf s {publicUrl, mail, providers}`, a secret read as `set | not-set`,
  written as `Maybe Text` (`null` or missing keeps, `""` clears, text replaces; a provider
  left out is removed with its secret, `mail: null` drops the password); `GET`/`PUT
  admin/server`, `POST admin/server/providers/<name>/check` (as stored, or as typed), `POST
  admin/server/mail/test`; `checkServerSettings` shared by server and demo. Storage:
  migration `0005-server-settings.sql`, address and mail as rows of `settings`, providers in
  `sign_in_providers` (name, position, kind, client id, issuer, secret), secrets in clear
  (the file holds password and session hashes already; `data/` is mode 700; backups carry
  them too); kept in a second `IORef` replaced under the lock; the mailer built per mail,
  providers cached by (settings, secret, public URL) and replaced per request so any change
  re-runs discovery; `wiki-server oidc check --data DIR [NAME]`. Panel: one thing edited at a
  time, saving writes the whole; secrets in password fields, shown as "Set"/"not set" with
  "Replace…" and (mail) "Clear"; each provider shows its redirect URI with "Check", "Change",
  "Remove"; "Add a provider"; "Send a test mail". `MonadAdmin` gains `serverSettings`,
  `setServerSettings`, `checkProvider`, `sendTestMail`; `MemWiki` keeps them for the tab.
  Validation: a provider needs a secret, mail and providers need a public address, a mail
  account needs a password, a change is refused whole. Tests: HTTP (administrator only,
  secrets never in an answer or the log, keep/clear/drop, survive a restart, a provider added
  at run time signs in with no restart, a removed one 404, a changed issuer re-runs discovery,
  a replaced secret used at once, mail through the SMTP sink with run-time settings, "Check"
  against the fake provider), migration from 4, `oidc check --data`, removed flags refused,
  admin contract, 4 browser cases, hydration, the server smoke test adds the fake provider
  through the panel in Chromium and signs in with it, `test-deploy-local.sh` 26+10+10; server
  524, app 814, api 67+105, browser 165; `app.wasm` 9.20 MB. Known: a secret travels once in
  the `PUT` body over the listener the panel is on (plain http on the private network,
  decision 20); an upgraded deployment starts with nothing set; settings changes are not
  logged. CI note: the `wasm` job failed once on the server smoke test's draft step ("Draft
  saved" not seen in 30 s, no `PUT …/draft` logged), untouched by this PR and green on the
  previous PR; the one re-run passed, so a timing flake of the autosave on the runner; if it
  recurs, make the step robust (wait for the draft request, or type then wait past the 2 s).
- **WP4.5 merged** (2026-10-25, PR #64, `main` at `dbcc242`). Comments as decision 23 says.
  Core: `Wiki.Core.Anchor` (`Anchor {exact, prefix, suffix}`, 32 characters of context each
  side; `locate` finds a single occurrence wherever it moved, tells several apart by how much
  context matches, ties and misses are `Orphaned`, occurrences found one character at a time
  since overlapping ones were missed; `renderedText` without islands; `highlight`, a pure pass
  over the VDom wrapping parts of single text nodes in `<mark class="comment-mark"
  data-thread>`, the quote starting last wins an overlap); `Wiki.Core.Comment` (`Thread
  {id, page, anchor, resolved, createdAt, comments}`, `Comment {id, thread, author, body,
  createdAt, editedAt}`, the rules, `checkCommentBody` ≤ 20 000 characters, the folds);
  `CommentThreadId`, `CommentId`. API: `CommentsApi` at `pages/<page>/threads…` (list, open,
  reply, edit, delete comment, delete thread, resolve/reopen); `Wiki.Api.Events`
  (`ClientMessage` `subscribe`/`unsubscribe`, `ServerMessage` `subscribed` with the page's
  threads, `refused`, `page` + `event`; an open `PageEvent` whose unknown types parse as
  `Unknown`). Backends: `MonadComments` with one contract of 20 cases on Mem (IndexedDB store
  `threads`, database version 4), Mem kept, SQLite (migration `0006-comments.sql`, after
  WP4.4's 0005) and HTTP (threads cached and preloaded, a write folds into the cache).
  Server: `Wiki.Server.Events` at `GET api/v1/events` (`websockets`, `wai-websockets`),
  routed after the closed-wiki rule (anonymous 401 before the upgrade), foreign `Origin` 403
  (`Host` or `X-Forwarded-Host` accepted), plain GET 426, logged as 101; subscriptions
  checked when made and before each event; events published after commit; an outbox of 256
  per connection, closed if it falls behind, pings every 20 s. The `subscribed` answer carries
  the page's threads read in the same hold of the connection as the subscription
  (`Storage.threadsThen`), so nothing falls between a page's render and its subscription and a
  reconnect catches up the same way, with no HTTP request. App: quotes marked on the page, a
  "Comments (n)" toggle (unresolved inline threads, orphaned included) opening the side panel
  (`View/Comments.hs`), a floating "Comment" button on a selection (`jsbits/comments.js`),
  quote ↔ thread focus, page threads under the article, anonymous readers see threads and
  "Sign in to comment."; `Wiki.App.Live` (`MonadLive`, HTTP only): one socket per tab, opened
  lazily, page subscribed while shown, reconnect 1 s doubling to 30 s, restarted on session
  changes; the demo seeds the first post with three threads. Rules: deleting a thread's first
  comment deletes the thread and is refused while it has replies; space administrators delete
  any thread, its opener while every comment is theirs. Comments render through
  `renderSections`; `Body` generic over slots. Also fixed, found by the runner: the editor was
  read-only while a save was in flight (textarea `readOnly` mirrored into CodeMirror), so
  keystrokes during Ctrl+S were silently dropped and no draft followed; the attribute and the
  toolbar's `not saving` guard are gone, with a browser test holding a save while typing. Tests:
  anchoring natively with a property, highlight markup, rules and folds, the contract on four
  backends, HTTP per rule, the WebSocket end to end, migration from 5, hydration at zero
  repairs, 8 browser cases plus the catch-up and the editor race, both smoke tests (the
  server's shows a comment across two tabs over the real WebSocket); server 580, app 855, core
  625, browser 175; `app.wasm` 9.5 MB. Limits: a thread the tab opens between `subscribe` and
  its answer can blink and lose focus; a socket keeps the identity it opened with until the
  client restarts it; touch selection and scroll untested; exports carry no comments; a
  reverse proxy must forward the upgrade and keep `Host`. For presence: `PageEvent` is open,
  `ClientMessage` needs a constructor, `Env.events` holds the hub, nothing is replayed so
  re-announce on `Replaced`. Known flake: `Test.Server.Api` "logs each request…" races the log
  line written after the response under full-suite load.
- **WP4.6 started** (2026-10-25) on `wp4.6-one-space` from `main` `57530a1`: the space
  directory as the front page, one space's tree in the sidebar, a space's home page, icon and
  description, "Space settings"; migration `0007`.
- **Added to WP4.6** (the owner, 2026-10-25): the page's action bar (Edit, View source,
  History, Present, Comments, Delete) sticks under the header while the page scrolls, so a
  long page can be edited without scrolling back up; the editor's toolbar likewise if it does
  not already.
- **WP4.6 merged** (2026-10-25, PR #65, `main` at `14e429d`). One space at a time, as the
  owner asked after Confluence. The front page is a directory of spaces (`View/Directory.hs`:
  a card per top-level space with icon, name, description, page and subspace counts, a
  public/private badge; a space seen only through a subspace gets a card without a link that
  names the subspaces one may open; "Recently visited", the last six in `localStorage`,
  `Wiki.App.Recent`). Inside a space the sidebar shows its icon and name, a switcher back to
  the directory or to another space, "Up to <parent>", the home page, "Pages and settings",
  the page tree and a "Subspaces" section; the breadcrumb reads Spaces › space › subspace ›
  page. A new space is made with a "Home" page from a template; `/s/<space>/` shows the home
  page when there is one, the list of pages otherwise, and that list is always at
  `/s/<space>/pages/` (`pages` is a reserved slug; existing spaces have no home page until an
  administrator sets one with "Set as home page" or in the settings). Icons: an emoji, one of
  ten colours, or an uploaded PNG/JPEG/GIF/WebP/AVIF up to 1 MB, SVG refused, stored as a blob
  and served from `spaces/<id>/icon/<blob>` with `nosniff`, a sandbox CSP and an ETag; without
  one, the first letter on a colour picked from the id. `View/SpaceSettings.hs` takes the place
  of "Rename" and "Permissions": one form for name, description, icon and home page, the
  permissions below. Backend: `setSpaceProfile`, `uploadSpaceIcon`, `spaceIconUrl`,
  `pageCounts` on `MonadWiki`, checked with `canAdministerSpace`, over Mem, Http and SQLite;
  API `PUT spaces/<id>/profile`, `POST spaces/<id>/icon`, `GET spaces/<id>/icon/<blob>`, `GET
  spaces/page-counts`; migration `0007-space-profile.sql` (`home_page` referencing `pages` `ON
  DELETE SET NULL`, `icon`, `description`); moving or deleting a page clears a home that
  pointed at it; blob garbage collection counts icon blobs; export and import carry the three
  fields and icons under `icons/<space id>`, an import into an existing space fills only what
  is still empty. The owner's addition: `.actions.page-actions` and the editor's toolbar stick
  under the header (`jsbits/layout.js` sets `--header-height` and `--page-actions-height` from
  the real sizes and `data-stuck` while stuck; nothing changes in print). The smoke tests
  leave `data-stuck` and `.recent-spaces` out of their count of hydration repairs, since the
  script and `localStorage` set them, not Halogen. Tests: core model tests, the contract's
  `profiles` section on four backends, HTTP per permission rule, server render 200/403/404,
  migration from 6, import of the new fields, `Test.Hydrate` on the new routes at zero
  repairs, `Test.Browser.Spaces` (directory, switcher, settings, icon upload, home page, sticky
  bar), both smoke tests through the directory, a home page, `pages/` and an uploaded icon;
  core 651 + 99, api 122 + 71, app 908, server 604, browser 182.
- **WP4.7 LaTeX delimiters** (the owner, 2026-10-25): `\(…\)` for inline and `\[…\]` for
  display math, beside `$…$` and `$$…$$` (pandoc's `tex_math_single_backslash`). Decided with
  it: a `\[` or `\(` then starts math rather than escaping a bracket, as in pandoc; a literal
  bracket needs no escape outside links, and `docs/markdown.md` says so. A commonmark syntax
  spec of our own in `wiki-core` beside `mathSpec`, the same `Math` nodes, so rendering,
  search, slides and the preview need nothing. Started on `wp4.7-tex-delimiters` beside WP4.6.
- **WP4.7 merged** (2026-10-25, PR #66, `main` at `5c87f9d`). `\(…\)` and `\[…\]` read as
  inline and display math through `Wiki.Core.Markdown.TexMath.texMathSpec`, placed before
  `defaultSyntaxSpec` so it sees the backslash before the escape does; the same `Math` and
  `MathBlock` nodes, so nothing downstream changed. Accepted with it: an opener nothing
  closes in the paragraph falls back to the escape; an existing page with a literal `\[…\]`
  pair now shows a formula (none in the demo). `attachmentReference` writes a name's brackets
  as `&#91;`/`&#93;` since `\[1\]` would be math (the read-back property caught it);
  `parsec` added to wiki-core; `docs/markdown.md` documents the four delimiters; a browser
  test checks the preview sets both kinds. Rebased over WP4.6 with one changelog conflict.
- **WP4.8 Pin bump to haskell-halogen `f7ee7e3`** (the owner merged #72 to #76 on
  2026-10-25): a subscription's action now runs nested in the effect that dispatched its
  event (`preventDefault` from a `Window` emitter's action is in time when the page itself
  dispatched the event from an effect; a key the user presses while the loop is busy is still
  queued, so the slides' wrapped `keyDown` of WP4.3, which prevents the default in the
  listener, stays), `H.component` built from handlers
  (`H.onAction`, `H.onInitialize`, …; `mkComponent` stays; no module here imports `Halogen`
  unqualified, so the new `component` export clashes with nothing), hspec-halogen's
  `isVisible` counts `visibility: hidden` as hidden (the stylesheet uses none). Its own small
  package after WP4.6 and WP4.7 merge, since a bump rebuilds every package on both backends;
  adopt the handler form where a component is touched anyway, not wholesale. Started
  on `wp4.8-pin-bump` from `main` `57e2cac` on 2026-10-25 while WP4.6's CI ran, since the
  agent's build takes as long either way; it rebases before its pull request.
- **WP4.8 merged** (2026-10-25, PR #67, `main` at `29931c3`). One line: the pin is
  `f7ee7e3`. Nothing else had to change: no module imports `Halogen` unqualified, nothing is
  styled with `visibility`, no test relied on a queued subscription action, and the slides'
  `keyDown` wrapping stays, as decided above. The handler form (`H.component`) is adopted
  nowhere yet; use it in components written or touched from now on. Found on the way:
  `Wiki.Server.Storage.Migrate` embeds `migrations/` with `embedDir`, and GHC does not
  recompile it when a file is added to the directory, so a worktree with an older build runs
  the old migrations and `wiki-server-test` fails with "no column named …" until
  `dist-newstyle/native/build/*/*/wiki-server-0.1.0.0` is deleted; CI builds from scratch.
  The Wave A agents were told; a package that adds a migration may make the module depend
  on the directory's files.
- **Wave A started** (2026-10-25) from `29931c3`, four worktrees in parallel: WP4.9 on
  `wp4.9-backups`, WP4.11 on `wp4.11-account-hygiene`, WP4.12 on `wp4.12-presence`, WP4.16
  on `wp4.16-export`. Each brief names what the others touch (the page's action bar, the
  panel's Server section, migrations numbered at rebase).
- **WP4.16 merged** (2026-10-26, PR #68, `main` at `a777568`). `pandoc` 3.12.1 linked into
  `wiki-server` as a library, built `+embed_data_files -http` (an export can never make the
  server fetch anything), two `allow-newer` entries (`pandoc:crypton`,
  `pandoc-types:QuickCheck`) so the rest of the plan does not move; about 20 minutes once
  into the cabal store, so the first CI run and the first `deploy-local.sh` after it are that
  much longer. `Wiki.Api.Export`: `docx`, `html` (self-contained, MathML, served sandboxed),
  `epub`, `pdf`, `pptx`, `beamer-tex`, `beamer-pdf`; `GET pages/<id>/export/<format>` and
  `GET spaces/<id>/export/<format>`; the session's new `exports` field lists what this server
  makes, so the Export menu (`View/Export.hs`, a `<details>` in the page's action bar and the
  space's actions; none in the demo) and the panel's "Export" row (whether `xelatex` was
  found, looked up on every request) are right in the server's render. `Wiki.Server.Export.
  Document` is pure: our Markdown read by pandoc's reader with our extensions, raw HTML
  through our allowlist first, every formula with the KaTeX macros (built-in, the space's, the
  page's) expanded by texmath, image attachments in the media bag, other attachments and page
  links as links under the public address, Mermaid a note with its source, TikZ raw LaTeX in
  the LaTeX outputs and a note elsewhere, decks cut as `Slides.deckOf` (level 1 title or
  section slide, `::: notes` to `\note{}` or speaker notes, aspect 16:9/4:3, `beamer` theme
  Madrid), a space as one document in page order with title page and three-level contents.
  Export permission is read permission; one export at a time per person (429 meanwhile); 60 s
  timeout that also stops TeX; a pandoc or TeX failure is `Invalid` with its message. Review
  added `restrictTeX`: `openin_any=p`, `openout_any=p`, `shell_escape=f` set in the process
  environment before each `makePDF`, since a TikZ block or a formula is author-written TeX
  and `\input{/etc/passwd}` would otherwise reach xelatex; a PDF test exports such a page and
  checks nothing leaked (pending where `xelatex` is absent, as the other PDF test). Limits:
  the document is built in memory, not streamed, and `HEAD` builds it too; only
  `\newcommand`, `\renewcommand`, `\DeclareMathOperator` are expanded; the PDF path has run
  nowhere yet (no `xelatex` in the agent's container; the runner decides). Tests: 23 server
  cases (mapping natively, each format over HTTP with structure checks, refusals, the lock),
  6 browser cases, the server's smoke test downloads a DOCX; server 629 (2 pending). The
  Dockerfile takes `--build-arg WIKI_TEX=1`. Skylighting is now linked, ready for the
  server-render swap.
- **WP4.9 merged** (2026-10-26, PR #69, `main` at `bd0cf20`). Backups the server makes
  itself, only once an administrator turns them on in the panel's Server section ("Backups",
  `View/Backups.hs`, its own component mounted by the section; the demo shows it disabled).
  `Wiki.Api.Backups`: on/off, `DailyAt h m` (**UTC**) or `EveryHours n`, retention `{daily,
  weekly}` (the newest, plus the newest of each of the last N days and M ISO weeks), an
  optional destination (a directory that must exist, or an `rclone` remote whose config is a
  write-only secret as WP4.4's), `GET`/`PUT admin/server/backups`, `POST …/backups/run`.
  `Wiki.Server.Backups`: a thread started with the server, rereading the settings each
  minute and woken by a change or "Back up now"; `VACUUM INTO data/backups/<time>.sqlite`
  with the storage held for the copy only, then `PRAGMA integrity_check` (a failing copy is
  deleted), pruning, the off-site copy (`rclone copyto` + `rclone copy --ignore-existing` for
  the blobs, laid out as a data directory, nothing deleted there; the config written per run
  to a 0600 file in a 0700 temporary directory, deleted after); errors logged and retried a
  minute later; the last result in the `backup-last` settings row (no migration, no log
  table). `--rclone PATH` names the program only. `wiki-server restore BACKUP --data DIR
  [--attachments DIR]` checks integrity, schema and version, refuses a directory a server
  holds, moves the old database to `DIR/replaced/<time>/`, brings missing attachment files
  over and warns about the rest. Live detection is an OS lock on `<data>/wiki.lock` held by
  `openStorage` (not by `withStorageAside`, so the console's `users`, `oidc` and `backup`
  work beside a running server); a second storage on one data directory is now refused
  (`DataDirInUse`), tests that restarted a server use `withDemoRestarted`. Agent's choices
  the owner may revisit: "Back up now" is refused while backups are off; schedule times are
  UTC; the deploy's `backup --keep 10` counts every file in `data/backups`, so a deploy can
  cut the panel's weekly history and the panel's pruning can delete deploy backups (both in
  the README). Also fixed: the server smoke test's provider step clicked before the program
  had adopted the page. Tests: 11 HTTP cases with a fake `rclone`, 7 storage cases including
  back up → restore into a fresh directory → compare every table and the archive, 2 browser
  cases, the smoke test turns backups on, backs up, has `restore` refused under the server
  and done beside it. Not run: the Docker image (the README's Docker restore line).
- **WP4.12 merged** (2026-10-26, PR #70, `main` at `7d2a9d9`). Presence and edit conflicts
  over WP4.5's channel, no migration. Protocol: `ClientMessage` gains `StartEditing`/
  `StopEditing`; `PageEvent` gains `Editing [Author]` and `PageChanged UTCTime` (the new
  version's time, not the body); `Subscribed` carries who was editing. **Deviation from the
  plan's wording, accepted:** editors are `Author` (id and display name), not `User`, since
  `User` carries the login and these events reach anonymous readers of public pages. Server:
  `Wiki.Server.Presence` is a pure value kept by the hub in the same STM transaction as the
  notifications; `editing` is accepted only from someone who may edit the page
  (`Storage.editorOf`); each change tells a page's subscribers who edits it other than that
  connection (so one's own other tab shows as "You (in another tab)"); a connection's end
  drops its presence; `savePage` and `restoreVersion` publish `PageChanged` after commit. App:
  `Live.Feed` gains `startEditing`, `stopEditing`, `editorsOf`, re-announces after a
  reconnect and remembers the last editors per page; the HTTP cache drops read pages on
  `PageChanged`; the page view shows "X is editing this page." as the last element of the
  action bar and reloads at once on a newer save, or offers "Changed since: show the new
  version" while the reader is busy (text selected, a quote being commented on, rename or
  move open); the editor announces itself only once it knows who else edits, asks first when
  someone does ("Edit anyway" / "Back to the page"), names the others, notes a save made
  meanwhile, says `stopped` on finalize (no `pagehide` handler: a closed tab ends the
  connection). Conflict view on 409: their version and its author read, the author's text
  saved as a draft at once, their version diffed against the author's text with
  `Wiki.Core.Diff` rendered by the new shared `View/Diff.hs` (taken out of the history view),
  two columns from 961 px; "Keep mine" saves over theirs, "Take theirs" loads theirs and
  discards the draft, "Merge by hand" keeps the author's text with their changes since the
  base beside it and saves against their version next. The demo has the conflict view but no
  presence, and two demo tabs cannot conflict (each holds its own wiki). Limits: "X is
  editing" can be stale while the socket is down (corrected on reconnect); one's own save
  from another tab reads "Someone else has saved"; the reload costs one extra request. For
  WP4.10: `Hub.connections` and `Hub.presence` count sockets and editors. For WP4.13:
  `PageChanged` carries only `updatedAt`; extend it rather than adding a second event. Tests:
  `Test.Server.Presence`, three WebSocket cases, cache `afterEvent`, browser cases for the
  three ways out and for presence over the fake server, the smoke test with two users' tabs
  over the real WebSocket. The editor's typing tests time out under heavy load on `main` too
  (pre-existing).
- **WP4.11 merged** (2026-10-26, PR #71, `main` at `fedc318`). Migration
  `0008-account-hygiene.sql` (`users.email`, `email_verified_at`; `sessions.public_id`,
  `address`; tables `totp`, `recovery_codes`, `reset_tokens`, `email_verifications`, each
  cascading with its user). Sessions: the account panel lists them (signed in, last seen at
  most once a minute, address, this browser marked), "Sign out" per session, "Sign out
  everywhere" keeps the current one; a session's `public_id` is what the page sees, never the
  cookie's secret. TOTP: `Wiki.Server.Totp`, RFC 6238 over crypton's HMAC-SHA1, 30 s, 6
  digits, ±1 step, each code once (`last_counter`), tested on the RFC 4226 and 6238 vectors;
  the QR code's module matrix computed by `qrcode-core` on the server (native only;
  `allow-newer: qrcode-core:containers`) and drawn by Halogen as an `<svg>` of `<rect>`s, one
  per run of dark modules; one code confirms; ten recovery codes (80 bits, SHA-256) shown
  once, each once; at sign-in 401 `SecondFactorRequired` with a `wiki_pending` cookie
  (`HttpOnly; SameSite=Strict`, five minutes, five wrong codes) and `POST
  session/second-factor`; **provider sign-ins need the code too** (the callback answers a
  server-rendered code form posting to `auth/<provider>/second-factor`; the owner may want
  OIDC to bypass TOTP, an easy change); wrong codes count as failed sign-ins; the user removes
  it with a code, an administrator from the Users row or `wiki-server users
  second-factor-remove LOGIN` (through `withStorageAside`, no lock). E-mail: set in the panel
  or the administration's "New user", verified by a mailed link valid one day with a confirm
  button (so mail scanners do not verify); not exported, like the password hash. Reset:
  "Forgot your password?" takes a login or an address, mails a single-use 30-minute link to a
  verified address only, answers 204 whatever the input with the lookup and the mail on a
  thread after the answer, limited to 10 requests per address in 15 minutes and 3 mails per
  account per hour; the reset ends every session and signs nobody in, so the second factor
  still applies; without mail configured the forms say so. **Beyond the brief, accepted:**
  changing or removing the address and starting a second factor require the current
  password where the account has one (a hijacked session could otherwise set its address,
  verify it and reset the password). The TOTP secret is stored in clear, as the mail
  password is. Demo: the switcher's "Your account…" shows the one session, second factor and
  mail disabled with a note. For the next packages: `MonadSecurity` (`Wiki.App.Security`) is
  required by the shell; `SignInError` gains `SecondFactorNeeded`; `NewAccount` an optional
  `email`; `Directory` gains `secondFactor`, `emails`, `mailing`; `resolveSession`, `signIn`,
  `register`, `acceptInvitation`, `landWith` take the request's address; `Env` gains
  `resets`, `pending`, `logger`; WP4.13 mails verified addresses only. Not exercised: the
  pending cookie across a real cross-site provider redirect in Chromium (tested over HTTP
  with an explicit cookie). Tests: `Test.Server.Totp`, `Test.Server.Hygiene`, the provider's
  second factor in `Test.Server.Oidc`, migration from 7, log redaction, goldens, hydration at
  zero repairs, `Test.Browser.Security` (9 cases); the smoke test lists sessions, signs out
  everywhere, enrols a second factor from the QR's secret with a JavaScript TOTP and sees
  `SecondFactorRequired`; server 686 (2 pending), app 927, browser 208; `app.wasm` 10 084 KiB
  (2302 brotli).
- **Wave A complete** (2026-10-26): WP4.16, WP4.9, WP4.12, WP4.11 merged in that order, each
  rebased onto the one before (one cycle of CI per rebase on the serial runner; the pandoc
  build cost one run about 40 minutes, cached since). Migrations: `0008` taken by WP4.11;
  Wave B's start at `0009`. Open for the owner: "Back up now" while backups are off, backup
  times in UTC, the deploy's `--keep 10` versus the panel's retention, OIDC bypassing TOTP.
- **Wave B started** (2026-10-26) from `main` after WP4.11: WP4.10 on
  `wp4.10-observability`, WP4.13 on `wp4.13-notifications`, WP4.14 on `wp4.14-blog`, in
  parallel worktrees; each brief names what the others touch (`Render.hs`, `View/Page.hs`,
  `View/Space.hs`, the account panel, migrations numbered at rebase).
- **WP4.10 merged** (2026-10-26, PR #72, `main` at `fcb3c67`). Migration `0009-audit-log.sql`
  (no foreign keys: rows outlive users and spaces and survive imports). `Wiki.Core.Audit`,
  `Storage/Audit.hs`: one row per administration write in the same transaction (`record`):
  space grants, public flag, space and page deletion, wiki-wide grants, groups and members,
  accounts (create, password, disable, second-factor and identity removal), wiki, server and
  backup settings, invitations, imports, self-registration and provider sign-ins
  (`user.register` with the provider), the console's `users` commands as `administrator` from
  `console`; secrets only as `changed`/`cleared`; refused writes record nothing; the address
  reaches the storage through `Caller.address` and `runSqliteWikiFrom`. `GET
  admin/activity?actor=&offset=`, 50 per page, newest first; the Admin page's "Activity"
  section (`View/Activity.hs`) with a person filter and Newer/Older; the export carries
  `audit.json` (only when there are entries; old archives import), import merges by id and
  records itself. `GET /metrics` on the admin listener only, at the listener's root
  (`http://127.0.0.1:8081/metrics`), Prometheus text written by hand (`Wiki.Server.Metrics`,
  no dependency): `wiki_http_requests_total{listener,route,method,status}` (status class,
  method from a fixed set), `wiki_http_request_duration_seconds{listener,route}` with the
  default buckets, gauges `build_info`, `start_time_seconds`, `schema_version`,
  `websockets_open`, `spaces`, `pages`, `attachments`, `users`, `database_bytes`, `blobs`,
  `blob_bytes`, `backups_kept`, `backup_age_seconds` (the newest file in `data/backups`), the
  counter `errors_total`; route labels are the patterns of servant's own router structure
  (`Wiki.Server.Routes`), so ids and secrets never become labels. `GET /healthz` (new, not
  extended: it did not exist) on both listeners before the closed-wiki rule: `status`,
  `schemaVersion`, `lastBackupAgeSeconds`, 503 when the database cannot be read; the
  Dockerfile's `HEALTHCHECK` asks it. `admin/status` gains `schemaVersion`, `lastBackup`,
  `connections`, `errors` (the last 20 error-level log lines, `Log.keepingErrors`; a 5xx is
  logged as an error; backup failures are warnings and show in the Backups part instead); the
  Server section's "Status" block (`View/Status.hs`) with Refresh. Over HTTP the two reads
  use `once`: the first from the server-rendered preload, then fetched fresh. Fixed on the
  way: `Storage/Migrate.hs` has `-fforce-recomp`, so a new migration file is seen without
  deleting the build. For the next packages: `Caller.address`; `Env.errors`, `Env.metrics`;
  `logRequests` takes a route and an observer; `Archive.audit`; `applyImport` takes an actor
  and an address; a new administration write calls `record` and adds its action to
  `Wiki.Core.Audit.actionText` and `docs/api.md`; a new admin read must be answered by
  `Test.Hydrate.apiOver` and `Test.Browser.Http.serveDemo`. Tests: `Test.Server.Metrics`,
  `Test.Storage.Audit`, `Test.Server.Observability`, admin contract cases on three backends,
  `Test.Browser.Activity`, goldens, the smoke test's step for `/healthz`, `/metrics` and the
  activity; server 712 (2 pending), app 929, browser 210.
- **WP4.14 merged** (2026-10-26, PR #73, `main` at `8e33be4`). Migration `0010-space-blog.sql`
  (`spaces.blog`); the flag is part of `SpaceProfile`, set from "Show as a blog" in Space
  settings, carried by the export as an additive field. `Wiki.Core.Blog`: posts are the
  space's top-level pages other than its home page, newest first by creation date (the first
  version); nested pages are not posts; `neighbours`, pages of 10 (`?page=n`, the new `Posts`
  route), `excerptOf` (the first paragraph with text, markup, images, inline code and footnote
  marks dropped, formulas kept as TeX, cut on a word at 300 characters), `firstImage`. New
  read `postDetails` (first author and comment count per page) on Mem, HTTP (cached,
  preloaded, dropped on a comment write) and SQLite, `GET spaces/<id>/post-details`.
  `View/Blog.hs` reuses the directory's cards, the home page above the list; `postInfo` in
  `View/Page.hs` shows "Posted <date>" and Previous/Next in the blog's order. `Wiki.App.Head`:
  the shell's `Settled` answers with a `Head` (title, description, `og:title/description/url/
  type/image`, `<link rel="alternate">` for a public blog) written by `Static.withHead` for
  both the prerender and the server render; further `<head>` content goes in `headTags`.
  `Wiki.Server.Feed`: `/s/<space>/feed.xml` (Atom) and `/feed.rss` (RSS 2.0, author in
  `dc:creator`) with the newest 20 posts' full HTML through the allowlist and absolute links;
  `/sitemap.xml` of public spaces and pages with `lastmod`, capped at 50 000; only what an
  anonymous reader may see, 404 otherwise and in a closed wiki; absolute addresses from the
  panel's public URL, else the request's forwarded host and scheme (`Wiki.Server.Address`).
  Limits: the demo's blog has two posts and no authors (more posts break 24 contract and
  order tests; archives carry no versions, so imported pages have no author); the demo's
  prerender has a path for `og:url`; feeds asked on the admin listener without a public URL
  fall under `/admin/`; no visible feed link, only the `<link>`. Feed tests validate against
  RELAX NG schemas (RFC 4287's; RSS 2.0's written from the spec) with `xmllint` and are
  pending where it is missing (`libxml2-utils` added to the runner's package list in the
  README). Follow-up noted: `setSpaceProfileTx` is not audited (WP4.10 left it out), so a
  profile change, the blog flag included, writes no `audit_log` row; add a `record` there in
  the next package touching `Storage.hs`. Tests: core 682, app 959, server 732 (2 pending),
  browser 212; both smoke tests walk the blog, the server's checks the public blog, head tags,
  both feeds, the sitemap and the 404s.
- **WP4.13 merged** (2026-10-26, PR #74, `main` at `f769551`). Migration
  `0011-notifications.sql`. Mentions: `Wiki.Core.Markdown.Mention`, a pass after commonmark
  (`splitMentions`, a `Mention` inline; skipped inside code, links and embeds; a trailing `.`
  or `-` is not part of the login; `mentions` collects a document's logins);
  `Options.resolveMention` turns one into a link when the login exists, else plain text; a
  mention links to a search for `@login` titled with the user's name (no profile pages), and
  logins are resolved only for the mentions a view shows and only for someone signed in.
  Rules as pure functions in `Wiki.Core.Notification` (`recipients`, `pageWatch`/`spaceWatch`
  tri-state: a page's mark, then the nearest space's, then "my own page"; `newlyMentioned`,
  `digest`, mail modes; the type is `Happened`, not `Activity`, to avoid WP4.10's
  `Wiki.Api.Activity`), with QuickCheck properties: nobody of their own actions, nobody of a
  page they may not read, each person once. API `Wiki.Api.Notifications` (list, mark read,
  settings, people, page and space watches), `POST unsubscribe/<secret>`, `ServerMessage`
  `Notified`. `MonadNotifications` with a contract on Mem, IndexedDB (store `notifications`,
  database version 5), SQLite, HTTP (people, notices and watches cached and preloaded); the
  live channel gains `listen`/`unlisten`. Server: notifications created in the save's or
  comment's transaction and sent to the user's connections after commit (`Events.notify`); a
  new page notifies watchers as a save does; `Wiki.Server.Notifier` mails at once or as a
  daily digest from 07:00 UTC, only to a verified address, re-checking the permission to read
  before mailing, waiting a wake or a minute before its first look (its start-up pruning
  locked the database under a test); the unsubscribe token is an HMAC with a key in
  `settings`; pruning keeps 90 days and at most 500 per user; the operator account gets none
  (403). UI: `View/Bell.hs` (unread count, the latest 50, mark read per item and all, live),
  `View/Watch.hs` (one element in the page's action bar, one in the space's and the blog
  view's actions), `View/NotificationSettings.hs` (one block in the account panel and the
  demo's; the mail setting is NULL until chosen, an unverified address counts as off),
  `View/Unsubscribe.hs` (`/unsubscribe/<secret>/` with a confirm button so a mail program's
  fetch turns nothing off); the server renders all of it, adopted without repair. Also added
  (the planning session's ask): `setSpaceProfileTx` and `uploadSpaceIconTx` now record
  `space.profile` in the audit log with the fields that changed in words, a save that changed
  nothing records nothing. For later packages: a view that shows Markdown fills
  `Body.Place.people` through `Body.askPeople`/`unasked`; a new HTTP read must be answered by
  `Test.Hydrate.apiOver` and `Test.Browser.Http.serveDemo` or be in the preload where tests
  assert nothing else is asked. Tests: core 714, app 996, server 773 (2 pending), browser 217;
  the server's smoke test mentions a user in a comment and sees the bell in their tab over the
  WebSocket.
- **Wave B complete** (2026-10-26): WP4.10, WP4.14, WP4.13 merged in that order; migrations
  `0009`, `0010`, `0011`. Two packages took `0009` at once and the second renumbered at rebase,
  as planned. Open for the owner: nothing new.
- **Wave C started** (2026-10-26) from `main` after WP4.13: WP4.15 on `wp4.15-toc-templates`
  and WP4.17 on `wp4.17-offline-pwa`, in parallel worktrees; the next migration is `0012`
  (WP4.15's `template` flag; WP4.17 has none).
- **WP4.17 merged** (2026-10-26, PR #75, `main` at `8f78703`). No migration.
  `web/manifest.webmanifest` (relative addresses, so one file serves the server's base path,
  `/admin/` and the demo; `start_url`/`scope`/`id` `./`, standalone, theme `#f6f8fa`; an SVG
  icon and 192/512 px PNGs, plain and maskable, drawn at build time by `web/src/pwa.mjs`, a
  small rasteriser of our own over `web/src/icon.svg`, no dependency; there is no wiki-wide
  icon, so the uploaded-icon branch never applies); linked from `web/index.html` (every page,
  404 and the loading page included, comes from that template; `headTags` holds only what
  differs per route). `web/src/sw.js`, written by `bundle.sh` as `sw.js` with a version that
  is a hash of the files it precaches; activation deletes other versions' caches; **network
  first for everything**, the cache only when the network fails, app files rewritten only on
  an ETag change; cached on install: the program, scripts, CSS, KaTeX fonts, CodeMirror,
  Mermaid's entry, the manifest, the icons, the offline page; cached on read: pages (50,
  oldest out), API GETs (300), attachments and space icons only as images up to 1 MB; never
  cached: `api/v1/session`, `admin/…`, `account/…`, `notifications…`, `events`, `archive/…`,
  `invitations/…`, `password-reset/…`, `email-verification`, `unsubscribe`, `pages/*/draft`,
  exports, anything under `auth/`; writes untouched; the first page, loaded before the worker
  existed, is kept on a `keep-page` message. A page served from the cache offline gets `<meta
  name="wiki-offline-copy" content="<time>">` from the worker (a page cannot read its own
  response headers), which `Wiki.App.Offline` shows as "You are reading an offline copy from
  <time>" above the route over the server backend (not the demo, whose content is live from
  IndexedDB) with the `.offline-notice`, until the next route; `web/offline.html` for a page
  never read, listing what can be read offline; "Install" in the header beside the bell while
  the browser's `beforeinstallprompt` offer (kept by `index.js`) is open; sign-out over HTTP
  deletes the page and answer caches (`forgetReads`), the app files stay; the WASI shim is
  bundled from `node_modules` (locked 0.3.0) instead of jsDelivr so the page starts offline;
  `.webmanifest` served as `application/manifest+json` by `Static.hs` and
  `toolchain/deploy-server.mjs`. **Secure context only:** browsers run a service worker over
  HTTPS or on localhost, so the owner's plain-HTTP Tailscale deploy gets no worker and no
  Install and works as before; the admin listener on loopback and the demo on Pages do. HTTPS
  (deferred from the owner's pick) is therefore the next productionisation item worth doing.
  **Plan correction (drafts):** the plan said the editor keeps drafts locally and sends them
  when back online; in fact the draft lives on the server (`saveDraft`), an autosave that
  fails offline says "Draft not saved" quietly and retries at the next change, not on
  `online`; verified, not rebuilt; a retry on `online` is a small follow-up. Under Playwright
  a page the worker serves offline reads `navigator.onLine` as true, so the shell treats any
  offline copy as offline. For later packages: the smoke tests' existing parts open pages with
  `serviceWorkers: "block"` (their Playwright routes do not see a worker's traffic), new parts
  need the same or their own context; the browser test runner loads every top-level `.js` in
  its asset folder as a classic script, so `wiki-app/test/web/bundle.sh` deletes `sw.js` and
  `wasi-shim.js`; a new API GET is cached unless added to the worker's never-cached list.
  Tests: manifest validity and linking natively, the server serving `sw.js`, the manifest and
  `offline.html` on both listeners and under a base path, 6 browser cases, one offline part in
  each smoke test (offline reload with the copy line and notice, another space from cached
  answers, a page never read gets the offline page, back online gets the live page, sign-out
  leaves nothing cached); not tested: the caps and trimming. Server 774 (2 pending), app
  1000, browser 223.
- **WP4.18 started** (2026-10-26) on `wp4.18-https-deploy` from `main` `1f1a7df`, beside
  WP4.15's pull request; it touches only `toolchain/` and the README.
- **WP4.15 merged** (2026-10-26, PR #76, `main` at `f181a62`). Migration
  `0012-page-template.sql`. Heading ids in one pass at parse time (`Ast.withHeadingIds` over
  `Slug.headingSlug`: lower-cased, letters of every script with their diacritics kept, digits,
  `_` and `-` kept, white space to `-`, punctuation and emoji dropped, dashes collapsed, an
  empty result is `section`; duplicates `-2`, `-3`… in document order, never an id written in
  braces), replacing commonmark-extensions' `autoIdentifiersSpec`, **so the second of two
  equal headings is `x-2` where it was `x-1`** (old links to `-1` no longer hit). An empty
  `<a class="heading-anchor">` ends each heading, the `#` drawn on hover by the stylesheet, so
  the page's text, comment quotes and search are unchanged; `Options.headingAnchors` turns
  them off (feeds do). `[[toc]]` as a paragraph that is exactly that wikilink (any case) is
  the `TableOfContents` block, `<nav class="toc">`; `Wiki.Core.Markdown.Toc` builds the nested
  list of top-level headings (a skipped level nests one down) for the inline list and the
  "Contents" panel, a `<details>` shown for 3 or more headings when the page has no `[[toc]]`,
  built from the parsed page so the server render and the prerender include it;
  `jsbits/toc.js` keeps the fold in `localStorage` and marks the current section as
  `data-current` with IntersectionObservers (the last heading above a line a quarter down the
  window; the last in the window at the page's end), which both smoke tests leave out of
  their repair counts. Layout: from 1200 px one sticky column beside the text (contents, the
  comments stacked under them when open), 761 to 1199 px the comments beside and the contents
  above, at 760 px and below both around the text. Following a fragment link writes `#id`
  into the address bar with `replaceState`, and a page opened with a fragment scrolls to it
  (`wiki_scroll_to` in `jsbits/browser.js`, leaving `#/…` hash routes alone). Templates:
  `Page.template` (export additive), `treePages`/`templatePages`, a template is never a post,
  `SearchQuery.templates` false by default (no search UI asks for them yet), `PUT
  pages/<id>/template` (Edit; not a save: no version, `updatedAt` unchanged; a space's home
  page refused), page counts leave templates out, an import keeps the archive's flag on a new
  page; `Wiki.Core.Template` holds the built-ins (meeting notes, decision record, how-to) as
  Markdown files embedded by Template Haskell (`template-haskell` now a wiki-core dependency,
  builds on wasm); `fillTemplate` fills exactly `{{title}}`, `{{date}}` (UTC date),
  `{{author}}` once; "Use as template" is one `aria-pressed` toggle in the action bar, a note
  above a template page, "Templates" sections in the sidebar and the space's pages list, "New
  page" offers Blank, the space's templates and the built-ins; the demo's Team space has a
  "Weekly sync" template and the handbook a `[[toc]]`. Also on this pull request (the owner:
  "utwardź, bo ciągle się pojawia"): the editor's "loses no keystroke while the preview
  catches up with a long page" types the long run one word per `typeText` call, since
  hspec-halogen's `typeText` is Playwright's `pressSequentially` with a 5 s timeout per call
  it cannot change and three words timed out on a busy runner; passed three times in a row
  and once under load; `--match` takes a plain substring of the description, not a path.
  Limits: pandoc exports use pandoc's own heading ids; a heading titled like a footnote id can
  collide with it; `[[toc]]` links in feeds are bare fragments; persisted demo data shows the
  template only after a reset. Tests: `Test.Markdown.Toc`, `Test.Template`, render markup,
  a contract section, HTTP for the flag and the search exclusion, migration from 11, export
  dropping `[[toc]]`, hydration at zero repairs for the guide (panel) and the handbook
  (`[[toc]]`), `Test.Browser.Contents` (7), both smoke tests (a page from a template; the
  server's checks the imported template, the panel and `[[toc]]` at zero repairs, and
  `#heading` scrolled to and marked); core 760, app 1029, server 789 (2 pending), browser 224.
  Process note: the planning session pushed a plan-only commit to `main` while this pull
  request's CI ran, which cost one extra rebase and CI cycle; plan commits are held on the
  session branch while a pull request is in CI.
- **WP4.18 merged** (2026-10-26, PR #77, `main` at `f9dfa80`). `deploy-local.sh --server`
  and `--static` serve HTTPS by default: the listener binds to `127.0.0.1:<port>`, the
  server's unit carries `--secure-cookies`, and once the service answers on loopback the
  script runs `tailscale serve --bg http://127.0.0.1:<port>` (tailnet only, never Funnel),
  then checks `https://<name>.<tailnet>.ts.net/` (`api/v1/info` for the server), waiting up
  to `WIKI_DEPLOY_HTTPS_WAIT` (60 s) for the first certificate before warning, and prints that
  address first. Each deploy reads `tailscale serve status`: a serve already proxying to the
  port is left as it is (a hand-set one, as on the owner's machine, counts as the
  deployment's), one on the deployment's previous port is moved, anything else at the
  address is left alone with a warning. The script never runs sudo for the serve: it runs
  `tailscale serve` as the user (tailscaled's operator) and, failing that, prints `sudo
  tailscale serve --bg …` and `sudo tailscale set --operator=$USER` and carries on, answering
  on loopback. `tailscale status --json` says whether MagicDNS (`CurrentTailnet.
  MagicDNSEnabled`) and certificates (`CertDomains`) are on; if not, or when Tailscale does
  not answer, it warns, points at the admin console's DNS page and serves plain HTTP, keeping
  `https=yes` in the state so a later run moves to HTTPS; a CLI older than 1.52 gets the
  older `serve https:443 /` form printed, not run. `--http` restores the old behaviour
  (Tailscale address, ufw rule, no Secure cookies), turns the deployment's serve off and drops
  `--secure-cookies` on redeploy; `--https` is the way back and drops a remembered
  non-loopback bind; a `--bind` other than `127.0.0.1` (including `::1`) implies `--http`. A
  deployment from before this change moves to HTTPS on its next run and its `tailscale0` ufw
  rule is deleted. The script reads the admin listener's server settings and reminds the
  owner to set the HTTPS address as the panel's public address when none or a different one
  is set (a panel action, decision 11). `--status` shows the serve; `undeploy-local.sh` and
  `--stop` run `tailscale serve --https=443 off` for the deployment's serve (edge: with more
  than one handler on 443 the command asks for confirmation and fails under `/dev/null`, and
  the hint wrongly suggests sudo). State gains `https`, `https_host`, `serve_port`. README:
  HTTPS first, prerequisites (MagicDNS, HTTPS Certificates, the operator), the hostname in
  public Certificate Transparency logs, the service worker and "Install" needing HTTPS, the
  demo's browser data per scheme and port (an import from a plain-HTTP demo needs the server
  on `--http` or an export first). Also: `toolchain/test-deploy-server.mjs` expected the
  request log without `route=` (WP4.10) and had been failing unnoticed because
  `test-deploy-local.sh` was not in CI; fixed, and the script now runs as a step of CI's
  `native` job (about two minutes, fakes only, the real binary for the last stage). Not
  tested against a real tailscaled (none in the sandbox); the CLI formats were checked against
  Tailscale's sources; the owner's first real deploy is the end-to-end check. Known: a second
  deployment (`--name`) on one machine cannot share port 443 and should use `--http`. Tests:
  36 deploy cases (the fake `tailscale` records `serve`, answers `serve status`, simulates
  access denied; a fake `curl` reaches the proxied listener), 10 deploy-server, 10 static.
- **Wave C complete; the owner's Phase 4 pick is done** (2026-10-26). Merged in Phase 4:
  WP4.2 slides, WP4.3 pin bump and `Net.Fetch`, WP4.4 server settings from the panel, WP4.5
  comments, WP4.6 one space at a time, WP4.7 LaTeX delimiters, WP4.8 pin bump, WP4.16 export,
  WP4.9 backups, WP4.12 presence, WP4.11 account hygiene, WP4.10 observability, WP4.14 blog,
  WP4.13 notifications, WP4.17 offline/PWA, WP4.15 contents and templates, WP4.18 HTTPS
  deploy. Migrations to `0012`. Open items: Polish interface (deferred by the owner); a retry
  of the editor's draft on `online`; a search UI asking for templates; our heading ids in
  pandoc exports; a second deployment on one machine cannot share port 443; the four Wave A
  product questions ("Back up now" while backups are off, UTC backup times, the deploy's
  `--keep 10` against the panel's retention, OIDC bypassing TOTP). Nothing is planned beyond
  this without the owner's word.
- **Build parallelism and the demo's PDFs** (2026-10-26, PR #78, `main` at `000bce4`; the
  owner: "-j do builda", module-level over package-level, since a change rebuilds one or two
  packages). No code: `cabal.project` sets `jobs: $ncpus` and `semaphore: True`, so cabal 3.16
  hands GHC 9.14 a semaphore (`-jsem`) and the modules of one package compile in parallel
  within the one job budget; `cabal-native-opt.project` inherits it, so the deploy's build
  does too. The wasm cross compiler (`9.14.1.20260731`) speaks semaphore protocol v2 where
  cabal 3.16 offers v1 (`-Wsemaphore-open-failure`, an error under `-Werror`), so
  `cabal-wasm.project` turns the semaphore off and gives this repository's packages GHC's
  `-j` through `program-options` instead; revisit `semaphore: True` there once cabal and the
  wasm GHC agree on a protocol. Found on the way: the runner had gained `xelatex`, so
  `Test.Server.Export`'s PDF test ran for the first time and failed, in order, on
  `mhchem.sty` missing (`texlive-science`), on `\pu` (LaTeX's mhchem has none; `withPreamble`
  now adds `\providecommand{\pu}[1]{\text{#1}}` for a page that uses it) and on `soul.sty`
  (`texlive-plain-generic`; pandoc's strikeout and underline). The demo's PDF test is now
  pending, naming the missing files, where `kpsewhich` finds no `mhchem.sty`, `tikz.sty`,
  `soul.sty` or `beamer.cls`, and a new case exports a page that needs nothing beyond LaTeX.
  The runner has `texlive-science`, `texlive-pictures` and `texlive-plain-generic` since
  (the owner installed them), so the full PDF case runs in CI (16 s). README names the
  packages. A process note: the first push of `semaphore: True` broke the wasm build, which
  the native gate did not show; a project-file change needs both backends built like any
  CPP'd code.
- **Phase 5 proposed** (2026-10-26). The owner asked to prepare a public release: a licence
  (which, given the dependencies), the demo on GitHub Pages from IndexedDB, and the
  self-hosted runner kept to the owner's own pull requests. Licences checked in the cabal
  store and the Hackage tarballs: 285 dependencies, all permissive but pandoc
  (GPL-2.0-or-later), texmath and skylighting (cabal says `GPL-2`, the file notices and
  README say version 2 or later), which only `wiki-server` links; in the page, TikZJax is
  GPL-3.0-or-later and its BaKoMa fonts come without a licence file. Decision 24 (MIT,
  proposed) and Phase 5 (WP5.1 licence, runner gating and `--server` by default; the
  owner's step; WP5.2 the Pages deploy) are written; nothing starts before the owner
  confirms the licence. The tree and the history hold neither the tailnet hostname nor
  secrets (grepped); the `maintainer` address is in the `.cabal` files.
- **WP5.1 started** (2026-10-26) on `wp5.1-public-release` from `main` `ba29135`, alone;
  decision 24 confirmed (MIT).
- **WP5.3 added** (2026-10-26, the owner's ask while WP5.1 runs): the README for the
  public, with examples per library and a deck, and screenshots. After WP5.1, beside WP5.2.
- **WP5.1 merged** (2026-10-26, PR #79, `main` at `7fc422d`). `LICENSE` is MIT; each
  package carries an identical copy, since `cabal check` rejects `license-file:
  ../LICENSE` (`malformed-relative-path`), checked byte for byte by
  `wiki-app/test/Test/Licence.hs` (native only; it reads the files as UTF-8 bytes, as the
  POSIX locale broke on the `ś` of the author field). The README's licence section: MIT,
  the sentence on Claude, a table of the third-party licences read from each package's
  metadata (two beyond the plan's list: `@bjorn3/browser_wasi_shim` MIT or Apache-2.0,
  `@lezer/highlight` MIT; DOMPurify named inside Mermaid's bundle), the GPL-3 rule for a
  conveyed `wiki-server` binary, TikZJax and the fonts. TikZJax has no licence file in
  its npm package nor its repository (every usual name 404s), only `package.json`'s
  `GPL-3.0+`, so the FSF's text is kept in `web/licenses/GPL-3.0.txt` (sha256 matching
  Debian's copy); the fonts are BaKoMa Computer Modern, converted to WOFF2 by TikZJax's
  build, so modified, which the BaKoMa Fonts Licence (from CTAN, kept as
  `web/licenses/BaKoMa-LICENCE.txt`) allows provided its notices and the originals'
  location go with the copies: `bundle.sh` writes `tikzjax/LICENSE.txt`,
  `tikzjax/fonts/LICENCE.txt` and a `NOTICE.txt` naming both, and the smoke test checks
  all three are served. The original `kisonecat/tikzjax` says `GPL-3.0 or LPPL-1.3c`;
  the fork shipped (`drgrice1`) says `GPL-3.0+`, which is followed. CI: one expression on
  every job's `runs-on`, `ubuntu-latest` when the pull request's head repository is not
  this one (compared by `full_name`, so a deleted fork, null, goes hosted too), the actor
  ends in `[bot]`, or the dispatch input `runner` is `hosted`; `self-hosted` otherwise;
  `actionlint` 1.7.7 clean; the README's CI section documents both layers and what
  remains (a fork's run uses the fork's copy of the workflow, so approving one means
  reading its `.github/` changes first; write access is access to the runner's user).
  Deploy: `--server` is the first run's default, `--static` the opt-in; a state file from
  before `--server` existed has no mode and stays the demo. Gate: native, wasm, 38 deploy
  cases, smoke test, format, all green; CI green on the self-hosted runner with the new
  expression (actor `Swordlash`). Not run: the hosted path, which only GitHub can run,
  once the repository is public. Carried to WP5.2: the built page ships no notices for
  the MIT/BSD libraries esbuild bundles (KaTeX, highlight.js, CodeMirror, fflate,
  Mermaid, the WASI shim), which a public deploy should add (`--legal-comments=external`
  or a licence file in the build); the `concurrency` group is keyed on the branch name
  alone, so a fork's pull request with one of our branch names would share it (add the
  head repository to the key). Noted: native tests need a UTF-8 locale (`LANG=C.UTF-8`).
  **The owner's step is next**: confirm nothing in the `.cabal` `maintainer` field should
  go, make the repository public, require approval for all external contributors, turn on
  secret scanning and push protection, set Pages to deploy from GitHub Actions, run the
  workflow once with `runner: hosted`.
- **WP5.2 and WP5.3 started** (2026-10-26) on `wp5.2-pages` and `wp5.3-readme`, both from
  `main` `b4d75ac`, side by side (WP5.2 owns the workflow, the toolchain scripts, `web/`
  and the demo's database name, and one paragraph of the README; WP5.3 owns the rest of
  the README, `docs/screenshots/`, `toolchain/screenshots.mjs` and the demo's page texts).
  WP5.2's deploy job is gated on the repository being public, so it can merge before the
  owner flips it without making `main` red.
- **The repository is public** (2026-10-26, the owner), and the hosted path broke at once:
  the owner's dispatch with `runner: hosted` and Dependabot's first pull request (#80,
  fflate 0.8.3, routed to hosted runners by the `[bot]` rule as meant) both failed in the
  `format` job, where `curl` got a 404 for `fourmolu-0.21.0.0-linux-x86_64`: since
  0.20.0.0 fourmolu's releases ship `fourmolu-<version>-<os>-<arch>.zip`, one binary
  inside, and the bare name is gone. Fixed by the planning session (PR #81, `main` at
  `d5a62b8`): the job and `bootstrap.sh`'s `install_fourmolu` fetch the zip, check it
  against `FOURMOLU_SHA256`, pinned at last (`aadf6931…`, the zip's), and unpack the
  binary; checked here against the downloaded zip, `actionlint` clean. Process note: a
  path CI does not run rots; the hosted path had not run since the runner moved to the
  owner's machine, and the next steps of it (`haskell-actions/setup`, the caches, the
  wasm toolchain from ghc-wasm-meta) are exercised by a dispatch on `main` with `runner:
  hosted`, started after the merge.
- **The hosted path's second rot, fixed** (2026-10-26, PR #82, `main` at `4ad21a8`). With
  fourmolu fetched, the hosted `native` and `wasm` jobs failed in `bootstrap.sh ready`,
  the gate every `npm run` goes through: it demanded the whole toolchain whatever the
  command (fourmolu, the wasm sysroot, alex and happy, Chromium), which the self-hosted
  runner has and a hosted job does not (the native job has GHC, cabal and Node; the wasm
  job installs Chromium after its build and no fourmolu; ghc-wasm-meta's `setup.sh`
  writes no sysroot marker). The gate now checks per command (native: GHC and cabal;
  wasm builds: the sysroot, the generators, Node, the npm packages; browser tests:
  Chromium on top; fourmolu nobody's), the hosted wasm job writes the marker, and
  `test-bootstrap.sh` (run by hand, and failing since WP4.3 for want of the WASI shim in
  its fixture) has a case for it and passes its 20. Dependabot's first run also showed
  the hosted wasm job builds the dependency store (about 35 minutes) and caches it. The
  dispatch with `runner: hosted` was started again after the merge.
- **WP5.3 merged** (2026-10-26, PR #83, `main` at `34c8de8`; its first agent was killed by
  accident and a second finished from the worktree). The README opens for a visitor: what
  the wiki is, the demo's address, four screenshots in a table (`page.png`: the Markdown
  guide at its Mathematics section with the formulas, `\ce` and the Mermaid flowchart;
  `editor.png`: the Mathematics page in the editor beside its preview; `slides.png`: the
  Presentations deck at its formulas slide; `spaces.png`: the directory; 79, 132, 40 and
  81 KB, taken by `toolchain/screenshots.mjs` under `npm run screenshots` at 1280×800 in
  headless Chromium, byte-identical across runs), then "Writing pages" with the Markdown
  as typed per library (KaTeX inline and display, the Docs space's macros, a page macro,
  `\ce`; Mermaid; TikZ with `\usetikzlibrary`; code; an alert; `[[toc]]`; images and
  attachments; links) and "Presentations" with the demo's own seven-slide deck; "What it
  does" is a feature list; the operational sections stay (`docs/` has no deployment guide
  to repeat), with two pointers to `docs/api.md`. Deviation from the plan's text, accepted:
  the examples link to whichever demo page already shows each one (Markdown guide,
  Mathematics, Docs' pages and settings, Diagrams, Tour, Team handbook, Presentations)
  rather than all living in Presentations and Tour; the demo gained only a TikZ picture on
  Diagrams loading `positioning` and `arrows.meta`, since no page had a
  `\usetikzlibrary`. `wiki-app/test/Test/Readme.hs` (native) checks every example is on
  the page it links to line for line, every link resolves to a demo space or page, every
  `#fragment` names a heading of that page by `headingSlug`, and every screenshot exists
  under 300 KB; `Test.Demo` requires a `\usetikzlibrary` and a `[[toc]]` in the demo.
  Gate green (wasm, native, 1040 wiki-app examples, browser 230, smoke 84 s, format).
  Not done: CI runs no `node --check` on `screenshots.mjs` (one workflow line, WP5.2's
  file). To keep in mind: the demo's address appears in the README's links and in
  `Test.Readme.demoAddress`; a change to a demo page's text under an example, or a
  renamed heading, fails the test, so the README and the demo change together; after a
  change to the wiki's look, `npm run build-wasm` then `npm run screenshots` and commit.
  Flaky, seen by both WP5.2 and WP5.3 and left alone: `Test.Server.Api`'s "logs each
  request" reads the log right after the response, before the line is written (passes
  alone); `smoke-test-server.mjs` line ~557 asserts the address before it changed (needs
  an `eventually`). Both are a small fix for the next package that touches them.
- **The hosted path works end to end** (2026-10-26): Dependabot's #80 went green on the
  hosted runners after #82 (format, native with its tests and the deploy-script tests,
  wasm with the build, the browser tests and the smoke test; the wasm job 28 minutes with
  the store cached). The dispatch on `main` was cancelled by a fast-forward push sharing
  its concurrency group, which #84 fixes. The owner then asked for WP5.4 (above), chosen
  over always-hosted and over a fixed split per job; it starts after #84 merges.
- **WP5.2 merged** (2026-10-26, PR #84, `main` at `263d3d1`; its first agent was killed by
  accident and a second finished from the worktree). The `deploy` job runs on a push to
  `main` or a dispatch from it, after `native`, `wasm` and `format` or the `tested` skip,
  only while the repository is public (its name says so), on the same runner expression,
  with `pages: write`, `id-token: write`, environment `github-pages` and a `pages`
  concurrency group that queues; it downloads the artifact `app` (from the run
  `ci-already-tested.sh` found when `tested` is true, else this run) into
  `$RUNNER_TEMP` (the self-hosted workspace persists, and a download into it would be laid
  over the last deploy's files), runs `configure-pages`, refuses a page whose `<base
  href>` is not the path Pages reports, then `upload-pages-artifact` and `deploy-pages`.
  Every wasm job builds, tests and smoke-tests the page for `HALOGEN_BASE_PATH=/blog/`
  and uploads it as `app` (3 days) from both runner kinds while public;
  `ci-already-tested.sh` prints `run_id` and, with `REQUIRE_ARTIFACT=app`, counts a run
  only if it still has an unexpired `app` (`test-ci-already-tested.sh`, 8 cases, in the
  native job). The concurrency group names the head repository and gives a dispatch its
  own group (its run id), so a fast-forward and a run by hand no longer cancel each other.
  The demo's database is `wiki-demo` (a browser's old local `wiki` database is left, not
  opened; an export carries it over). `web/bundle.sh` writes `licenses.txt` from esbuild's
  metafiles (`web/src/licenses.mjs`): the 68 packages that contributed bytes to a bundle,
  with their licence texts from their own directories, and a bundled package without a
  licence file fails the build; chosen over `--legal-comments=external`, which only
  collects comments the sources carry. The smoke test takes `HALOGEN_BASE_PATH`, serves
  the build under that prefix only, checks `<base href>` and installability with
  Chromium's own view (`Page.getAppManifest`, `getInstallabilityErrors` empty, the
  worker's scope the base path); `smoke-test-server.mjs` prerenders its own page for `/`;
  the hydration test adopts the pages under `/blog/` too. CI also runs `node --check
  toolchain/screenshots.mjs`. Gate green at `/` and under `/blog/` (44 pages adopted with
  nothing repaired), 230 browser tests, `actionlint` clean, 38/10/10 deploy cases. Not
  run here: the deploy itself; the push of this merge is the first, and `configure-pages`
  fails if Pages' source is not "GitHub Actions" (the owner's setting).
- **The demo is live on GitHub Pages** (2026-10-26, 22:28Z): the push of #84's merge
  found the pull request's run and its `app` artifact (`tested` skipped the builds),
  `configure-pages` answered (the owner had set the source to GitHub Actions), the base
  path check passed, and the deploy took under a minute; `https://swordlash.github.io/blog/`
  answers 200 with `<base href="/blog/">`, the manifest, `licenses.txt` and `app.wasm`
  (10.9 MB). WP5.4 started on `wp5.4-pick-runner` from `main` `8e0b380`; Dependabot's #80
  asked to rebase, to be fast-forwarded after its hosted run.
- **Dependabot's #80 merged** (2026-10-26, `main` at `b6a1744`, fflate 0.8.3): its rebased
  run went green on the hosted runners, the `[bot]` rule routing it there as meant; its
  wasm job spent 19 minutes in `--with-deps`'s apt (below). Fast-forwarded at the owner's
  word; the push redeployed the demo from the hosted run's artifact.
- **Two small fixes by the planning session** (2026-10-26): #86 (`main` at `c04ade5`): a
  slide's page body read the page's variables (code's background, the highlighter's and
  inline colours, surfaces, borders), which the system's dark scheme switches to
  light-on-dark values, so on the default and light themes code was dark text on a dark
  box (the owner's screenshot of the demo's "Themes" slide); each slide theme now
  re-declares the page's set for its own background, scoped to `.slide` and
  `.slides-theme-dark .slide`; checked in Chromium under both schemes. #85 (`main` at
  `e408f14`): on hosted runners Playwright's Chromium is cached by the lockfile and
  installed without `--with-deps`, whose apt-get fetched fonts and upgrades the tests do
  not use from a mirror at 34 kB/s (the same finding as haskell-halogen's #89; the runner
  image has every library the shell needs).
- **WP5.4 merged** (2026-10-27, PR #87, `main` at `d9549ce`). The `tested` job is `plan`, on
  `ubuntu-latest` for every run (`contents: read, actions: read`), with outputs `tested`,
  `run_id` (a push only, `ci-already-tested.sh` unchanged) and `runner`, from
  `toolchain/ci-pick-runner.sh`: `ubuntu-latest` without an API call when the dispatch
  input is `hosted` or `TRUSTED` (WP5.1's expression, evaluated once in the workflow) is
  not `true`; else `self-hosted` unless another run of `build.yml` is queued or in
  progress with a job whose labels name `self-hosted` and whose status is queued or in
  progress (`waiting` and completed jobs do not count; a queued run that lists no jobs yet
  counts as busy, the safe side); any API error, unreadable response or missing tool
  answers `ubuntu-latest`; the newest 30 queued and 30 in-progress runs, 100 jobs each,
  no further paging; a small JSON reader in awk (nested ids, steps' statuses and field
  order made grep unsafe), passing with mawk and gawk. The build jobs take `runs-on:
  ${{ needs.plan.outputs.runner }}` and drop `!cancelled()` (a failed `plan` skips them
  rather than starting them with an empty `runs-on`); `deploy` takes it too.
  `test-ci-pick-runner.sh`: 17 cases against a fake `curl`, in the native job. The README's
  CI section states the rule, that `plan` runs on the hosted runners for everyone, the
  machine-off case, and that a fork's `toolchain/` must be read before approving its run.
  Its own pull request was the first real run: `plan` wrote "Runner: ubuntu-latest,
  because the owner's machine is busy: job 'tested' of run 40416602976 is queued there"
  and the build went hosted. Accepted limits: the token cannot see whether the machine
  is online; two overlapping `plan`s can both pick the machine (the second queues); one
  pick per run. Found on the way: the hosted wasm job rebuilt its dependency store on
  every branch because Actions caches are visible only from the branch that saved them
  and from the base branch, and the wasm store had been saved only on pull request
  branches (the dispatches on `main` were cancelled before the save by the shared
  concurrency group, now fixed; pushes to `main` skip the build); a dispatch with
  `runner: hosted` on `main` after this merge saves it where every branch reads it.
  To do, small: a weekly `schedule` that warms the hosted caches on `main`, since GitHub
  evicts a cache unused for 7 days; and the three fixes carried from WP5.2/5.3 (the
  request-log test, the smoke test's address check, `--legal-comments`-style notices
  are done). The three pull requests #86, #85, #87 were rebased as a chain
  (#86 → #85 → #87) and fast-forwarded in that order, one CI run each on the final tree.
- **The hosted caches are on `main`** (2026-10-27, 01:10Z): the dispatch with `runner:
  hosted` after WP5.4's merge went green end to end (`plan`, `format`, `native` with the
  store from cache, `wasm` building its store in 43 minutes and saving it on `main`,
  Chromium cached and installed in 6 s, tests, smoke test, artifact, deploy); from now a
  hosted wasm job on any branch restores that store. The pushes of #86, #85 and #87 each
  found their pull request's run and redeployed the demo in under a minute (the first of
  the three was cancelled by the next push while its `tested` waited for the machine; the
  later deploys carried its change).
- **The weekly hosted run and the two races, fixed** (2026-10-27, PR #88, `main` at
  `f01470e`, by the planning session at the owner's word): `schedule` runs the workflow
  on Mondays at 03:17 UTC on the hosted runners (`plan` treats a scheduled run as
  untrusted and asks for hosted; it has a concurrency group of its own; `deploy` does not
  run from it), so the hosted caches on `main` are read and saved again before GitHub's
  seven-day eviction. `Test.Server.Api`'s request-log test waits for the line the
  middleware writes after the response (passes 8 of 8 here, where it failed 2 of 3 full
  runs before); `smoke-test-server.mjs`'s address check after creating a space goes
  through its `eventually`. The three small to-dos of the previous entry are closed.
- **WP4.19 started** (2026-10-27) on `wp4.19-assistant` from `main` `1a5c489`, alone; the
  owner lifted the shelving of decision 21 with API keys for both providers.
- **WP4.19 reshaped and extended** (2026-10-27, PR #89 open on `wp4.19-assistant`, from
  `main` `1a5c489`). The owner reshaped it the same day into a chat whose model edits the page
  through `replace`/`insert` tools as tracked changes (above), then added in the PR: the next
  message tells the model which changes the author rejected or undid; model and effort pickers
  under the message (Anthropic `output_config.effort`, OpenAI `reasoning.effort`); the
  providers chosen from round floating bubbles with their logos at the text's top right (the
  OpenAI logo from simple-icons 15.22, the last release carrying it); the model lists fetched
  from the providers' `/v1/models` and grouped (recommended, all, other), the built-in list a
  fallback; a provider that cannot be reached dimmed with the reason; an OpenAI-compatible
  base URL (Azure OpenAI, GitHub Models, OpenRouter, a local server). The planning session
  drove the built demo against the real APIs with keys the owner lent (Haiku 5.5, gpt-5-mini):
  the tool loop, tracked changes, Stop, the prefix cache (11,484 tokens read on every
  Anthropic request after the first) all hold.
- **WP5.5 merged** (2026-10-27, PR #91, `main` at `968bf50`). The agent noted a flaky test
  outside its package: "counts a notification the live channel tells of, with no page shown"
  (`/Mentions, watching and notifications/over the backend over HTTP/`) failed twice in its
  environment with "no attempt finished within 2000 ms"; to be made robust.
- **WP5.6 opened** (2026-10-27, PR #90 on `wp5.6-password-by-mail`), rebased onto `968bf50`
  after WP5.5. Beyond the brief, the agent made the public reset skip provider-only accounts
  and refuse their old links, and gave disabled logins their own hint. The owner, reviewing,
  asked why the storage is hand-written SQL rather than `persistent`/`opaleye`/`rel8`: the
  two latter are PostgreSQL-only; the answer became WP5.7. WP5.8 came from the owner's look
  at the export.
- **WP5.6 merged** (2026-10-27, PR #90, `main` at `7ee7dbe`), after the rebase; the account
  panel's two lines about a password reworded for provider accounts in the same PR. WP3.7's
  note that an identity-only account sets its first password with `current = null` no longer
  holds. Next: #89, then WP5.7 and WP5.8 one at a time.
- **WP4.19 merged** (2026-10-27, PR #89, `main` at `14b9797`, 12 commits, rebased onto
  `2ebdd31`). The last round, bubbles, fetched model lists, an unreachable provider dimmed and
  the OpenAI-compatible base URL, was tested live at that head on both providers (the lists
  fetched and grouped, `gpt-5-mini` chosen from "All models"; the model acknowledged a
  rejected section from the "Rejected" line). A harness bug found on the way: the test
  markup serialiser's literal U+00A0 was turned into `p` by the wasm embedding, so every
  `p` in prerendered test markup became `&nbsp;`; written as an escape now, and jsbits stay
  ASCII. Not tried live: a blocked network and a base URL other than OpenAI's (scripted
  tests cover both). The owner's keys stay in the session's scratchpad for later packages,
  never in the repository. Next: WP5.7 alone, then WP5.8.
- **WP5.7 closed without merging** (2026-10-27, PR #92, the owner: "zostajemy przy
  sqlite-simple na razie"; decision 7 stands). The spike ported users, groups, grants,
  identities, sessions and the second factor (36 statements) to persistent entities and
  esqueleto over one connection shared with sqlite-simple, with PostgreSQL migrations as twin
  files, a throwaway local PostgreSQL for tests (`toolchain/with-postgres.sh`) and a service
  container in CI; the gate was green. Against it: about twice the code for the ported part
  (208 → 436 code lines, plus 313 lines of PostgreSQL migrations), persistent-sqlite internals
  outside the PVP to share the connection, `veryUnsafeCoerceSqlExprValue` for a grant's
  subject (a user's or a group's id), `INSERT OR IGNORE` as two statements, `COLLATE NOCASE` as
  `lower_` (which folds every letter on PostgreSQL), and the static link leaving the whole
  server on persistent-sqlite's SQLite 3.43.1 rather than direct-sqlite's 3.45.0. If
  PostgreSQL ever becomes a goal, the port is done in one go (and `rel8` is then the better
  fit); the branch `wp5.7-persistent-spike` stays on origin as the reference. On the way the
  agent found `toolchain/test-bootstrap.sh` failing on `main` since WP4.19 (its fixture lacked
  the SDKs); fixed on `main` by the planning session.
- **WP5.9 started** (2026-10-27, the owner: `Http.Preload` compiles far too slowly because of
  aeson's Generic instances; use `deriveJSON` everywhere and drop `Generic`) on
  `wp5.9-aeson-th` from `main` `7eea2c5`: every Generic-derived JSON instance (78 empty
  instances, ~116 `genericToJSON`/`genericParseJSON`/`deriving anyclass`) to `Data.Aeson.TH`
  with the same `Options`, the 92 golden files unchanged as the proof, `Generic` kept only
  where another class needs it, compile times of `Preload`, `wiki-api` and `wiki-core` before
  and after in the report.
- **WP5.9 merged as something else** (2026-10-27, PR #94, `main` at `4f59c3e`). The
  measurements overturned the premise: `Preload.hs` had only two Generic instances, and its
  cost was the Simplifier and CodeGen on 21 mirror records (`SpaceAt`, `PageAt`, `…Of`),
  their derived `Eq`/`Show`, and the two conversions `toPreload`/`fromPreload`, at -O1. The
  owner then decided: one type, no per-module `-O0`. `Preload` and its mirrors are gone;
  `preloadJSON`/`parsePreload` write and read `Cache` directly, 390 hydration payloads
  byte-identical. `Preload.hs` alone: native 17 s/4.9 GB → 10.5 s/1.5 GB, wasm 15.9 s/5.6 GB
  → 6.6 s/1.5 GB (`-fno-specialise` would give 8.5 s/0.7 GB and 5.2 s/0.7 GB; not added, the
  owner dislikes per-module flags). The Generic → Template Haskell swap of `wiki-api` and
  `wiki-core` was built and measured but not merged: GHC's work drops 8–19 % everywhere, but
  on wasm every package that runs a splice pays 20–25 s for the external interpreter
  (`wiki-api` 26 → 45 s, `wiki-core` 38 → 51 s), and wasm is the owner's priority; it is
  kept on `wp5.9-aeson-th-reference` (with `Wiki.Core.Json.deriveValueJSON`, which encodes
  through `Value` so keys stay sorted as Generic's did). The PR body carries a ranking of
  the wasm build by module (clean, `-j1`: 485 s, 90 s of it outside GHC's passes):
  `Wiki.App.Shell` 114 s and 21 GB on its own (its 28-label `Slots` row type), the `hh`
  views next (`Editor` 15 s, `SignIn` 11 s, `Server` and `Admin` 10.5 s), and CodeGen run
  twice per module because the wasm project builds `shared: True` for TH (33 s of `.dyn_o`).
  Next on compile time, when the owner says so: WP5.13, `Shell`'s slots and the `.dyn_o`
  question, measured the same way.
- **WP5.12 merged** (2026-10-28, PR #93, `main` at `264cf19`). Every source module of
  `wiki-core`, `wiki-api`, `wiki-app` (`src`, `app`, `contract`) and `wiki-server` (`src`,
  `app`) has its comments and haddocks rewritten to the rule of 2026-10-27; 175 files,
  no code line changed (checked with a diff filter on the merge). The first five modules
  went out alone, the owner answered twelve of their sentences with questions, and the
  rewrite folded the answers in before going on. Comments found wrong against the code
  were corrected to what the code does (`BlobId`/`Attachment` and blobs, `Export`,
  `Search`, `Mail`'s list, `App`, a mangled "chooseProvider"). Two comments are left as
  found because the code or the comment needs a decision: `Cache`'s module comment says
  choosing a watch changes nothing else, but `setWatching` empties every cached watch
  first; `Backend.attempt`'s list of reads that throw has three entries where the module
  comment has four. The test suites' comments are not rewritten. Reduced gate (comments
  only): native build with no warnings, fourmolu; CI green on the head.
- **WP5.10 merged** (2026-10-28, PR #95, `main` at `8d3bb0a`). TikZ pictures draw the Polish
  and German letters: `web/src/tikz-patch.mjs`, run by `web/bundle.sh` on the copied
  `tikzjax/run-tex.js`, makes three checked string replacements in dvi2html (the metrics
  loop now reads code 127, the umlaut; the glyph table gets code 32, the stroke of `ł`/`Ł`,
  for the 46 fonts laid out as BaKoMa's OT1 text fonts; dvi2html's errors get a `dvi2html: `
  prefix), each of which must match exactly once or the build stops, with
  `tikzjax/NOTICE.txt` listing them. `\k` (the ogonek) is defined for OT1 in the island
  (`web/src/tikz-letters.mjs`, a TikZ-drawn hook sized in em), not in
  `Wiki.Core.Markdown.Tikz`'s preamble, because the PDF export passes that preamble to
  xelatex, whose fonts have a real ogonek; so acceptance item 3's preamble tests do not
  apply. A character the fonts lack (TS1 signs: `€ ° £ § © µ ± × · ½`) gives "The fonts TeX
  has here cannot draw '€' (line 2)." with a pointer to the guide; guillemets and `„` give
  TeX's own error. A missing-font rejection in the worker is marked handled so it no longer
  reaches the page's console. Tests: `toolchain/test-tikz-letters.mjs` and a smoke-test
  check drawing 109 letters beyond ASCII in a node and a pgfplots label through the real
  TikZJax. Full gate on the head; CI green. Found on the way: `test-native` needs
  `LANG=C.UTF-8` (two `wiki-core-html-test` tests read `docs/markdown.md` as text; the same
  on `main`), a toolchain fix for later.
- **WP5.16a merged** (2026-10-28, PR #96, `main` at `ee4c7eb`). Findings 1, 3, 6 and 4 of
  the audit, one commit each. A pool of four read-only connections (`PRAGMA query_only`)
  beside the writer carries `Reads` transactions, `resolveSession`, `mayReadPage`,
  `editorOf` and the export; the backup's `VACUUM INTO` has a connection of its own;
  `threadsThen` stays on the writer (`ReadsOnWriter`) for decision 23's guarantee. The
  write path loads only the users a save or comment could tell (a `UNION` of indexed
  queries; a single `OR` query scanned `users` and the new test caught it), watches only
  for the page and its chain of spaces, the page's maker through the first version;
  migration 0013 indexes `notifications (seq)`, `watches (page_id)`, `watches (space_id)`
  and `group_members (user_id)` (the last from finding 8f, needed here). The bell reads
  `ORDER BY seq DESC LIMIT 50` (a further 50 when some are about pages the user can no
  longer read), one `pageNodes` per distinct space, and `unread` is a count grouped by
  space and filtered to viewable spaces (the brief's plain count would have counted
  unviewable pages). The hub makes one permission check per user per event (a shared
  `Check` in a `TVar`, the first connection asks, the rest wait); the client's reconnect
  backoff is jittered ±30 % (`jittered` in `Live.hs`, longest wait 39 s). Tests:
  `Test.Storage.Scale` (reads beside a held read, a held write and a backup; a save with
  300 users and 3,000 watches scanning no table but spaces and grants, with the same
  statement count as with one of each; the bell with 500 notifications in a 2,000-page
  space loading the pages once; 100 sockets of 3 users making 3 checks) and
  `Test.Live` for the jitter. Measured with the new `wiki-server-bench` (1,000 users,
  10,000 watches, 2,000 pages, 200,000 notifications): the bell 21 s → 52 ms; a save 50
  users watch 600 ms → 56 ms; a comment with 100 tabs 530 ms → 10 ms committed, 20 ms
  all told; the slowest read during a backup 430 ms → 92 ms. Unchanged, for 8b and 8c:
  a page view's reads at about 60 ms (`watching`/`loadMarks`, `getPageTx`/`locatedTx`
  loading the whole space; `lineageOf` can replace the latter), `mentionable`, and
  `attachments` without an index on `page_id`. Seen once on `main`'s code in the bench, not
  reproduced: an uncaught "cannot rollback - no transaction is active". Full gate; CI green.
- **WP5.11 merged** (2026-10-28, PR #97, `main` at `4d1727d`). The chat shows the model is
  working: "Thinking" with three animated dots from Send until the first text, the seconds
  waited after 3 s of silence, the thinking summary streamed into a collapsed `<details>`
  that stays at the top of the message as "Thought", "Editing the page…" while a tool call
  arrives (the edit's note replaces it), a blinking cursor on streaming text, a time on
  each message and a duration on each answer; still under `prefers-reduced-motion`. The
  requests ask for the summary (Anthropic `thinking: {type: adaptive, display:
  summarized}`, OpenAI `reasoning.summary: auto`); a 400 for that part makes the island
  resend without it and leave it out for the rest of the chat (verified live on Opus 4.5
  and Haiku 4.5, which refuse adaptive thinking). Two island events, `thinking` and
  `tool-start` (`HeardThinking`, `HeardToolStart`); the scripted provider can pace tests
  with `{wait}`, `{thinking}` and a `pause` on a tool step. "Close" replaces the × and Esc
  in the message box closes too. Default effort `medium` on both providers, an "Effort"
  select per provider on the settings page (`ProviderSettings.effort :: Maybe Text`, read
  through `effortOf`; the old `effort` field is not read, so stored settings read as
  medium); the picker under the chat changes the conversation only. Seen live: the 5.5
  models send the summary as one block just before the text (Haiku 5.5 about 6 s
  before), so most of a wait shows "Thinking…" alone; OpenAI's gpt-6.1-sol and gpt-6-luna
  accept `summary` and send empty ones. Found, not fixed (outside the package): Haiku 4.5
  gets a 400 on every request, "This model does not support the effort parameter", because
  `output_config.effort` has been sent since WP4.19; a later package drops it on that 400
  as the island drops `thinking`. Seven new browser cases, island and native tests; full
  gate; CI green.
- **WP5.14 merged** (2026-10-28, PR #98, `main` at `23566b2`). Design A: page content is
  cached only until the first route change. The shell calls the new `MonadLoad.endPreload`
  in `arrive` and in `reload` when the route changes; the HTTP backend then drops page
  content (`Cache.forgetPageContent`: `pageAt`, `pages`, `postDetails`, `versionLists`,
  `searches`, `pageCounts`) and fetches it on every read without storing it; session,
  spaces, drafts, versions, threads, notifications, watches, mentions and the
  administration's data stay cached; the server's prerender always caches; this client's
  own writes still empty the whole cache. `listPages` answers `[PageSummary]`
  (`Wiki.Core.Page`, `summaryOf`; the server reads summaries in one query,
  `Rows.loadPageSummaries`); the blog view and the new-page form read their page by
  themselves; the page view tells the shell which page it shows (`ViewOutput.Showing`) for
  the head's preview; export and feeds read whole pages through `Storage.spacePages`; the
  prerendered page carries the page shown under `pagesAt`; `excerpt` moved into
  `PostDetails`. Not done, optional: caching `template.html` on the server. Tests: the HTTP
  backend's cache before and after `endPreload`, the prerender caching whatever the route,
  the preload carrying the page shown, and a browser case that reproduces the owner's bug
  (tab A shows a page, the server's answer changes with no live event, A returns and shows
  the new text; the page fetched twice, the list once). Full gate; CI green. The brief for
  this package still described the subscription window; the agent followed the plan.
- **WP5.13 merged** (2026-10-28, PR #99, `main` at `3b499cb`). `Wiki.App.Shell`'s cost was
  row-types' `.+`/`.==` type families, not the number of labels: `Slots` is a synonym, so
  GHC reduced the families again at every `HasType` site (each `HH.slot`, `H.tell`,
  `H.queryAll`) and kept each proof as a coercion (29 M coercions after the desugarer, 15.8 M
  in Tidy Core, against 184 k and 172 k now; terms about 10.7 k either way). The row is now
  written as a sorted `R '[ … ]` list (`Data.Row.Internal`, since `Data.Row` hides `R`)
  with six labels: the 14 views with `ViewOutput` share `"view"` (index `ViewSlot`), the 9
  `Void` children share `"part"` (`PartSlot`), `editor`, `signIn`, `invite` and `reset`
  keep their own. No behaviour change; no test added (types only; the browser suites and
  the hydration and smoke tests run every child). Measured with GHC called directly (`-j1`,
  `-ddump-timings`, `+RTS -s`): wasm GHC passes 86.8 s → 11.0 s, 20.7 GB → 5.4 GB
  allocated, residency 1.5 GB → 385 MB, wall 117 s → 37 s (23 s of which is Template
  Haskell's external interpreter starting node and loading the `.so` files, on every
  single-module wasm rebuild); native 96.4 s → 11.4 s, wall 104 s → 16.5 s. The 27 labels
  written flat alone give 12.0 s; six labels still built with `.+` give 14.0 s. Not
  applied, measured: `shared: False` for the whole wasm project rebuilds every store
  package and breaks splices that run another package's code; per-package `shared:
  False` on `wiki-core`/`wiki-api` has no effect (dependencies of a shared package are
  built shared); on `wiki-app` alone it saves 18.9 s of GHC time at `-j1` but needs seven
  dependencies pinned `shared: True` and a project file for `dev-test.sh`, judged not
  worth it; the second CodeGen costs 35.4 s in all at `-j1`. `SignIn`: the type check of
  the generated template code is about 7 s, the `hh` quoter 0.2 s; a micro-benchmark
  points at haskell-halogen-core's `DOM.HTML.Indexed` element rows (about 60 labels
  chained with `.+`): an element with no attributes costs 88 ms against 4.5 ms with a flat
  row, and `hh` emits a bare `[]` for such elements. An upstream change (flat rows in
  `DOM.HTML.Indexed`) is the next saving on the views. Rule for later: a row named by a
  synonym and used at many sites is written flat. Full gate; CI green on the rebased head
  (the wasm job 14 min against 16 before).
- **WP5.8 merged** (2026-10-28, PR #100, `main` at `040cb8f`). The export is a tree, format
  version 2 of `docs/export.md`: the manifest, `users.json`, `groups.json`, `grants.json` and
  `audit.json` as before, then `spaces/<slug>/space.json` (no `parent`), `icon.<ext>`,
  `pages/<slug>/page.json` (no `space`, `parent` or `body`; the attachments' records
  inside), `page.md` (the body byte for byte), `attachments/<name>`, `comments.json`
  (threads with their comments nested, as `Wiki.Core.Comment` is shaped, not the brief's
  flat list), subpages under `pages/` and subspaces under `spaces/` to any depth. Import
  reads versions 1 and 2 through `migrations`, which now works on the archive's files (1
  → 2 reads the flat files and writes the same wiki as version 2, so one reader handles
  every version); golden archives `wiki-export-v1.zip` and `-v2.zip`. Comments are new to
  the archive: `Archive.threads` and `commentAuthors` (people who wrote comments but are
  not users, in practice the server's `~administrator`); on import an author is matched by
  login, else kept by name under the id `~former:<name>` and shown as "Carol (not a user
  here)", not editable, deletable by a space administrator (`formerAuthor`,
  `formerAuthorName`, `absentAuthor` in `Wiki.Core.Comment`; no SQL migration, the name is
  in the `author` column). Directory names are the slugs (Windows device names get a
  trailing `_`); attachment names are percent-escaped where a file system refuses them,
  with a property test that two names never give one file name, and non-ASCII names
  checked through a real zip; the record's slug wins over the directory. The server's
  export reads all threads in two queries inside its read-only transaction; the empty-
  storage import restores threads with ids and times; the merge import brings threads only
  to pages it creates or replaces, skipping ids the page has, renumbering ids used
  elsewhere, and counts comments in the audit entry (the import dialog's `ImportSummary`
  in `wiki-api` is unchanged). Fixed on the way, present in version 1 too: a server wiki
  with two identical attachments (one blob) exported an archive that could not be imported;
  a shared blob is now refused only when its files differ. Not covered: fflate writing a
  non-ASCII name read back by zip-archive, names differing only in case on a case-
  insensitive file system, very long names. Full gate; CI green.
- **The round of 2026-10-28** (the owner: "Zrób wszystko oprócz polskiego"): WP5.16b, WP5.17,
  WP5.16c, WP5.18, WP5.15 and the haskell-halogen flat rows, two at a time (the container
  has 15 GB; six at once killed it on 2026-10-27): WP5.16b with WP5.17, then WP5.16c with
  WP5.18, then WP5.15 alone in this repository beside the haskell-halogen package, then the
  pin bump. The Polish interface stays out.
- **WP5.17 merged** (2026-10-28, PR #101, `main` at `5a19c82`). Five commits. The Anthropic
  adapter has a list of parts a model may refuse (`thinking`, `output_config`), each with
  its 400 pattern; a refused part is dropped once and left out for the rest of the chat
  (Haiku 4.5 live: refuses adaptive thinking first, then the effort, then answers). The
  native tests run under any locale: `npm-command.sh` exports `LANG=C.UTF-8` when the
  locale is unset or `C`/`POSIX` (and `LC_ALL` likewise when it is `C`/`POSIX`), and the
  tests that read files as text (`Test.Markdown.Document`, three reads in
  `Test.Server.Backups`) decode UTF-8 themselves. The cached draft is `CachedDraft`
  (`NoDraft | HasDraft Draft | DraftRefused WikiError`; no entry means not known;
  `forgetDraft`), with `draftAnswer`/`cachedDraft` where the API's `Either WikiError
  (Maybe Draft)` is still the shape; the preload's JSON unchanged. The two comments say
  what the code does (choosing a watch or changing the notification settings removes the
  cached watches; five reads throw `Unreachable`, `mentionable` being the fifth). The
  rule from the owner's review of #93: `requireView` fails with `NotFound` on both
  backends, so a space the principal may not view, and everything under it, answers as a
  missing space; `Forbidden` now only means "may view, may not do this"; `createSpaceTx`
  and `moveSpaceTx` check view on the parent or destination first; the administration
  keeps `Forbidden` first. A search scoped to such a space answers `[]`, as for a missing
  space (the method never refuses, by its type). Tests: a contract block `hiddenSpaces`,
  an HTTP test (404 not 403; 403 for a save by a viewer), every test expecting
  `Forbidden` for an unviewable space now expecting `NotFound`, the smoke test; `docs/api.md`
  states the rule. Visible changes: in a closed wiki someone not signed in gets `NotFound`
  for the public spaces too; a private space shows "There is nothing here" under "Not
  found". Left as found: `View/NewSpace.hs` decides `Forbidden` in the client for a parent
  the user may not view. Full gate; CI green.
- **WP5.16b merged** (2026-10-28, PR #103, `main` at `3237886`). Findings 5, 7, 8, 9 and 11,
  one commit each. Search: migration 0014 adds `pages.search_fold` (title and search text
  folded with `foldText`), the index `pages (space_id, template)` and a partial index
  `pages_unfolded`; the fold is backfilled at startup 500 rows at a time (SQL cannot
  fold); `searchPagesTx` matches in SQL (`instr(search_fold, ?) > 0` per word, the spaces
  searched, `template = 0` unless asked) and folds only the matches; paths through
  `withAncestors`. Sitemap and feeds: `sitemapPages` reads nodes of every viewable space in
  one query; a feed picks its 20 posts among summaries and reads only those (`feedPosts`,
  first author by join); `FeedCache` keeps each answer 60 s (keyed by route and public
  address, 404s not kept, at most 1,000), `public, max-age=60`. Page views: `mentionable`
  with `WHERE login IN`; `watching` through `loadMarksOn` (the page and its chain);
  paths through `resolvePathM` over `childPage`; create, move and shift read siblings
  only; the subtree is a recursive CTE (`subtreeIds`); delete and `locatedTx` take the
  path from `lineageOf`; `attachmentFile` reads the attachment with its space in one
  query and only that chain's grants (`readWithin`); attachments and space icons answer
  `private, max-age=300`; `loadTelling` and `loadAllMarks` are gone. History:
  `postDetails` through the first-version join, bodies only of pages that can be posts;
  `listVersions` takes `VersionsQuery {before, limit}` (default 50, at most 500; query
  parameters on the versions route); `VersionInfo.number`; migration 0015 indexes
  `page_versions (page_id, rtrim(updated_at, 'Z'))`; the History view lists 50 with
  "Older…", and a deep version opened by address fetches pages until it is loaded. Audit
  log: `ActivityQuery.before` (an entry id, keyset `(at, id) <`), `offset` still answered;
  the actor list is a recursive skip scan over `audit_log_actor` (the brief's `GROUP BY`
  still reads every row); "Newer" keeps a stack of cursors. Bench medians, `d08cf3c` →
  this: search of a word on 1 page of 20,000 716 → 58 ms (on every page 737 → 687 ms:
  ranking folds every match, FTS5 is the next step; in one 2,000-page space 660 → 12 ms);
  sitemap written 231 → 131 ms, repeated within a minute 0.12 ms; feed of a 2,000-page
  blog 7,016 → 264 ms; page view (getPage, watching, mentionable for 3) 124 → 2.2 ms;
  blog listing of 2,000 posts × 20 versions 1,095 → 222 ms (excerpt parsing now); Activity
  page 100 of 100,000 69 → 2.3 ms. Next free migration: 0016. Noted: `search_fold` as a
  column of `pages` still reads past each body; a separate table would read a quarter of
  the bytes. Full gate; CI green.
- **WP5.18 merged** (2026-10-28, PR #102, `main` at `e4d9589`). A wiki setting
  `adminCreatesPasswordAccounts`, on by default (row `admin-creates-password-accounts` of
  the `settings` table, no migration; a wiki without the row has it on), a checkbox with
  one sentence of help under "Who may come in", and carried by `Directory` so the Users
  view makes one read. Off: the "New user" form is replaced by a note naming
  `wiki-server users add`; `POST admin/users` is refused with 403 before the login,
  password or address is looked at, and the storage refuses it too
  (`requireAccountCreator`). The refusal is a plain 403: `Forbidden` carries no text in
  `wiki-api`, `wiki-app` or `wiki-server`, and the reason is the setting itself, which
  `GET admin/settings` and the directory show; the brief's "with a message" is dropped.
  Unaffected: the console (`createAccount` never reads the setting), invitations,
  accounts people make themselves, sign-in providers, `setPassword`, "Send a password
  link…". The audit entry `settings.wiki` gains the detail. Tests: contract (refused when
  off, blank login included; shown in settings and directory; back on works), HTTP on both
  listeners with a restart in between and the console run beside the live server, the
  password link still mailed when off, the audit detail, a browser test of the form and
  the note. `docs/api.md`, the README, three changelogs. Note for later: `PUT
  admin/settings` bodies must carry the field (`FromJSON` is derived). Merged after a
  rebase onto a plan-only commit without a second CI run, by the owner's word ("nie
  każdy PR musi być ff"): the tree differs from the green head only in `docs/PLAN.md`.
- **WP5.16c merged** (2026-10-28, PR #104, merged by the owner on GitHub with a merge
  commit, `main` at `fe10e39`). Findings 10, 12 and 13, one commit each. Export:
  `Wiki.Core.Export.archiveFiles` names each attachment and icon by its blob (`FileBlob`)
  instead of its bytes; `Export.Zip.writeZipFile` (about 100 lines over `zlib` and `digest`,
  because zip-archive builds the archive in memory) writes the zip one file at a time, from
  memory or from files on disk read in chunks, byte for byte what `zipFiles` makes (a test
  says so); the server writes it to `<data>/tmp/` and answers with `responseFile`, the
  endpoint is `RawM` and pauses Warp's timeout; written in full before the answer so a
  missing blob is still a 500. Uploads arrive as `Tmp` multipart files (the forms are
  parameterised by the backend) and `storeBlobFile` copies them into the blob store in 64
  KiB chunks, hashing on the way; `<data>/tmp/` is emptied when the storage opens. The
  import reads the archive from its temporary file but still unzips in memory
  (`--max-import-size` 512 MiB). Metrics: `wiki_blobs` and `wiki_blob_bytes` from one
  query over `attachments` grouped by blob plus unshared icons; the directory walk is
  gone, so the samples mean "the blobs the wiki names". Demo: `openMemWiki` reads only the
  keys of `attachments` and `versions` (`unreadBlobs`, `unreadVersions`); an attachment's
  bytes are read when its object URL is first made or at export and are not kept in the
  heap; a page's versions when its history is shown, its first version when its creator
  is needed; a write saves only the stores `touched` reports (field-by-field `StableName`
  comparison; pointer equality gave false positives), so a draft save writes the drafts
  store only. Measured: export of 1,000 pages + 500 MiB of attachments, server peak
  resident 1,391 MB and cut off by Warp's 30 s timeout in 2 of 3 runs → 121 MB in 19.6 s;
  a 50 MB upload 186 → 103 MB; `/metrics` with 10,000 blobs 0.39 s → 0.020 s; the demo's
  load with 200 attachments of 256 KiB reads 50 MiB in 330 ms → no bytes in 2.3 ms
  (IndexedDB calls timed in Chromium, not the demo itself). New: `wiki-server-memory-test`
  (`+RTS -T`, live heap under 30 MiB for an export of 100 MiB plus a 50 MB upload; the old
  export reached 97 MiB), a metrics test with the blob directory deleted,
  `Test.Counting` (IndexedDB calls recorded) for the demo's laziness, `wiki-server-bench
  attachments|blobs` seeders. Not done: ZIP64 (4 GiB or 65,535 files refused with a
  message, as before); the export still holds every page body in memory. Removed:
  `Wiki.Api.Zip` and `Disposition`. Full gate; CI green.
- **Flat element rows merged upstream** (2026-10-28, haskell-halogen PR #93, `master` at
  `1f934f2`, merged by the planning session after Codex's review at the owner's word).
  Every element row of `DOM.HTML.Indexed` (108) and `Halogen.Svg.Indexed` (22) is defined
  inside one declaration splice per module, `$(flatRows [d| type HTMLdiv = Interactive
  ("onScroll" .== Event) … |])`, with the old definitions verbatim inside;
  `Halogen.Row.TH.flatRows` reifies each group once, collects the labels, refuses a
  duplicate, sorts in `CmpSymbol` order and defines each synonym as `R '[ … ]`; `flatRow`
  does one row for users and accepts a row already flat (`HTMLdiv .+ "custom" .== Text`)
  and substitutes a synonym's parameters inside field types (both found by Codex, fixed).
  `Test.IndexedRows` proves each of the 130 rows and 26 groups equal to its old
  definition with `Refl`. Numbers: 200 `HH.div [] []` 15.5 s → 0.2 s natively; the wiki's
  `SignIn` 12.4 → 3.5 s (type check 8.2 → 0.4 s), `Editor` 18.0 → 9.4 s; `core` from
  nothing 86 → 31 s natively, 65 → 27 s on wasm (wall 91 → 49 s), 159 → 67 s on the
  JavaScript backend (peak 11.4 → 4.7 GB). On the way, a GHC finding: the JavaScript
  backend (9.12.2) keeps about 50 MB and 0.75 s of its own memory per Template Haskell
  splice in a module, linear in the number of splices, the JS linker running once per
  splice and keeping its dependency records (heap profile: `ExportedFun`, `BlockDeps`,
  `Module`/`RealUnit`); 108 per-row splices (the PR's first head, `5125414`) took CI's
  16 GB runner past its memory twice, which is why it is one splice per module. The
  reproduction (N trivial splices, N = 10/50/100, JS and native) and a writeup for a GHC
  issue are in the session's scratchpad (`ghc-js-th-splices.md`, `ghc-js-th-repro.tar.gz`),
  handed to the owner. Follow-up noted upstream: `th`'s `unknownHtml`/`unknownSvg` still
  use chain-built rows. Next here: WP5.19, the pin bump.
- **WP5.19 merged** (2026-10-28, PR #105, `main` at `295a26d`; pushed before the local gate
  at the owner's word, "pchnąłbym go nawet bez testów i zlecił testowanie CI"; CI green).
  `cabal.project` pins haskell-halogen `1f934f2` (17 commits past `f7ee7e3`; no toolchain
  pin moved). The bump needed `Typeable m` where a component's state holds `m` (six
  components, `Static.startApp`) and, because the browser suite mounts the shell over a
  polymorphic `m`, in `Test.Browser.Mount`'s helpers and 34 spec files; nothing else in
  the 17 commits needed a change. Measured, the wasm cabal step of `wiki-app` from an
  empty build directory, `-j1`, with WP5.15 building beside both runs: wall 445 → 319 s,
  GHC passes 320 → 218 s, `wiki-app` alone 217 → 115 s; per module (passes / type check)
  `SignIn` 10.7/5.7 → 3.7/0.2 s, `Editor` 16.9/7.6 → 9.7/0.6, `Page` 7.5/2.6 → 4.3/0.3,
  `Admin` 11.6/6.7 → 3.9/0.2, `View.Server` 13.9/7.3 → 4.9/0.3, `Shell` 13.0/5.5 →
  6.8/0.4; `wiki-core` and `wiki-api` unchanged. The views' type check is no longer the
  cost; the slowest `wiki-app` module is now `Backend.Mem.State` (11.7 s, simplifier and
  code generation), then `View.Editor` (9.7 s, simplifier 5.0 s). Noted for later: the
  upstream way to drop `Typeable m` is to build such components with the `Component`
  constructor and `ComponentInfo {stateType = Nothing}`, which would also free the 34 spec
  signatures; upstream, a hoisted component no longer renders again after a `get` that
  leaves the state as it was, and natively an event can be built from JSON
  (`Halogen.VDom.DOM.Monad.Native.event`), which makes native tests possible for views
  that only had browser tests.
- **WP5.20 merged** (2026-10-28, PR #107, `main` at `bfd3307`). `Block` gains `Pause` (a
  paragraph of `. . .` at the top level, in a box, an alert or a list item; in a quotation,
  a footnote or code the dots stay text; a page renders nothing for it). `Slide` gains
  `steps`: the body keeps all content, later pieces are wrapped in `stepMark`
  (`div.slide-step` with `data-step`), incremental list items get an `itemMark`; `atStep`
  and `showingStep` (which only adds `slide-step-later`, so islands are not redrawn).
  Steps follow Beamer's counter (the first item of an incremental list appears with the
  content before it, a pause after the list starts the step after its last item,
  `nonincremental` turns it off). Presenting: → Space PageDown step then slide, ← PageUp
  back a step or to the previous slide whole, Home (1,1), End the last slide whole, swipe
  and the Back/Next buttons step; `?slide=3&step=2`; later steps `visibility: hidden` with
  a 0.3 s fade (none under reduced motion); overview and print show whole slides, "each
  step on its own page" adds print-only copies at each earlier step. Exports: `Output` has
  `ToBeamer` and `ToPowerPoint`; Beamer keeps pauses (`\pause`, and
  `\pause[\value{beamerpauses}]` after an incremental list so Beamer adds no empty page)
  and `\begin{itemize}[<+->]`; PowerPoint steps incremental lists only (pandoc 3.12's
  writer has no pause handling, so pauses are dropped there, the plan said otherwise);
  DOCX, HTML, EPUB and plain PDF drop pauses; a quotation's content is wrapped
  `nonincremental` in both slide formats (a list alone in a quotation no longer exports
  as incremental). Tests: steps in `Wiki.Core.Slides`, five browser cases, the Beamer
  `.tex` and a page count of the Beamer PDF equal to the browser's steps (7; `zlib` in the
  test suite to inflate PDF streams; pending without xelatex and beamer), the PPTX
  animation, the DOCX without markers, the smoke test (the demo deck prints 9 pages, 13
  with steps, a reload returns to `?slide=7&step=2`). The demo deck gains slides 7
  "Steps" and 8 "One item at a time"; README and `docs/markdown.md` updated. Full gate;
  CI green.
- **WP5.15 merged** (2026-10-28, PR #106, `main` at `82f6825`, nine commits). `docs/newtypes.md`
  is the inventory: every `Text` field and argument of `wiki-api` and `wiki-core` grouped by
  what the text is, with today's rules, where they run, the decision, and what stays `Text`.
  The newtypes: `Login` (`parseLogin`, the old `checkLogin` rules), `Password` (`Show` prints
  `Password <hidden>`; `checkNewPassword :: Password -> Either Text Password`, since a
  password typed at sign-in is one too; the hand-written `Show` instances that hid passwords
  are gone), `Email` (`parseEmail`, moved from `Wiki.Api.Admin`), `Url` (new `Wiki.Core.Url`:
  the public address, an issuer, `Discovered`, `redirectUri`, the assistant's base URL,
  `SourceUrl`; no shared parser, the three rules stay where they were), `FileName`
  (`parseFileName`, the rule both backends had written separately), `MimeType`
  (`uploadedMimeType`, `mimeEssence`), the tokens each with a hiding `Show`
  (`ResetToken`, `VerificationToken`, `UnsubscribeToken` replacing `MailToken` in
  `wiki-api`; `InvitationToken` now `Maybe` in `Invited`; `SessionToken` in
  `Wiki.Server.Password`, `PendingToken` in `SecondFactor`; `ApiKey` in `Wiki.Core.Assistant`)
  and `ModelName`. The JSON instances check nothing, so a bad value in a request still gets
  the backend's own `Invalid` message: request fields the backend checks stay `Text` and the
  backend parses where it checked before; responses, stored records and internal
  functions use the newtypes. No `IsString`; no `ToField`/`FromField` (orphans). Wire
  formats, cookies, the archive and IndexedDB records unchanged; no golden file changed.
  Kept as today and noted: an archive restored into an empty server keeps logins without
  `parseLogin`; a provider's e-mail is stored as given. Stays `Text` by design: logins used
  only as lookups, `Oidc.Endpoints`, the renderer's `AttachmentRef`, `TotpEnrolment.uri`,
  the server-settings secrets. Tests: `Test.User`, `Test.Attachment` additions, the `Show`
  of the keys and tokens. Full gate on the first head; after the rebase over WP5.20 (only
  changelog conflicts) the native gate again, wasm and smoke by CI; CI green.

- **WP5.21 merged** (2026-10-29, PR #108, `main` at `97a8a1a`, four commits). Part A: one
  policy, written once as the meta element of `web/index.html` (and `offline.html`);
  `Wiki.Api.ContentPolicy` reads it at compile time and renders the server's header from
  it, adding `frame-ancestors 'none'`; `connect-src` is the two providers plus the hosts of
  `--assistant-hosts` or the server settings' `assistantHosts` ("The assistant's hosts" in
  the administration); `base-uri 'self'` because the pages carry `<base href>`; every page
  also sends `Referrer-Policy: same-origin` and a `Permissions-Policy`; a provider address
  the policy would block is reported by the assistant first (`ErrorKind Blocked`,
  `allowsConnect` normalising default ports). The browser suite runs under the policy
  (`test/web/policy.mjs` writes `0-policy.js`, a spec after the suite checks nothing was
  refused); a native test that raw HTML renders nothing the policy would block; the smoke
  tests check the meta and the header on every page; CI runs `npm audit --omit=dev
  --audit-level=high`. Part B: `Wiki.Core.Assistant.Vault` (AES-GCM under a vault key,
  wrapped per passkey under HKDF-SHA256 of the passkey's PRF output, the device record),
  routes under `api/v1/assistant` (`vault` GET with ETag/304, PUT with If-Match, DELETE;
  `passkeys`; the registration and assertion ceremonies), migration 0016 (`passkeys`,
  `assistant_vaults`), `Wiki.Server.WebAuthn` written here with crypton and cborg
  (attestation none, ES256 and RS256, rpIdHash, UP/UV, sign count; the expected origin from
  `Wiki.Server.Address.requestOrigin`, one origin honouring `X-Forwarded-Proto`),
  `Wiki.Server.Vault` storing only ciphertext, salt and wrapped keys with every field
  bounded, at most 20 passkeys, ceremonies 5 minutes in memory. In the application the
  device keeps a non-extractable `CryptoKey` in IndexedDB and an exportable key never
  outlives its step; the settings page: turn on, unlock, add and remove a passkey, "ask
  each time" (one touch per page load), turn off also while locked (the way back after
  losing every passkey); the demo offers no sync; plain HTTP without WebCrypto keeps the
  settings as text with a warning and says sync needs HTTPS; old settings are sealed on
  first load; tabs learn of a dropped key through a `BroadcastChannel`. Tests: pure, server
  (a played ES256 authenticator, RS256, HTTP flows, bounds, migration), 14 browser specs
  with a stub of `navigator.credentials` (one probes that no exportable key remains after
  a cancelled step), and `toolchain/test-passkeys.mjs` in the smoke test: a real
  `wiki-server` and Chromium's virtual authenticator with PRF. Review: nine findings from
  a Claude Code review and three from Codex, all confirmed and fixed in `97a8a1a` (stale
  settings after turn-off, the exportable key on failure paths, unbounded fields, the
  allow list at unlock, the origin check, the dead form-action plumbing on the sign-in
  pages, the panel after a failed turn-on, a stale key in a second tab, default ports,
  the retry after a conflict, turn-off while locked, plain HTTP). Decisions kept: the
  editor loads the vault only on a device that already syncs; the administration shows
  nothing about vaults. Not done: the browser's own passkey dialog was not seen by a
  person. For WP5.22: migration 0016 and the raw SQL of `Wiki.Server.Vault` move to the
  new storage layer; `Env.ceremonies` is per process. Full gate by the agent (`-j1`),
  CI green on the merged head. The owner's review comment on the hand-rolled request
  types became WP5.23.

- **WP5.23 merged** (2026-10-29, PR #109, `main` at `dc5fef6`, five commits). `WikiApi`,
  `SpacesApi`, `PagesApi` and `ArchiveApi` take the multipart backend as their first
  parameter: the server serves `ApiWith Tmp`, the client is derived from `ApiWith Mem`
  (servant-multipart-client reads a `Tmp` upload from a file path, which the browser has
  not); paths, methods, headers and bodies are the same. `Wiki.App.Backend.Http.Request`
  is gone; `Http.Transport` holds `HttpRequest` (servant's request with its body collected
  and its path relative to `<base href>`), `Transport`, the fetch and silent transports and
  the time limits (multipart gets `uploadTimeout`); `Http.Client` holds `prepare`,
  `withBoundary`, `endpointUrl` (a call's address worked out in servant's `Free` client
  without sending it, for the tests; panics on a call that sends no request), `answer`,
  `fromApiError` and the session conversions. `HttpWiki` has the `RunClient` instance,
  the one place every request goes through: `NotCached` under `cacheOnly`, the request
  marker, the transport, the 401/403 session re-check (guarded by `rechecks`, with a test
  that a refused session endpoint asks exactly once). The client is `clientIn` on
  `ApiWith Mem`; every method of `MonadWiki`, `MonadAdmin`, `MonadComments`,
  `MonadNotifications`, `MonadAccount`, `MonadSecurity` and `MonadVault` calls one
  endpoint through `call`. `Render.inProcess` takes servant's request and returns
  servant's response; the handlers' type is `WikiApi Tmp AsServer`. Only the declared
  status is accepted (a 201 answering a `Get` is `Unreachable`; before, any 2xx). The wire
  moved only in ways the server already read: `application/json;charset=utf-8` and an
  `Accept` header, `login=a&login=b` for a list, a colon in a path segment unencoded, a
  form ending with `--boundary--` and a text part with `Content-Type: text/plain`; the
  server's API tests passed unchanged, the contract over the derived client
  (`Test.Server.Http`, 203 examples) and the smoke test confirm it. App tests name the
  client's addresses with `endpointUrl`, not `links` (the native prerender test had been
  answering its mentions with a 404 unnoticed; fixed). Spike: servant-client-core 0.20.3.0
  and servant-multipart-client 0.13.0 build for wasm under `allow-newer: *:*`, bringing
  only `base-compat` and `safe`. Review: Codex found nothing; five findings of a Claude
  Code review fixed in `dc5fef6` (the re-check test, `endpointUrl` failing loudly, the
  tests and the `Links` header, two haddocks). Full gate by the agent, CI green on the
  merged head. For later packages: a new endpoint must declare the status the server
  answers (`PostCreated` against `Post`), a mismatch shows as `Unreachable`; a test
  transport's response must carry `Content-Type: application/json` (`jsonResponse` in
  `Test.Scripted`); new endpoints are called through `endpoints.<record>.<field>`.

- **WP5.22 merged** (2026-10-29, PR #110, `main` at `5150b0d`, sixteen commits; the agent
  was restarted once with the container, its uncommitted work survived on disk). One
  storage layer on Beam (`beam-core` 0.11.1, `beam-sqlite` 0.7, `beam-postgres` 0.6.4) in
  `Wiki.Server.Storage.*`: `Backend` (a class with `Db` and `Connection`: connections,
  transactions, the retry rule, search, size, backup), `Schema` (every table once), `Rows`
  (shared queries), `Sqlite` and `Postgres` (what differs), `Migrate` and `Backup` for both.
  `OverloadedRecordDot` resolves Beam's columns, no `FieldSelectors` needed. One `0001-initial`
  schema per backend (`.sqlite.sql`, `.postgres.sql`), WP5.21's tables in both, `Vault.hs`
  ported; no data migration; a database of the old shape makes `wiki-server backup` exit 3,
  which the deploy reads as "incompatible" and refuses without `--fresh` (which moves the
  old data to `data/replaced/<time>`). Pools: one writer and four readers on both;
  PostgreSQL writes SERIALIZABLE with three attempts, reads REPEATABLE READ READ ONLY.
  Search: a generated `tsvector` (title A, body D) with a GIN index, `websearch_to_tsquery
  ('simple')` and `ts_rank`, whole words, no stemming; SQLite keeps the folded search;
  `ServerInfo.capabilities` says `database` and `search`, the application does not read it
  yet. Options: `--sqlite FILE`, or `--database URL` plus `--database-password-file FILE`
  (a URL with a password is refused; the password never joins the URL text, it is a
  `Secret` and reaches libpq in the connection string and `pg_dump`/`pg_restore` through
  `PGPASSWORD`), `WIKI_DATABASE_URL`, `WIKI_DATABASE_PASSWORD_FILE`, `--pg-dump`/`--pg-restore`;
  with none, `DIR/wiki.sqlite` as before. `docker-compose.yml`: `postgres:17` with a named
  volume, a healthcheck and a `db-password` secret; the image carries `libpq5` and
  `postgresql-client-17`. `deploy-local.sh`: PostgreSQL by default (brings the container up
  with `up --wait` on 127.0.0.1 at `--db-port`, default 5433; reuses an existing one with a
  `pg_dump` into `data/backups` before the new server starts, which applies pending
  migrations), `--sqlite` as the alternative, a change of direction either way refused
  without `--fresh`, no Docker names `--sqlite`; `test-deploy-local.sh` 67 cases with a
  fake docker. `backup`/`restore` for both; every open storage holds a PostgreSQL advisory
  lock shared on a connection of its own and a restore takes it alone, so a restore refuses
  a live database from any data directory and a server refuses a database being restored;
  the replaced dump keeps its facts file so a restore can be undone. CI: `ci-postgres.sh`
  starts a container by a step (not `services:`, for a runner without Docker); the native
  tests and the smoke test run on both; locally the fixture starts a temporary cluster when
  `initdb`/`pg_ctl` are found, else the PostgreSQL half is pending. Bench (this container,
  medians): page view 2.5 ms SQLite against 11 ms PostgreSQL 16 over a socket; search of
  20,000 pages 57 ms against 4 ms (every page: 192 against 23 ms); save of a page 50 users
  watch 13 against 44 ms. The PostgreSQL gap is not reconnects (checked with
  `log_connections`: one writer and one reader carry the run) but ~0.2 ms of client wait per
  statement through GHC's IO manager over 29 statements (6 BEGIN/COMMIT, 15 permission
  context, 8 the view); PostgreSQL executes the view in 1.8 ms. Review: ten findings of a
  Claude Code review and two of Codex, two of them confirmed by running the code (the
  `--database` URL check refused every URL with a user, so no PostgreSQL deploy could start;
  the password from the file was printed in the start-up log through `?password=`); all
  fixed in the last commits with tests through the real option parser; the mail queue's
  `loadPending` was not a pure read (it also unqueued disabled users), now split into a
  read and a conditional write. Not run here (no Docker daemon): the image build, a real
  `docker compose up`, PostgreSQL 17 (local runs used 16); CI's first `ci-postgres.sh` run
  passed. For later: one read transaction per request would cut the page view's round
  trips from 29 to about 15 but needs a request-scoped storage context (the render calls
  the API in process, one transaction per call); prefix matching on PostgreSQL search
  (`:*` on the last word, our own escaping, a minimum prefix length) is the owner's
  decision; the lock-holder connection dies silently if PostgreSQL restarts under a
  running server, so until the server restarts a restore is not refused; `Env.ceremonies`
  stays per process; `LISTEN/NOTIFY` and `SKIP LOCKED` unused.

- **WP5.24 and WP5.27 merged** (2026-10-29, PR #111, `main` at `e1b436f`, twenty-six commits,
  four review rounds: Claude Code at high effort each time and Codex `gpt-6.1-sol` at high
  twice, the first two reviews of the two-review rule). **A.** Every transaction runs in
  `Wiki.Server.Storage.Backend.withTransaction` (and `withTransactionEither`, rolled back on
  a `Left`), mask-based: begin, the body under `restore`, the commit, a rollback on an
  exception in either, an asynchronous exception arriving during the rollback rethrown;
  the four wrappers, `Migrate.applyMigrations` and `Backup.dumpWithFacts` use it,
  `rollBackOnError` is gone, `retrying` unchanged. Tests on both backends: a body that
  throws, a statement that fails, a `Left`, a failing commit, each leaving no transaction
  open. **B.** The permission context is kept in memory for one generation. The generation
  is a row (`permissions_generation`, migration `0002-permissions-generation` on both
  backends) bumped by database triggers, not by code: on every change to `spaces` (every
  column, because the copy also answers the list of spaces and a space by path, with names,
  icons, descriptions and order), `global_grants`, `space_grants` and `group_members`, and on
  a user added or deleted or whose `id`, `login`, `display_name` or `disabled` changed (the
  other columns do not bump); whoever writes: the server, the console in another process, a
  foreign-key action, a statement by hand. SQLite fires per row, PostgreSQL once per
  statement and only when it changed a row (transition tables). A read transaction reads the
  generation with one statement and uses the process-wide copy when it matches, else loads
  the context (one scan per generation for the process; at most the four readers that see
  the new generation at once); a write always reads from the database, because it decides
  on its own snapshot and on PostgreSQL the rows it read join its serializable check. A
  missing generation row bypasses the cache. Two processes writing permissions at once
  conflict on the one row at SERIALIZABLE and one is retried (three attempts; rare writes).
  `readWithin` loads the context only when the attachment exists and keeps what it loads.
  List writes (`insertSpaces`, `insertMembers`) go 500 rows per statement like
  `insertUsers`; `updateSpaces`/`setSpacePositions` removed (Beam has no batched update).
  Page view: 29 statements → 17 on both backends; PostgreSQL 14.35 → 2.89 ms median in this
  container. **WP5.27, the libraries review**, one replacement per commit: `Wiki.Server.WebAuthn`
  (343 lines) → `webauthn` 0.12.0.0 (parsing and verification; the wiki keeps its options,
  sentences, the `crossOrigin` check; attestation is forced to "none" and only the
  `authData` is taken from the attestation object, so a statement in any format is never
  decoded; a new key's public key is stored in the package's canonical COSE encoding, a key
  stored before is made canonical on each read by `canonicalCoseKey` and never rewritten;
  registration stays strict as CTAP2 mandates canonical CBOR; `allow-newer` for webauthn's
  `base`, `time`, `crypton`, `crypton-x509*`). `Wiki.Server.Totp` (171 lines) →
  `one-time-password` 3.0.1.0 over `sel`/libsodium (`hotpSHA1`; a 20-byte secret padded with
  zeros to the package's 32, which HMAC does to any short key, so stored secrets, the
  otpauth URI, recovery codes and every code are unchanged; `Secret` builds its HMAC key
  once; `hotp` returns `Maybe` for a key over 32 bytes or under six digits; every program
  using it starts with `Sel.secureMain`; `allow-newer` for `chronos`/`bytebuild` bounds;
  building needs `libsodium-dev` and `pkg-config`, running `libsodium23`: the bootstrap,
  the image, both CI jobs and the README say so). `pwa.mjs` icons → `@resvg/resvg-wasm`;
  jsbits base64 → `Uint8Array.prototype.toBase64`/`fromBase64`; `databases.js` →
  `indexedDB.databases()` alone (these set decision 26's floor: Chrome/Edge 140, Firefox
  133, Safari 18.2). Kept, with the reason: the ID token reading in `Wiki.Server.Oidc` (6
  hand-written lines; `jose` checks claims only with a signature and would refuse the test
  provider's unsigned tokens, the token is read unsigned on purpose as it comes from the
  token endpoint over TLS, OIDC Core 3.1.3.7; `openid-connect` is bounded below our aeson;
  `oidc-client` covers neither GitHub's plain OAuth nor Apple's `form_post`);
  `Wiki.Server.Limiter` (the packages limit requests, the wiki counts failed sign-ins per
  login and per address, clears on success and reports the wait); `Wiki.Server.Address`
  (`wai-extra`'s `guessApproot`/`appearsSecure` ignore `X-Forwarded-Host` and trust other
  headers, which would change the passkeys' relying party); `sw.js` (Workbox would replace
  ~40 lines of fetch-then-cache, the rest is the wiki's offline behaviour, and its precache
  and expiration change the stored layout; the owner confirmed). Also in this PR: an ID
  token for another client is refused naming both client ids, and a Google client id
  without `.apps.googleusercontent.com` is refused on save (the owner's sign-in error of
  2026-10-29); `cabal.project` pins `network < 3.2.10` until `smtp-mail` 0.5.0.1 compiles
  with it. Gate: native and wasm builds without warnings, 1753 server examples, wasm
  100/886/282, the smoke test on SQLite and PostgreSQL (round two; nothing in the browser
  changed after). For later: a second server instance needs the generation shared
  (`LISTEN/NOTIFY`); `Env.ceremonies` stays per process.

- **WP5.25 merged** (2026-10-29, PR #112, `main` at `9b3b48c`, sixteen commits, two review
  rounds: Claude Code at high and Codex `gpt-6.1-sol` at high on each head, 10 + 7 findings,
  all but one fixed). **The administration as pages:** `Route.Admin` takes an `AdminSection`
  (`overview`, `users`, `groups`, `permissions`, `server`, `backups`, `activity`), one
  address each under `/admin/<section>/`, `/admin/` redirected to `overview` by the shell
  (`Router.redirect`); on these routes the shell's sidebar is the administration's
  navigation (a row of tabs on a narrow screen), breadcrumb and title name the section, each
  section mounts its view alone with its own loading and errors. Choices: no Invitations
  section (they stay inside Access, mounted as Permissions); export and import under
  "Backups and data"; no "Last sign-in" (nothing stores it; sessions go on sign-out, so the
  newest session is not it). **Users paged:** `GET api/v1/admin/users?offset=&limit=&q=
  &administrators&disabled` (limit 25 by default, 1–100; `Wiki.Api.Admin.pageOfDirectory`
  defines the answer every backend must give; the server reads one page in SQL, `Rows.
  loadUserPage`, ordered by `lower(login)` by code points with `COLLATE "C"` on PostgreSQL
  (`Backend.byCodePoints`), the administrators filter an `EXISTS` on `global_grants`, then
  the details of those users only; the HTTP backend starts from the prerendered page as the
  audit log does; `directory` stays for the groups). `View/Users.hs`: search over login and
  display name (every word, case-folded; Beam writes no `ESCAPE`, so `%`, `_`, `\` match a
  character; SQLite folds ASCII only), filter (everyone, administrators, disabled), page and
  query in the address (a page below 1 or past the last redirected into range; the shell's
  `canonicalAdmin` compares with `Router.current` so a view's redirect is not written back),
  25/50/100 a page in `localStorage` (the shown page's size from the answer, the kept size
  for the next request), "1–25 of 312", the page shown stays dimmed at its height while the
  next is fetched, answers applied only when latest (re-checked after the second fetch for
  a managed user who left the filter). **The Manage dialog** (`View/UserDialog.hs`): a
  `<dialog>` through `showModal` (two one-line `browserJS` bindings; the browser gives the
  backdrop, inertness, Escape, focus return; no package needed), one scrolling column:
  Permissions (administrator, creates spaces), Signing in (password, password link where
  the server mails, address, disconnect a provider), Groups, Account (danger style, asked
  once: disable, remove the second factor, remove the account); every change saved at once
  with a short "Saved" and the row refreshed; drawn from `managing` plus the last page
  received, so a failed refetch neither tears it out nor reopens it; it refuses to close
  while a request is in flight (Done and × disabled, `cancel` prevented, backdrop ignored;
  if the browser closes it anyway the table hears `Closed` after the answer). **Removing an
  account** (the owner's addition): offered only for a disabled login, never one's own, the
  login typed to confirm; `DELETE api/v1/admin/users/<user>` (409 enabled, 400 oneself, 403,
  404), `Rows.deleteUserRows` in the write bracket (cascades take sessions, memberships,
  identities, second factor, recovery codes, links, verifications, passkeys, vault, watches,
  notifications; grants and drafts deleted explicitly; migration 0002's users delete
  trigger bumps the permission generation, tested); versions and comments stay under
  `formerAuthor <login>` (`~former:<login>`, shown as "login (not a user here)"), others'
  notifications keep the actor under the same former id; no migration; the login is free
  again; `user.remove` in the activity log, the only table keeping the old id; console
  `wiki-server users remove --data DIR LOGIN`; the demo keeps removed logins by id
  (`MemState.removed`, its IndexedDB store never rewrites a version). Screenshots by
  `toolchain/screenshots.mjs` (users, dialog, removal; light and dark) in the README.
  Not changed from review: `keptNotice` rebuilds the record because `n {Notice.actor = …}`
  is ambiguous under GHC 9.14 (`Happened` has `actor` too). Tests: pure (`Test.Users`),
  stub server, contract on five backends, `Test.Storage.Removal`, a Scale case with 70,000
  administer grants (more than a statement's parameters), HTTP, prerender, hydrate,
  routes, and hspec-halogen for navigation, paging, the dialog and the removal. Gate on
  `a40edd7` (then rebased on plan-only commits): 1799 server examples on SQLite and
  PostgreSQL, wasm 106/886/295, the smoke test on SQLite and PostgreSQL. For later:
  `loadUserPage` (LIKE, offset) and WP5.28's `loadUsersStartingWith` (indexed prefix) stay
  separate; the in-flight-close and failed-refetch paths are untested in the browser
  because the demo answers at once.

- **WP5.28 merged** (2026-10-29, PR #113, `main` at `ed56dd9`, eight commits, two review
  rounds: Claude Code at high and Codex `gpt-6.1-sol` at high on each head, 12 + 11
  findings, all but two confirmed and fixed). **Endpoint** `GET api/v1/notifications/people/
  search?q=<letters>` (`NotificationsApi.searchPeople`, `[User]`): users who may sign in
  whose login or display name starts with the letters, case-folded by the database's own
  `lower()` (one `SELECT lower(?)` first, so the comparison folds as the indexed expression
  does: ASCII only on SQLite, the cluster's ctype on PostgreSQL; `@Łu` finds Łukasz on
  SQLite, `@łu` does not, documented), at least two letters (`minPeopleSearch`, to slow an
  enumeration of the directory; `people` only confirms logins the caller knows), at most
  ten (`maxPeopleFound`), ordered by display name then login by code points (WP5.25's
  `byCodePoints`), only logins a mention can name: `Wiki.Core.Markdown.Ast.mentionsWhole`
  is `parseMarkdown ("@" <> login) == Right [Para [Mention login]]` (so `anna-`, `_anna_`,
  `anna*` are left out); the storage reads a further page only when dropped logins fill
  one, inside one read transaction (REPEATABLE READ on PostgreSQL, one `BEGIN` on SQLite).
  Migration `0003-users-by-prefix`: indexes on `lower(display_name)` (and on PostgreSQL
  `lower(login)` and `lower(display_name)` in collation "C"); the prefix is a range (`>=`
  the letters, `<` `prefixEnd`, which raises the last code point and skips surrogates),
  because neither database answers `LIKE` from an index on an expression; the Scale suite
  checks the plan on both backends (PostgreSQL with `enable_seqscan` off). `MonadNotifications.
  mentionCandidates :: Text -> m (Either WikiError [User])` on the demo, the storage and the
  HTTP backend (only a 404 from a server without the endpoint becomes `Right []`; other
  errors are asked again later). **Editor:** `@codemirror/autocomplete` 6.20.4 (pinned),
  `autocompletion({override: [source], defaultKeymap: false})` with the library's keymap at
  `Prec.highest` and `stopPropagation` (Tab accepts; Escape acts only when the list is
  shown, else it reaches the form); the Mac-only Emacs bindings for Ctrl-b/e/k are dropped
  from the text's keymap so Ctrl+B is the toolbar's; the source asks the component with a
  `wiki-mention` event and the component answers through `Editor.Browser.answerMention`;
  answers kept per letters as typed for the editor's life, questions in flight shared, given
  up for the list after 10 s but the late answer kept; `@login` plus a space unless one
  follows. Where a mention counts follows the renderer: not in code, inline links, images,
  wiki links `[[…]]`, references whose label the document defines (an undefined `[note
  @an]` is text, as commonmark-hs renders it), HTML, and not in TeX math, for which the
  editor's syntax tree gains a `TeXMath` node. **Recorded exception to decision 25:** no
  lezer-markdown math extension exists on npm, so `web/src/editor.js` carries two small
  inline parsers for `$…$`/`$$…$$` (commonmark-extensions' rules) and `\(…\)`/`\[…\]`
  (`TexMath`'s), tested in the browser against `parseMarkdown` on twenty cases, plus the
  link check: about 230 hand-written lines beyond the source function. The comment box
  (a plain textarea) gets no completion; later, if ever. Styling through
  `.cm-tooltip-autocomplete` with the theme's tokens, light and dark. Tests: wiki-core
  (`mentionsWhole`, `prefixEnd`), server HTTP (prefixes, folding per backend, a disabled
  user, the limit, the two-letter minimum, the visitor's `[]`, the 400), Scale, contract
  on Mem/SQLite/PostgreSQL/HTTP, the stub server, browser (the list, Enter, Tab, Escape,
  code, links, undefined brackets, math, the Mac shortcuts, a login with `@` not offered).
  Gate: 1815 server examples on SQLite and PostgreSQL, wasm 106/890/297. For later:
  `loadUsersStartingWith` and WP5.25's `loadUserPage` stay separate (different shapes).

- **WP5.29 merged** (2026-10-29, PR #114, merged by the owner as `07bae7a`, nine commits, two review
  rounds: Claude Code at high and Codex `gpt-6.1-sol` at high on each head, 10 + 10
  findings, all confirmed and fixed). **A. Boxes.** `> [!KIND]` takes any kind (letters and dashes, any case, stored
  lower; `validKindName` refuses the five, `title` and `icon`, whose classes the box's parts
  use) and an optional title after the marker, plain text as written; `AlertKind` is the
  five plus `Custom Text`, in the new `Wiki.Core.Markdown.Box`; `Alert kind title blocks`.
  commonmark-extensions' `alertSpec` has a closed kind type, so `Ast` carries its own block
  spec modelled on it (the one place a library could not serve). An administrator defines
  kinds in the Server section's "Boxes" (`BoxKind`: name, label, a colour by name from the
  five's palette plus teal, orange, pink and grey, an icon from a fixed set of inline SVG
  masks: none, info, lightbulb, pencil, question, check, star, book, flag), kept as JSON
  in the settings row `boxes` (no migration) and carried on every `SessionInfo`, so the
  prerender and the first render agree; the renderer (`Render.boxOf`, shared with the
  settings' preview) writes `alert alert-<name>`, the title (written, else the label, else
  the name capitalised) and, for a defined kind, `--box-colour`/`--box-icon` as custom
  properties (reset to `initial` on every box so a nested undefined kind stays grey);
  `web/style.css` changed once. Exports: pandoc's `Ext_alerts` off; the wiki's parser
  decides what is a box (`Ast.boxMarkers`, line and column), `Export.Document.withBoxes`
  replaces each marker with a placeholder pandoc reads as one word (`wikibox` + 8 hex of
  SHA-256 of the source, 16 or 64 if the source holds that start, + a number + `z`, so a page
  cannot spell its own placeholder; a quoted blank line follows it so a table, a `:::` div
  or HTML on the first line stays a block; a placeholder pandoc read as anything but a
  quotation, in any text node, is written back and the page re-read; `\r\n` and lone `\r`
  normalised for both parsers; one parse per page, `Ast.parseWithMarkers`/`Export.readPage`),
  `boxesOf` makes the five pandoc's alert divs and the others `div.alert-<name>` with a
  title div; the page and the export agree on `> [!NOTE]**x**` (a quotation), `> \[!NOTE]`
  (text), markers in code, raw titles. The Markdown guide gains "Notes and boxes"; the demo
  defines `exercise` (teal, pencil) and keeps its server settings across reload and import.
  **B. The guide on every server.** The texts live in `Wiki.App.Guide` (demo and server;
  two tours: the demo's and the server's: signing in, your spaces, editing, the assistant,
  search, where Administration is). `Wiki.Server.Guide`: a first start with no spaces
  installs the public space "Guide" at `/guide` (pages, attachments, macros, the tour as
  home page) in one transaction through `Import.mergeArchive`; `--no-guide` skips it; the
  setting `guide-installed` records the installed space's id and the guide's page paths,
  and install, update and the Overview work on that space only (a space of the wiki's own
  at `/guide` is never touched; `ServerStatus.guideInstallable` is true only when no guide
  exists and nothing holds `/guide`). `wiki-server guide install` puts it back; `guide
  update` keeps per page a hash of the title and text the guide last wrote: a page still as
  written gets the release's title and text (a release rename included), a page an
  administrator changed is left alone and named, a page the guide did not write is left
  alone; it adds a page a release brings that the guide never had (with its attachments; not attachments added to an
  existing page, named in the output), leaves a moved or deleted page alone and names it, publishes `PageChanged` for what it rewrote
  (`Storage.writingThen`; from the console no live channel reaches the running server's
  tabs, which re-read on reconnect after the deploy's restart); both commands in the audit
  log. The Overview offers "Install the guide" (`POST api/v1/admin/guide`,
  `MonadAdmin.installGuide`). `deploy-local.sh --server` runs `guide update` after the new
  server answers (a failure is a warning; `test-deploy-local.sh` covers it). The smoke
  test's server and the test fixture's start with `--no-guide`. Tests: wiki-core (parsing
  kinds and titles, rendering, `Test.Markdown.Box` property that the settings accept
  exactly the names a page reads), exports, settings validation, server (first start,
  not twice, `--no-guide`, own space at `/guide` untouched, update/add/leave-alone, the
  event), browser (Boxes section, a drawn box, Install the guide), deploy. `Wiki.Core.Page.savedAs` is the one
  place a page's new version is made (`savePageTx`, the import, the guide). For later: a
  wiki that ran an earlier head of this branch has a `guide-installed` row of the old shape
  (delete the row and the Guide space, then `guide install`); `guide update` from the
  console cannot reach the running server's live channel; the demo's own tour is unchanged.

- **WP5.30 merged (2026-10-31, PR #118, `2fce100`).** The first package the session
  implemented itself, without a subagent (the owner, 2026-10-31). A passkey signs its
  owner in alone (`POST`/`PUT session/passkey`: no passkey named, the challenge kept
  under itself for five minutes, at most fifty per address, found again by the one the
  client data names), with no second factor, or in place of the code after a password
  (`session/second-factor/passkey`, a refusal counted as a wrong code).
  `Wiki.Server.WebAuthn.verifyAssertion` takes a `Signer`: `Identified` where the wiki
  knows who asks (the vault, the second step), `Unnamed` for a sign-in alone, whose
  answer must carry the owner's user handle; the `webauthn` package checks both and the
  UV flag. Failures count against the address (`Limiter.addressVerdict`/`failedAt`)
  until the passkey names a login, then against it. A disabled user is refused before
  the passkey is checked. Passkeys are the account's: listed, made (with a name, and
  with the current password, as a second factor asks for it, since a passkey signs the
  user in) and removed under `account/passkeys`; `assistant/passkeys/assertion` stays
  for the vault. `AssertionResponse` gains `userHandle`, `RegistrationResponse` `name`.
  Turning the assistant's syncing off keeps the passkeys and drops only the wrapped
  keys; turning it on again asks for a passkey the user has, and makes a new one if
  that is not used; a passkey without PRF is kept to sign in with. In the browser:
  "Sign in with a passkey", the login field's offer (conditional mediation, aborted when
  the form closes, the password is sent or the button used; a ticket in `vault.js`
  keeps a sign-in whose challenge arrives after that from starting), "Use a passkey
  instead" in the code's form, and the account panel's Passkeys section (hidden with a
  sentence over plain HTTP). Plan text not met as written: "the same audit entry" (a
  password's sign-in writes none, so neither does a passkey's) and "the same refusal for
  a closed wiki" (a password's sign-in is not refused there either). Codex reviewed four
  rounds, the owner's new limit: retained passkeys reused for syncing and stale field
  offers; the password to make a passkey (P1), PRF asked for at registration, stale
  button dialogs; password fields emptied after each attempt; a new passkey when the
  user's cannot sync. Also fixed here, as CI would not pass without it: since WP5.35 the
  front page took its directory of spaces down and made it again each time its page
  loaded, so a click on a space's card meanwhile was lost; that was the demo smoke
  test's "flakiness". The directory now stays mounted. Tests: server (a fixed ES256
  authenticator: sign-in, cookie, counter, refusals for origin, UV, user handle,
  unknown passkey, stale or reused challenge, disabled user, the address limit, the
  second step, the password to make one), browser (a `navigator.credentials` stub with
  the field's offer, the button, the second step, the panel, plain HTTP, the stale
  races, the emptied fields), and `toolchain/test-passkeys.mjs` (Chromium's virtual
  authenticator) now signs in with a real passkey after signing out. Gate: native and
  wasm builds without warnings, all native suites (wiki-server-test 1905), the browser
  suite (315), fourmolu clean, CI green on the head. A real passkey on a real device is
  for the owner to try after deploying (HTTPS or localhost). Notes for later: the
  wiki-app `Accounts` record now carries four passkey methods, and the assistant's
  settings always show the password field, since they do not know whether the user has
  a password.

The owner's pick of 2026-10-25 for what follows (from the planning session's list): of the
productionisation items backups, observability and account hygiene (not HTTPS yet); of the
features everything but the Polish interface. Cut into packages that touch different parts,
run in waves of three or four after WP4.8, since each worktree builds both backends and the
runner is one machine. Migrations are numbered at rebase time (the next free number; the
migration test refuses gaps), and whichever merges second rebases.

**Wave A** (after WP4.8): WP4.9, WP4.11, WP4.12, WP4.16. **Wave B**: WP4.10, WP4.13, WP4.14.
**Wave C**: WP4.15, WP4.17.

- **WP4.9 Scheduled backups, off by default** (reshaped by the owner on 2026-10-25: only if
  configurable from the administration and off unless turned on). No systemd timer: the
  server itself schedules backups from a "Backups" part of the panel's Server section, off by
  default; when turned on: how often (daily at a time, or every N hours), how many to keep
  (daily and weekly), and an optional destination off the machine (a directory path or an
  `rclone` remote, with its config as a write-only secret) to which the newest copy and the
  attachments' blobs are copied after each backup. A backup is `VACUUM INTO`
  `data/backups/<timestamp>.sqlite` as the deploy does, checked with `PRAGMA
  integrity_check`, run on a thread of the server with the storage's lock held only for the
  copy; the panel shows the last backup's time, size and result and has "Back up now";
  `wiki-server backup` stays for the console and the deploy, and `wiki-server restore <backup>
  [--attachments DIR]` restores into a stopped server's data directory, refusing a live one. A
  CI test backs up, restores into a fresh directory and compares; the README documents the
  drill. Settings in the `settings` table (no migration unless a `backups` log table is
  wanted for the panel's history: your call).
- **WP4.10 Observability.** `GET /metrics` on the admin listener in the Prometheus text
  format (requests by route and status, latency histogram, open WebSockets, pages, users,
  database and blob sizes, backup age); an *audit log* table (who did what, when, to what:
  grants, settings, accounts, deletions of spaces and pages, imports) written by the storage
  for administration operations, shown in the panel ("Activity", newest first, filter by
  user) and exported with the wiki; `/healthz` extended with the migration version and the
  backup age; the status section shows the last 20 server errors (an in-memory ring).
  Migration for `audit_log`.
- **WP4.11 Account hygiene.** The account panel lists the user's sessions (created, last seen,
  address, the current one marked) with "Sign out" per session and "Sign out everywhere";
  TOTP second factor (RFC 6238, `crypton`'s HMAC, a QR code drawn by us as an SVG `<svg>` of
  rects, recovery codes shown once and stored hashed; required at sign-in when enabled; an
  administrator may remove it from the panel for a locked-out user); password reset by mail
  ("Forgot your password?" under the sign-in form, a single-use token mailed, 30 minutes,
  limited per address, silent when the login or e-mail is unknown; needs an e-mail on the
  account: the account panel and the admin's "New user" gain an e-mail field, verified by a
  mailed link). Migration for `email`, `totp`, `recovery_codes`, `reset_tokens`.
- **WP4.12 Presence and edit conflicts.** Over WP4.5's channel: `ClientMessage` gains
  `editing page`/`stopped`, the hub keeps who edits which page per connection (dropped with
  the connection), `PageEvent` gains `Editing [User]`; the page view shows "X is editing" and
  the editor shows the other editors by name and warns before starting when someone else
  already edits. On save, a 409 (`If-Match` mismatch) opens a conflict view: the other
  version's diff (`Wiki.Core.Diff`) beside the author's text, with "Keep mine", "Take theirs"
  and a manual merge (the author's text in the editor with the diff visible), instead of the
  bare refusal of today; `PageChanged` events refresh a page shown in another tab. No
  migration.
- **WP4.13 Mentions, watching and notifications.** `@login` in Markdown (pages and comments)
  becomes a link to the user with a mention event; a user may watch a page or a space
  (bell button; watching one's own pages and threads by default, a setting); a
  `notifications` table (mention, comment on a watched page or in a thread of mine, change
  of a watched page) shown in the header (badge, list, "mark read") and mailed, at once or
  as a daily digest per the user's setting, through the Server mail settings, with an
  unsubscribe link; nothing mailed about pages the recipient may not view. Migration for
  `watches`, `notifications`, notification settings on the user.
- **WP4.14 Blog view and RSS.** A space setting "shows as a blog" (in Space settings): its
  home shows the pages as dated posts, newest first, with an excerpt (the first paragraph),
  the author and the comment count, paged; a post's page shows its date and "previous /
  next"; `GET /s/<space>/feed.xml` (Atom) and `.rss` for public spaces, with the full
  rendered HTML of each post (through the allowlist) and a `<link rel="alternate">` on the
  space's pages; OpenGraph and `<meta name="description">` on public pages for link
  previews; a `sitemap.xml` of public pages. Reuses WP4.6's directory cards. Migration for
  the space's `blog` flag.
- **WP4.15 Table of contents and templates.** Headings get stable ids (slugified, uniquified)
  and anchor links on hover; a "Contents" panel in the page view (sticky under the action
  bar, on wide screens beside the comments panel, collapsible, current section marked on
  scroll) built from the parsed document, server-rendered; `[[toc]]` in a page places it
  inline. Templates: a space has a "Templates" folder of pages (a flag on the page, excluded
  from the tree and search by default); "New page" offers "Blank" and the space's templates
  (and a few built in: meeting notes, decision record, how-to); a template's `{{title}}`,
  `{{date}}`, `{{author}}` are filled. Migration for the page's `template` flag.
- **WP4.16 Export to PDF, DOCX and Beamer.** Decision (the owner, 2026-10-25): **link
  `pandoc` as a library** in `wiki-server` (native only), not shell out to a binary; so DOCX,
  PPTX, standalone HTML, EPUB and the Beamer `.tex` need nothing installed, and only PDF (and
  Beamer PDF) runs a TeX engine, `xelatex`, through pandoc's own PDF path when the binary is
  found on the machine (the panel's status says whether; the PDF buttons appear only then; the
  deploy's README says `apt install texlive-xetex` is optional). Costs accepted: pandoc's
  build (tens of minutes once, cached in the cabal store; `deploy-local.sh`'s first build after
  this package is long), a larger `wiki-server`, and pandoc's dependency set alongside ours
  (`commonmark`, `skylighting` come with it; `allow-newer` entries as needed). "Export" on a
  page offers DOCX, HTML and, where available, PDF; a deck offers Beamer PDF or `.tex` and
  PPTX, built from `Wiki.Core.Slides.deckOf` (level-1 title → title or section page, level-2 →
  frame, notes → `\note{}`, theme and aspect mapped); a space exports as one DOCX or PDF in
  page order with a title page and a table of contents. The input to pandoc is our own
  Markdown (pandoc's reader with the matching extensions: tables, footnotes, fenced divs,
  `tex_math_dollars` and `tex_math_single_backslash`, raw HTML through our allowlist first),
  images and attachments resolved from the blob store, islands (Mermaid, TikZ) rendered to
  images server-side where feasible and noted in the output where not. `GET
  pages/<id>/export/<format>` streams the file, one export at a time per user, with a
  timeout and a temporary directory; a `pandoc` failure is an `ApiError` with its message.
  Skylighting, which comes with pandoc, may then replace highlight.js in the server render
  (the Phase 4 candidate above) in a later package. No migration.
- **WP4.18 HTTPS by default, through `tailscale serve`** (the owner, 2026-10-26, after
  setting it up by hand: "udało się, możesz dodać do skryptu deploy żeby robił https by
  default"). `deploy-local.sh --server` serves over HTTPS by default on the machine's
  MagicDNS name: the public listener binds to `127.0.0.1` (no port on the Tailscale
  interface, no ufw rule), the unit passes `--secure-cookies`, and the script configures
  `tailscale serve --bg http://127.0.0.1:<port>` (tailnet only, never Funnel), which
  terminates TLS with a Let's Encrypt certificate tailscaled fetches and renews itself. The
  serve configuration persists in tailscaled, so it is set once and checked on every deploy
  (`tailscale serve status`); when the user may not configure it (no operator rights, no
  sudo), the script prints the one command to run and goes on, and the deploy still answers
  on loopback. After the service starts, the script checks `https://<name>.<tailnet>.ts.net/`
  answers, prints that address as the one to open, and reminds the owner to set it as the
  panel's public address when the panel has none (that stays a panel setting, decision 11:
  no command-line bootstrap). `--http` keeps today's behaviour (the Tailscale address,
  plain HTTP, no Secure cookies) for a tailnet without HTTPS certificates. `--bind` with an
  address other than loopback implies `--http`. Prerequisites (MagicDNS and "HTTPS
  Certificates" in the tailnet's DNS settings; the hostname enters public Certificate
  Transparency logs) go in the README, which makes HTTPS the documented path and notes that
  the service worker and "Install" of WP4.17 need it. `undeploy-local.sh` turns the serve off
  (`tailscale serve --https=443 off`) when it was the deploy's, with the same rights caveat.
  Tests: `toolchain/test-deploy-local.sh`'s fake `tailscale` learns `serve` (recording its
  arguments, answering `serve status`), with cases for the default, `--http`, a `serve` the
  user may not set, and the undeploy. No change to the server's code.
- **WP4.17 Offline and PWA.** A web manifest (name, icons from the wiki's own, theme
  colour) and a service worker that caches the application's files (versioned by the build)
  and the last pages read (HTML and API answers, in the browser's Cache API), serving them
  when offline with the offline notice of WP4.3 and a "You are reading an offline copy from
  <time>" line; the editor keeps drafts locally as it does and sends them when back online;
  "Install" offered where the browser allows. The demo on Pages becomes installable too.
  The service worker is JavaScript of ours under `web/`, registered from `index.js`, tested
  by a Playwright case that goes offline and reloads. No migration.

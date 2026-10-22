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
   are not, and the app needs the router and the th quoters. The pin is bumped
   deliberately, in its own commit.
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

Goal: an empty Halogen app builds natively and for wasm, in CI and in a cloud session,
and deploys to GitHub Pages.

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
- **WP0.3 CI and deploy.** `build.yml` (native build + tests; wasm build + tests; caches
  for the cabal store and the wasm toolchain, copied from haskell-halogen's workflow)
  and `build-deploy.yml` publishing the wasm demo to GitHub Pages under the project's
  base path. Acceptance: green CI on the PR, the demo URL serves the hello page.

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
- **WP1.7 Demo polish and release of the MVP.** Seeded tour page, README with the demo
  link, `test-gallery`-style Playwright smoke test of the deployed artefact (every
  route mounts, back/forward/reload work). Tag `v0.1.0-demo`.

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
  prerendered shell, configuration (port, data dir, base path), structured logging,
  a `Dockerfile`, a `docker-compose.yml` for a one-command run.
- **WP2.4 HTTP backend in the app.** `HttpWiki`: `MonadWiki` over `fetch` (JSFFI), with
  errors surfaced in the UI (not found, conflict, offline). The app picks `MemWiki` or
  `HttpWiki` at start from a flag in `index.html`, so Pages keeps serving the demo.
- **WP2.5 Page history.** Every save is a version; a history view with diff (a pure
  Markdown diff rendered in Halogen) and restore.

### Phase 3: authentication and authorisation

Goal: who you are decides what you see and may do, on both sides.

- **WP3.1 Accounts and sessions.** Users with argon2id password hashes, login/logout,
  HttpOnly cookie sessions, CSRF protection, a first admin created from the
  configuration. Rate-limited login.
- **WP3.2 Authorisation.** The permission rules of `wiki-core` enforced in every handler
  (space view/edit/admin, global create-spaces/administer, public spaces for
  anonymous), with tests per rule. Anonymous read of public spaces so the site works
  as a blog.
- **WP3.3 Administration UI.** Users, groups and membership; per-space permissions
  (grant/revoke to user or group, toggle public); global permissions; the UI hides
  what the current user cannot do, using the same pure rules.
- **WP3.4 OIDC login** (GitHub, Google) as an alternative to passwords; account linking.

### Phase 4: beyond the MVP

Candidates, ordered by likely value; each becomes a work package when it comes up.

- Full-text search (SQLite FTS5) with a search box in the shell.
- Export (PDF, DOCX, HTML) and import (Confluence XHTML/HTML, DOCX) with pandoc on the
  server.
- Comments on pages, labels, favourites, recently viewed.
- A table of contents panel and anchors; page templates; a "blog" view listing a
  space's pages by date with RSS.
- Hydration once haskell-halogen has it (the prerendered shell is thrown away today).
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

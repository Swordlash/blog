# Plan: a Confluence-style wiki in Halogen

A wiki of spaces, subspaces and pages, written in Markdown, built on
[haskell-halogen](https://github.com/Swordlash/haskell-halogen). This document is the
working plan: what the wiki has to do, the decisions taken, the work still to do, and
what is known to be missing.

It does not keep the history of the work done. What each work package built, and why,
is in its pull request, in the commits and in the changelog entries under `changelog/`
(the packages' `CHANGELOG.md` files are frozen since #245). Code
comments name work packages ("WP4.11 of docs/PLAN.md"); the texts of the packages done
by 2026-10-31, and the progress log of that time, are in this file as it was at
commit `162a94e` (`git show 162a94e:docs/PLAN.md`).

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
   for `hh` rather than nest combinators, and say so in its report; the first use added
   `th` to `wiki-app`'s dependencies, and until haskell-halogen 893fefa native `alex`
   and `happy < 2.2` to the wasm job for a one-off `ghc-lib-parser` build; since that
   pin (2026-11-03) the quotes are parsed by the compiling GHC's own `ghc` library,
   so neither is needed; since 3459805 (#166, 2026-11-05) that library may be 9.10's,
   9.12's or 9.14's. `clay` is optional:
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
    `data/backups/<timestamp>.sqlite`, and the last few backups are kept. An upgrade
    is checked and can be undone (WP5.73, the owner, 2026-11-06): the maker keeps the
    deployment it replaces in `previous/` with a copy of that backup and its commit,
    runs the new program's `migrate` and `check` before starting it, and rolls back by
    itself when either fails or the new server does not answer; `deploy-local.sh
    --rollback` goes back by hand. A deployment is kept only when a rollback puts
    the whole upgrade back. The rollback reconciles what the upgrade changed
    outside the files (WP5.73c1, #182): the firewall rule and tailscale serve go
    back to the old port, PostgreSQL to its old port, the unit is put back or
    removed. The service is started again only if it was running before the
    deploy, and its PostgreSQL container is stopped only if it was stopped.
    The data comes back too (WP5.73c2, #183): an upgrade that starts an empty
    wiki (a switch between SQLite and PostgreSQL, or `--fresh` on SQLite) sets
    the old one aside (the file into `data/replaced/<time>/`, PostgreSQL in its
    stopped container's volume) and records it in `previous/info` (`aside=`,
    with no backup to restore); the rollback moves the new wiki aside and the
    old one back, or starts the old container on its port. An adoption under
    `--prefix` keeps the old PostgreSQL directory in `previous/` and the
    rollback moves it and the state file back. Before setting a wiki aside, the
    old binary backs it up into `data/backups`. Only a deploy into another
    directory keeps nothing: the old deployment is intact where it was. A
    `Dockerfile`
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
27. **A page's title is its text's first line** (the owner, issue #120, built by WP5.39).
    Every page's text starts with `# ` and the title, and the title is read from that
    line (without a closing `#` run or a `{#id .class}` block); the page shows it once,
    as the heading. The editor keeps the `# ` in place and puts `# <title>` in a page
    that lacks it; the title field only shows the line. Renaming rewrites the line and
    keeps its attributes. Templates are the exception: their first line may be
    `# {{title}}`, so their name is typed in the field as before.
28. **JavaScript bindings: guarded, and promises as values** (the owner, on
    Swordlash/haskell-halogen#95, 2026-11-02). A `Safe` binding runs its call inside a
    `try` and throws what the JavaScript throws as a `JSError`, which Haskell can catch;
    on wasm an exception out of an unguarded synchronous import ends the program.
    Every wiki binding is `Safe`; `Unsafe` (nothing caught) is for code called on every
    render, as haskell-halogen's DOM operations are. A binding that starts asynchronous
    work returns `IO (Promise a)` and the program waits for it (`wait`, `waitCatch`,
    `mapConcurrently`, as with `async`); there are no awaiting imports any more. The
    bindings that awaited before #124 keep their old type through a wrapper that waits.
29. **Math macros and kinds of box, from the editor** (the owner, 2026-11-02, built by
    WP5.41). A page's own macros are a `math` block of definitions under its title; a
    formula with nothing to show shows nothing, and an empty block is not written. The
    editor's Box menu offers "New kind…" in a dialog with the same form as the
    settings' Editor tab, and the kind saved there is in the menu at once, without
    leaving or reloading the editor. Boxes are numbered within the page by default.
30. **The browser's objects through fields** (the owner, issue #122, built by WP5.46 in
    haskell-halogen and WP5.47 here). The browser's own objects (the window, the
    document, elements, events, the history, files, the caches) are read and called
    from Haskell through haskell-halogen's Web types and their `HasField` instances
    (`w.history.go`, `event.key`, `file.bytes`), not through a one-line JavaScript
    function per member. A member the wiki needs and core lacks goes into core, beside
    its newtype (an instance written here on a core type would be an orphan), in a
    haskell-halogen pull request before the wiki's. The wiki's own objects (the editor's
    host and its CodeMirror, the install prompt the loader keeps, the entries of the
    session history) are wiki newtypes over a `JSVal` with `jsFields`. A single call
    with an options object is an `inlineJS` expression in Haskell. What stays in
    `jsbits` is logic of the wiki's own, by decision 25: the zip archive, the reader's
    selection, the layout and the contents panel, CodeMirror's text and selection in
    UTF-16 code units, the live preview's channel, the assistant's SDKs and the vault.
31. **A user's feed of notifications, at an address only a POST makes** (built by
    WP5.31). A signed-in user has an Atom feed of the bell's list (the latest 50 about
    pages they may still read, title and link only, no body) at
    `me/notifications.atom?token=<secret>`, served outside the API's closed-wiki check
    with `Cache-Control: private, no-store` and outside `FeedCache`. The secret is
    made by `POST notifications/feed` and replaced by a later one; `GET` only reports
    the address, or none, so opening the account panel never makes a secret. A wrong,
    missing or renewed token is 404, not 401; the operator has none. The feed's `<id>`
    and its entries' ids are built on the wiki's address, the feed's path and the user
    id (`FeedHead.identity`), never the token, so a renewed address leaves them as they
    were and two users' feeds differ; the feed has no self link, and the alternate
    link is the wiki.
32. **The pages are built on GitHub and kept as release assets** (the owner,
    2026-11-03, built by WP5.49). `.github/workflows/server-page.yml` builds, on every
    push to `main` that changes code and on every tag, the server's page and the
    demo's from one `app.wasm`, and keeps them as release assets, which a public
    repository serves without a token: `app-server-<hash>.zip` and
    `app-demo-<hash>.zip` for the newest five commits of `main` on the pre-release
    `main-latest`, and `app-server-<tag>.zip` and `app-demo-<tag>.zip` on a tag's
    release, for good. `toolchain/deploy-local.sh --backend-only[=REF]` (REF: the
    checkout's commit, `main`, a tag or a hash) downloads the mode's page with `curl`
    alone and builds nothing for the browser: `--server` builds `wiki-server` after the
    bootstrap's `native` mode (the host GHC and cabal alone, no wasm toolchain, no
    Node, no npm) and `--static` builds nothing at all (the bootstrap's `node` mode:
    Node alone, for `server.mjs`). The server's mode uses no Node: gzip copies from
    `wiki-server compress`, probes with `curl`, JSON and zips through `python3` (or
    `jq` and `unzip`). The deploy checks libsodium, libpq and GMP before anything is
    built, names their Debian and RHEL packages, passes `PKG_CONFIG_PATH`,
    `LIBRARY_PATH`, `C_INCLUDE_PATH` and `CPATH` through, and writes the shell's
    `LD_LIBRARY_PATH` into the unit. Markdown counts as documentation in CI's filters
    and in the deploy's "same page" fallback except what is compiled in: the built-in
    templates and the Markdown reference (`is_code` in the script, the `paths` filters
    of both workflows).
33. **HTTPS three ways, exclusive of one another** (the owner, 2026-11-03, built by
    WP5.50). `tailscale serve` as before, the default; the server's own TLS,
    `wiki-server serve --tls-cert FILE --tls-key FILE` through `warp-tls` on the public
    listener alone (PEM, a chain after the leaf, one `.pem` for both; the key checked
    against the certificate at start, since tls does not; the session cookie `Secure`
    and the public address `https` without a proxy header; a renewed certificate takes
    a restart), which the deploy takes with `--tls-cert`/`--tls-key` (and `--tls-ca`
    for a check by the certificate's DNS name) at any `--bind`, `0.0.0.0` included,
    the files refused inside the deployment directory unless under `data/`, `state/`
    or `toolchain/`, which the install keeps; and `--behind-proxy` for a reverse proxy
    (Caddy, nginx) that terminates TLS: plain HTTP on `127.0.0.1`, `Secure` cookies,
    the forwarded headers the server already reads. `--https`, `--http`, `--tls-cert`
    and `--behind-proxy` refuse one another; the state remembers the way, and a
    deployment from before reads as Tailscale or HTTP from its old key.
34. **The PostgreSQL backend is a cabal flag** (the owner, 2026-11-03, built by
    WP5.52). `wiki-server`'s flag `postgres`, on by default and manual, puts
    `Wiki.Server.Storage.Postgres` and its `beam-postgres`, `postgresql-simple` and
    `postgresql-libpq` dependencies in the build; with it off (`--constraint
    'wiki-server -postgres'`) a PostgreSQL `--database` or `WIKI_DATABASE_URL` is
    refused at start, `wiki-server --version` lists the backends it has, and the test
    suite's PostgreSQL group is left out with a note. CPP sits only where the backend
    is chosen (the storage, its backend instance, the backup and restore, and a flag
    read in the layout); `PgPrograms` lives in the layout so the options and the
    console need none. The deploy builds with the flag off for a wiki in SQLite and
    on otherwise, explicitly, and for the wiki's server in SQLite passes
    `--without-postgres` to `check-native.sh` and to `bootstrap.sh native` and
    `build`, which then ask Debian for no `libpq-dev`: a SQLite deployment needs
    neither libpq nor `pg_config`, on either path, on Debian without root or on RHEL.
    CI's `native (unit)` job builds `wiki-server` with the flag off as well and runs
    its unit group, so a warning on either side is caught.
35. **The deploy has a wizard, a cabal script on brick** (the owner, 2026-11-03, built
    by WP5.51). `toolchain/configure.hs`, run through `sh toolchain/configure.sh`
    (which runs the native check and `bootstrap.sh native` with `--with-wizard`, the
    terminfo item and Debian package only the wizard needs, then `cabal run -z`:
    outside the project, since cabal would otherwise resolve the whole wiki for the
    script), asks for the deploy's options in eight screens, prefilled from the
    deployment's state file found as the deploy finds it, resolves paths with the
    deploy's own `realpath -m`, and on the last screen `exec`s `deploy-local.sh` with
    the command line it shows (`q` prints it instead). Every option in the deploy's
    header is a literal in the wizard and the other way round, checked by a test, so
    the two cannot drift; `--args-from FILE` runs the answers without screens for the
    tests (`toolchain/test-configure.sh`, run by the deploy test with
    `WIKI_TEST_WIZARD=1`, which CI's `deploy` group sets since #234: brick
    comes from the cabal store the `unit` group saves, and on CI a missing
    `script(1)` fails the screens case instead of skipping it).
36. **Links to pages, sections, boxes and selected text; the home page's options in
    its editor** (the owner, 2026-11-03, issue #120, built by WP5.53). The editor's
    "Link to a page" (Ctrl+Shift+K) picks a page through the search's picker (the
    header's box and the dialog share it) and, with "link a section", one of the
    page's anchors (`Toc.anchors`: headings and boxes with ids); the link's address is
    the route's own path (`/s/…/p/…`), which `resolvePageLink` reads first, the path
    form written by hand still read after it; the title goes through `labelText`
    (brackets as character references, since `\[…\]` would be display math). A box
    has an id (`box-<kind>-<n>` by its kind's count in the page, a starred box its
    title's slug) and the same hover `#` as a heading; in the page view that `#`
    copies the absolute address instead of navigating ("Link copied" in the corner;
    the href stays for a middle click). A selection's "Copy link" uses the browser's
    own text fragment (`#:~:text=`), built from the rendered text with breaks at block
    edges, islands and elements without text, a quote across a break written
    `start,end`; nothing of ours reads it. The home page's Show Spaces, Show Recently
    visited, Show to signed-out visitors and the icon are edited with the home page
    (`EditHome`) and saved with it, no longer in its view.
37. **Private subspaces, and personal spaces** (the owner, 2026-11-04, built by WP5.54).
    A space has `sealed`: `spacePermissions` reads only the chain from the last sealed
    space down (`sealedChain`), so no ancestor's grant or `public` flag reaches a sealed
    space, its own grants and its own `public` still work, its subspaces inherit from it,
    and a global administrator still sees everything. The settings' Permissions component
    has the "Make private" switch (`PUT spaces/<id>/sealed`, audit `space.sealed`); it
    grants the sealer `AdministerSpace` when they held it by inheritance alone, so that
    one click cannot lock them out. Personal spaces: `Space` has `owner`, `active` and
    `personalContainer`. "Enable personal space" in the account menu (`PUT
    account/personal-space {enabled}`, audit `space.personal`) makes, the first time
    anywhere, the container "User subspaces" (slug `users` or the next free one; known by
    its flag, not its slug; viewable by nobody, administrators included, and refusing a
    subspace made by hand, a move into it, rename and delete), and under it the user's
    space: slug the login slugified, public, the owner holding `AdministerSpace`, named
    "Space of <display name>" wherever spaces are read and never stored; rename and move
    are refused, everything else is an ordinary space's. Disable sets `active = False`
    and keeps the data: an inactive space in a chain gives nobody anything,
    administrators included. The Starred panel shows an active personal space first, as
    "Your space". Removing an account deletes its personal space. An archive carries the
    four fields when they differ from the defaults, and `readArchive` checks they fit
    together (an owner among the archive's users, one personal space per owner, one
    container, personal spaces under it only); a merge import brings personal spaces in
    as ordinary spaces, a turned-off one with its whole subtree private and the top of
    each run of hidden spaces the import creates sealed, so nothing it hid becomes
    readable. The container leads somewhere all the same (WP5.72, #178, the owner,
    2026-11-06): while the reader may open some personal space, it is a link, with
    the 👤 icon, to the finder of user spaces (`/user-spaces/`, `UserSpaces`), and
    the sidebar keeps "Your personal space" under it; the front page's card and the
    breadcrumbs lead there too. The finder lists the reader's own space and the
    user spaces whose home page they starred (a star on a space's home page is the
    space's star), then finds the others by login or display name over the spaces
    already listed, asking the server nothing. A new login is ASCII, with at least
    one letter or digit (`parseLogin`, the owner, the same day), so a personal
    space's slug spells its owner's login and the finder matches the login as
    typed; a login made before the rule is kept.
38. **Avatars, who is reading, who wrote, the editor's title, a line continuation, the
    page's width and PDFs in a tab** (the owner, 2026-11-04, built by WP5.55). `User` and
    `Version.Author` carry `avatar` (a blob and its media type), joined from the users
    table wherever an author is named and never stored on a comment or a version;
    `PUT` and `DELETE account/avatar` (the icon's media types, 1 MB at most), served at
    `users/<id>/avatar/<blob>` as an icon is, under the closed wiki's rule. The crop is
    made in the browser with Cropper.js from npm, bundled as a lazy island chunk (no
    CDN), a 256 px square shown round by CSS; a user without a picture is the first
    letter of their name on a colour from the name. A personal space with no icon of
    its own is answered with its owner's avatar as its icon in the application's reads
    only: writes, the transaction and the export keep the stored icon, an icon set in
    the settings wins, "none" falls back. Who is reading: a subscription on the live
    channel is reading; the server sends the readers (at most 15 names, each user once,
    the tab's own user left out, visitors not signed in counted) with the
    subscription's answer and on every change, and the page shows a stack of at most 5
    avatars, "+N" and a visitors' circle, the hovered one lifting. Who wrote: `Page`
    carries `createdBy` and `updatedBy` from its first and latest versions, and a byline
    under the title replaces the footer's "Last changed". The editor's title of a normal
    page is text, and a click puts the caret on the first line. A line ending with a
    backslash continues on the next, decided in the renderer; two trailing spaces join
    too, since the parser gives one node for both. The page bar ends with "Compact |
    Full width", remembered in the browser: on a wide screen the bar spans the content,
    the text is centred at the reading width or fills it, and the contents panel is
    pinned right. PDF exports are answered `inline` and opened in a tab, since Chromium
    browsers block downloads over plain HTTP.
39. **Claude at another address** (the owner, 2026-11-04, built by WP5.57). The
    assistant's settings take a base URL for Anthropic as for OpenAI (`baseUrlOf` for
    every provider but the scripted one): the model list, "Test the key" and the chat go
    there, the service is named by its host, and the hint and the "cannot reach"
    warning point at the administration's list of the assistant's hosts (the CSP) and
    at CORS. No choice of the key's header: the pinned `@anthropic-ai/sdk` 1.3.0 sends
    every key as `Authorization: Bearer`, never `x-api-key` (its `apiKeyAuth` and
    `bearerAuth` both; `toolchain/test-assistant.mjs` asserts it), so the owner's
    gateway, which takes a bearer token, is reached by the base URL alone. A 401 is
    explained: "<service> refused the key: it has probably expired or been revoked.
    Paste a new one in the assistant's settings.", with a link to them, in the chat, in
    "Test the key" and in the model list.

40. **The deploy installs a TeX that works** (the owner, 2026-11-04, built by WP5.58).
    `toolchain/check-tex.sh [ENGINE]` typesets the document the server's probe
    typesets (`fontspec`, `unicode-math`, `lmodern`, a formula; the same text in both
    places, kept identical) under the export's limits within 60 s, and says `working`,
    `failing` with the reason and the log's tail, or `not-found`. `deploy-local.sh
    --server` runs it after the toolchain step with the PATH the service will have
    (`systemctl --user show-environment`, else `/usr/local/bin:/usr/bin:/bin`), and
    says so when the shell finds an xelatex the service does not. When the engine is
    missing or failing it offers TeX Live under the toolchain,
    `<toolchain>/.wiki-toolchain/texlive/<year>` (not `~/texlive`, where people keep
    their own): `install-tl` cloned from its GitHub mirror,
    `https://github.com/TeX-Live/installer` (`--texlive-installer URL|DIR` names
    another repository or a directory; the owner, 2026-11-05, since a proxy of the
    owner's rejects CTAN's `.tar.gz` and lets GitHub through), the packages from
    the mirror (`--texlive-mirror`, default `https://mirror.ctan.org`, remembered),
    `scheme-basic` without docs and sources,
    then `tlmgr install` of `toolchain/texlive-packages.txt` (scheme-basic has no XeTeX;
    the list brings it, with what pandoc's template, Beamer, TikZ, `tikz-cd`,
    `pgfplots` and `mhchem` need), then the check again with the new `bin` first;
    about 250 MB, said before asking. `--texlive` and `--no-texlive` answer without
    asking; on a terminal the question is asked and the answer kept (`texlive`,
    `texlive_dir`, `texlive_mirror` in the state file); without a terminal nothing is
    asked, installed or recorded. The unit gets `Environment="PATH=<bin>:/usr/local/bin:
    /usr/bin:/bin"`; `--status` runs the check with the unit's PATH; the undeploy leaves
    the TeX Live with the toolchain. Nothing about TeX stops a deploy. The wizard's
    database screen offers the TeX on this machine, TeX Live under the toolchain (with
    the mirror) or none, prefilled from the state; "the TeX on this machine" over a
    remembered `texlive=yes` gives `--no-texlive`. Perl and its standard modules are
    checked at install time, not in `check-native.sh`.

41. **Exports that say what went wrong** (the owner, 2026-11-04, built by WP5.56). The
    server tries its TeX engine before offering PDFs: `probeTexEngine` finds `xelatex`
    and typesets, under exactly the export's conditions (`restrictTeX`, `texLimits`,
    `-halt-on-error -interaction nonstopmode`), a document that loads what pandoc's
    template loads (`fontspec`, `unicode-math`, `lmodern`) and sets a formula, within
    60 s (`ServeOptions.texProbeTimeout`), in a process group of its own that is killed
    on timeout. The result (`EngineNotFound | EngineWorking path | EngineFailing path
    output`, the output at most 2000 characters: how the engine ended, stderr's tail,
    the log's errors) is kept in `Env` with its time; made once at start, before
    listening (the `tex-engine` log event), and on `POST api/v1/admin/tex-engine/check`
    (`GET api/v1/admin/tex-engine` answers the last result; administrators only;
    `Wiki.Api.Admin.TexEngine {status, path, output, checkedAt}`; `MonadAdmin.texEngine`,
    `checkTexEngine`). The PDFs are offered only while the engine works; a PDF export
    while it fails answers 400 with one sentence pointing at the administration's
    Server section, which shows the three outcomes, the engine's output folded past 12
    lines, the usual causes (a missing format file, a service whose PATH or HOME differ
    from the shell's, a TeX Live older than 2021 whose kpathsea refuses full-path reads
    in paranoid mode, missing packages) and "Check again" with the time. The
    application fetches exports (`MonadWiki.fetchExport :: ExportTarget -> ExportFormat
    -> m (Either WikiError Document)`, the file name from `Content-Disposition`) and
    saves them from a `blob:` URL (`Browser.download`), a PDF opened in a tab
    (`Browser.openInTab`) or saved with a notice when the browser opens no tab; a
    refusal shows the server's sentence in a notice of the export component (red,
    dismissable, 15 s); while a document is made its entry says so and the entries
    wait; the HTTP backend gives an export, and the engine check, two minutes, and the
    server pauses Warp's idle timeout for both. A request is counted in the metrics
    just before its response is handed to Warp, so the duration histogram measures the
    time until the response starts.

42. **The key is tested before it is kept, and the crop is a modal** (the owner,
    2026-11-04, built by WP5.59). `readyWith :: Text -> Provider -> Settings -> Maybe
    Ready` builds the request `readyFor` builds with a typed key in place of the kept
    one. The key form's one primary button, "Test and keep the key" (Enter submits
    it), first fetches the model list with the typed key and shows it: a 401 refuses
    the key with decision 39's sentence and keeps nothing; any other failure of the
    list goes on with the chosen model (a gateway without a list); then it tests a
    message with the chosen model if the list has it, else the list's first; passing
    keeps the key and that model (storage, vault, the field emptied) and says so;
    failing keeps nothing and leaves the list shown, so another model can be chosen
    and the button pressed again (the owner's choice over a 404-for-model path). While
    checking, the field, the service, the model, the effort and the button are
    disabled; a result arriving after another user signed in or after the base URL
    changed is dropped. "Test the connection (no key)" shows only while the field is
    empty. The avatar's crop is a `<dialog>` shown as a modal, as the editor's link
    dialog, centred in the window, the canvas a square of `min(100vw - 4.5rem, 100vh
    - 14rem, 28rem)` with the picture fitted whole; once the picture is ready the
    component measures the canvas and the picture (`Wiki.App.Web.Rect`: `boxOf`, an
    element's box read through a newtype with `jsFields`, since haskell-halogen's
    `Element` has no `getBoundingClientRect`; `centredSquare`) and places the
    starting selection as the largest centred square inside the picture, through
    the adapter's `select`; the adapter (`web/src/avatar.js`) keeps Cropper.js's own
    calls only (Codex's finding, twice, under decision 30).

43. **The assistant's addresses come from the server** (the owner, 2026-11-04, built
    by WP5.60 in WP5.59's pull request). `ServerSettings.assistantHosts` (origins for
    the CSP) is replaced by `assistantServices :: [AssistantService {name, baseUrl,
    api}]`, `api` Anthropic's or OpenAI's (JSON `"anthropic"`/`"openai"`): names
    trimmed, non-empty, unique regardless of case; an http(s) base URL with a host,
    no fragment, no `*`, kept as typed but for trailing slashes. Old settings and
    `assistant-hosts` rows read as services speaking OpenAI's API named by host and
    port (a wildcard host dropped). Every session carries the list
    (`SessionInfo.assistantServices`, the server-rendered one included); the CSP's
    `connect-src` takes each service's origin plus `--assistant-hosts`, which stay
    allowed but are not offered. The Server section edits the services as the
    sign-in providers are edited (name, base URL, API). The assistant's settings
    offer, per provider, a "Service" choice: the provider's own and the session's
    services speaking its API; choosing one sets `baseUrl` as before, so `readyFor`,
    the vault and the model list are untouched; a kept address no service offers is
    shown as no longer offered and replaced by the next choice; the demo offers the
    provider's own only. No free field anywhere.

44. **The server is told when the TeX is off, and Perl is built for the installer**
    (the owner, 2026-11-04, built by WP5.61). `wiki-server serve --no-pdf`: the server
    runs no probe, offers no PDF format, answers a PDF export with 400 "PDF exports
    are off on this server (its --no-pdf option)", and the administration's engine
    status is `off` (`TexStatus`'s fourth value; the check endpoint answers it
    without probing); the Server section shows the state with what turns the PDFs on
    and no "Check again". The probe's timeout is 20 s, in the server (`probeTimeout`)
    and in `toolchain/check-tex.sh` (`WIKI_TEX_TIMEOUT` overrides); the export's own
    minute stays. `toolchain/check-native.sh` lists xelatex as an informative item
    through `check-tex.sh` (working, failing with the reason, not found), never
    counted, never a failure. The deploy's TeX step ends with `pdf=yes` only where it
    ends with a working engine, and the unit's `ExecStart` carries `--no-pdf` exactly
    otherwise (the found engine failing or absent and nothing installed, the install
    or its check failing, `--no-texlive` or the question declined); a later run that
    ends with a working engine drops it; `--status` reads the unit and says so. When
    the install needs Perl and the machine has none, or one without its standard
    modules, the deploy builds Perl (one pinned version, a shallow `git clone` of
    `https://github.com/Perl/perl5` at its tag, with no checksum: the owner,
    2026-11-05, over CPAN's tarball, which the owner's proxy rejects, and over
    re-pinning; `--perl-source URL|DIR` names another repository or a directory;
    `Configure -des -Duserelocatableinc`, `make`, `make install`, no `make test`)
    under `<toolchain>/.wiki-toolchain/perl`, for
    `install-tl` and `tlmgr` only, never on the unit's PATH, records `perl_dir` and
    reuses it; the terminal's question is one, naming the TeX Live download and, when
    needed, the Perl build; `--texlive` answers yes to both; the undeploy keeps that
    Perl with the toolchain. The CTAN binaries are accepted (the owner, 2026-11-04).
45. **Spoilers and scrolling listings (WP5.62, issue #152).** A block spoiler is a
    named pair of marker lines, `[[spoiler]]{name}(Description)` and
    `[[/spoiler]]{name}` (the owner, 2026-11-04: markers over a box kind, so that any
    blocks go inside and spoilers nest; the spelling after bbcode; the name one word,
    as an identifier in code; the description inline Markdown; both required). They
    are a container block spec on the parser's node stack, so they never reach the
    inline parser and the wiki links are untouched; a marker is one only on a line of
    its own, mid-line it is a wiki link. An end marker closes only the innermost open
    spoiler and only when the names agree, and is not read inside code or HTML blocks.
    A broken line (no braces, a bad name, no description, text after `)`, an end
    marker with no name or the wrong one, no spoiler open) is an error line in red
    with its reason, and an unclosed spoiler holds everything below it, in red. A
    spoiler never cuts a section (the owner, 2026-11-04): either its content has no
    heading, or it is a section spoiler (its first block a heading of level N, every
    heading inside deeper, ending before a heading of level N or less or at the
    document's end); anything else is an error. A good spoiler is `<details
    class="spoiler" data-spoiler="name">` with the description as its summary, closed
    by default; the contents, anchors, plain text, search, footnotes, mentions,
    formulas, pauses and slide steps all look inside. Open or closed is remembered
    per user, page and name in the browser's localStorage (a server-side store may
    come later), restored when a spoiler first appears, and shared with the editor's
    preview; a click on a contents entry, an in-page `#heading` link, `hashchange`
    and load open the spoilers around the target heading, and the current-section
    marker watches headings inside open spoilers. An inline spoiler, `||text||`, is a
    formatting spec like strikethrough, a `span.spoiler` blurred until clicked or
    Enter or Space when focused, hidden again by a second click; blog excerpts show
    it as "…". The toolbar has an inline button in the text tools and a block button
    in the block tools (the marker pair around the selection, the placeholder name
    selected). Exports show a block spoiler as a box titled by its description and a
    red line as its text; inline spoilers are marked at the source positions the
    wiki's parser recorded, so escaped bars, character references and bars in code
    export as pandoc reads them. Exported headings get the identifiers the wiki gives
    them: pandoc reads with automatic identifiers off, the identifiers written in the
    source (which the wiki's parser reports) are kept and reserved, and every other
    heading gets the wiki's slug with its `-2`, `-3` suffixes in document order, so a
    page's `#answer-2` link lands on the same heading in the document (plain
    duplicates used to get pandoc's `-1`). A fence's `{rows=N}` (a positive whole
    number of at most six digits) gives the `<pre>` the class `code-scroll` and
    `style="max-height: Nlh; overflow: auto"`, so it scrolls in the server-rendered
    page before any script runs; `overflow` is in the inline style as well as the
    class so a feed or an unstyled page still contains the listing.
46. **A copy button on code blocks, and numbered listings (WP5.63).** Every code
    block on a page, in the editor's preview, in comments, on slides and in the guide
    has a button in its top right corner that copies the listing (the owner,
    2026-11-05). The renderer's `copyButtons` option (off by default, on in the
    application's island options, so the feed has none) wraps the block in
    `div.code-block` holding the `<pre>` and an empty `button.code-copy` beside it,
    not inside it: the highlighter replaces what it fills, and a scrolling listing
    would carry a child button away. The label (Copy, Copied, Not copied) is drawn by
    the stylesheet from `data-copy`, so the button has no text: none in the page's
    text, comment anchors, search or a selection. It shows on hover, on keyboard
    focus and while a label is up, always on touch screens, never in print or
    without scripting. A document-level click listener in the islands script copies
    the `<code>`'s `textContent` with the clipboard API, falls back to selecting the
    code and the old copy command, and says Not copied when both fail; so it works on
    the server-rendered page before the application runs, which the smoke test
    checks with a real clipboard. A fence with the class `numbered`
    (` ```haskell {.numbered} `, with `rows=N` too) shows a number before each line
    (the owner, 2026-11-05): the `<pre>` gets the class `numbered` and starts with an
    `aria-hidden` span of one empty span per line, numbered by a CSS counter, so the
    gutter has no text, is right-aligned, dimmed, not selectable, and scrolls with
    the code; `numbered` is never read as the language. For the gutter to survive
    highlighting every listing is `<pre class="wiki-code"><code>…</code></pre>` with
    the island's ref on the `<code>`, which the highlighter fills in place. Exports
    give such a block pandoc's `numberLines` class: the LaTeX writer numbers the
    lines, the Word writer does not. The toolbar's code block command is unchanged.
47. **Section spoilers marked on the heading (WP5.64).** A heading whose text starts
    with `[[spoiler]]`, or `[[spoiler]]{name}`, a space and text hides its whole
    section (the owner, 2026-11-05: marking the heading says at once that the section
    is hidden, and a FAQ writes the question once; a name is optional, the heading's
    anchor id keys the remembered state otherwise): from the heading to just before
    the next heading of the same or a higher level, the footnotes, the end of the
    document or of the container the heading is in (a marker pair, a fenced div, a
    blockquote, a list item, a box); no end marker; nesting by structure. In the
    AST it is `Spoiler` with `kind = OnHeading` (`SpoilerHead.kind`), the heading
    without the marker as the first block and no description, so every walker that
    looks inside spoilers reads the heading as a heading. It renders as
    `details.spoiler.spoiler-section` whose summary holds the heading itself, at
    its level's size, with its id, anchor and contents entry; closed by default; the
    contents, an in-page link and a URL fragment open it as they open the pair's;
    the current-section marker watches the summary heading always and the headings
    inside only when every spoiler around them is open. `[[spoiler]]` elsewhere in a
    heading, with a bad name, no space or no text stays a wiki link; a setext
    heading cannot carry it. The pair's section rule treats a heading spoiler as a
    section starting with a heading. Exports drop the marker and export the section
    plain, with the wiki's ids; the feed shows the section without the box
    (`hiddenSections` off); a deck shows a top-level heading spoiler as its plain
    section; blog excerpts skip its paragraphs.
48. **A deploy for a machine that installs nothing from the internet (WP5.67).**
    Five options of `toolchain/deploy-local.sh`, remembered in the state, shown by
    `--status`, offered by the wizard and taken by `toolchain/configure.sh`, usable
    together or apart; the deploy without them is unchanged. `--system-tools`: GHC,
    cabal and Node are the machine's own; `bootstrap.sh` keeps floors beside the
    pins (`GHC_MIN_VERSION=9.10`, the oldest GHC haskell-halogen builds and
    tests with; `CABAL_MIN_VERSION=3.12`, the first with `--semaphore`
    and `cabal path`; `NODE_MIN_MAJOR=24`), and its read-only
    `system-tools [native] [node]` runs before anything else and checks only what
    the run needs: a missing or too-old tool stops the deploy, named with the
    version found and the note that removing the option lets the bootstrap
    install it; another version than the pinned one is used with a warning.
    Refused with a page built here, which needs the wasm toolchain. The floor was
    9.12 while `haskell-halogen-th` required `ghc >= 9.12`; haskell-halogen
    3459805 (its #103) takes the `ghc` library of 9.10 to 9.14, and with that
    pin (#166) the wiki builds on 9.10.3 and 9.12.2 once four local helpers that
    9.14 typed by itself carry their types (two in `Wiki.Server.Storage`, two in
    `Test.Storage.Scale`; #163), so the floor is 9.10. No CI job builds with an
    older GHC: the experiment's stores, several GB each, pushed the main
    branch's caches out of the repository's 10 GB. `--npm-registry URL`: `NPM_CONFIG_REGISTRY` for every npm and npx
    call; `npm ci` rewrites the lockfile's `registry.npmjs.org` addresses to it.
    `--hackage-mirror URL`: written into `$CABAL_DIR/config` before `cabal update`
    (forced when the address changes), `secure: True` kept, so the bootstrap
    fetches the mirror's `root.json` first and refuses a mirror without one;
    refused for a home-directory toolchain, where `~/.cabal` is the user's; a
    later run without the option writes Hackage back. `--bundle-locally` (with
    `--backend-only[=REF]` or `--app-page`): `BUNDLE_OUTPUTS` are deleted from
    CI's page and rebuilt into it by `npm ci` and `web/bundle.sh` (into the page,
    because `sw.js` hashes the files kept from CI), then compared file by file;
    `app.wasm`, `index.html`, the prerendered files and `ghc_wasm_jsffi.js`
    (written by the wasm post-link) are kept from CI's page; CI's bundles proved
    byte-identical when rebuilt this way. `--app-page FILE`: the page's zip from a
    file, refused without `app.wasm` or of the other kind, not combined with
    `--backend-only`; cached as `app-<kind>-file-<SHA-256>.zip` with the path in
    its `.meta`, checked fully before the cache is touched, so a refused
    replacement leaves the last good copy; with the file gone the cached copy for
    that path is used and said so. README has "A machine that installs nothing
    from the internet".
49. **The editor marks what does not render (WP5.65).** `Wiki.Core.Markdown.Problems`
    lists a page's problems as a first and last source line, a kind (formula,
    diagram, picture, spoiler, box) and a message, without touching the parser:
    `parserProblems` from the tree (a spoiler marker line in red, a spoiler not
    closed or cutting a section, a quotation that starts like a box marker but is
    not one, top-level only), `islandPlaces` the lines of every island by the key
    the renderer itself gives it (the page rendered with callbacks that record the
    keys), `allProblems` the two together. An island's lines are found by searching
    its block's text, since the parser keeps lines for top-level blocks only: a
    formula by its whole match between its delimiters in source order, code spans
    blanked out, the blocks a paragraph is split into by display math counted
    together, the source's first line as the fallback. The islands report: KaTeX
    once with `throwOnError` for the message, then as before; Mermaid and TikZ by a
    `wiki-island-drawn` event on their element; `Islands.reporting` raises `Failed`
    and `Cleared`, `Islands.component` nothing, so the reader's page is unchanged.
    The editor checks its text on a worker thread after typing stops, keeps island
    failures by key until the preview draws a text without the key
    (`keepDrawnFailures`, so an undo with the preview hidden brings a mark back), and
    shows them through `@codemirror/lint` (6.9.7): lines underlined, a gutter, the
    message, and a "N problems" button that jumps to the next. Island problems
    appear once the preview has drawn the island; text-only mode shows the parser's.
50. **"What's new?", built from one changelog entry per pull request (WP5.66).**
    `changelog/<number>-<slug>.md` holds one entry per pull request, the number
    its pr with zeros in front to five digits (the owner, 2026-11-05, #170: the
    files list in order; `00000` before the pull request is opened), checked
    against the entry by the reader and the CI check: four lines of front
    matter (`pr: N`, `title: T`), then `## New features`, `## Bug fixes` and
    `## Other changes` in that order, the first with a code example; the grammar is
    the README's "Changelog entries" and is the same in `toolchain/check-changelog.sh`
    and the server's reader. The server embeds the entries at compile time
    (Template Haskell, a stamp file listing them so cabal rebuilds for a new one)
    with its version (`WIKI_BUILD_VERSION`, else `git describe`) and build time,
    and serves the newest twelve at `GET api/v1/whats-new`; `--no-whats-new` (the
    deploy's and the wizard's too) turns the page off. The page shows them as one
    document, each entry's ids prefixed `pr-N-`, its links followed on the page;
    a dot on the sidebar's link marks entries newer than the reader's browser has
    seen. CI's `changelog` job requires exactly one new entry numbered with the pull
    request; the owner's label `no-changelog` exempts one (AGENTS.md). The demo
    has the page too (WP5.71, #171; the owner, 2026-11-05): the reader and the
    splices that embed the entries are `wiki-api`'s (`Wiki.Api.WhatsNew.Entry`,
    `.Embed`), and `wiki-app` embeds the same entries (`Wiki.App.Demo.WhatsNew`,
    through a `changelog` link beside its cabal file), with the version its own
    stamp records, since Template Haskell on wasm sees no environment and runs
    no git. The in-memory backend answers `whatsNew` with them and its sessions
    name the newest entry, so the link and its dot work as on a server; an
    export or import of the demo leaves them out, as the application's.
51. **The maker, the toolchain's second stage in Haskell (WP5.68a).** `maker/` is a
    package with a `cabal.project` of its own (`-Werror` for it), on Shake 0.19,
    optparse-applicative and, for `maker-tui`, brick 3.0. `toolchain/pins.env` holds
    the pins and floors as `KEY=VALUE` lines that the shell sources and the maker
    parses. `toolchain/bootstrap.sh` keeps what runs before a GHC exists: the
    read-only modes, the Debian packages, ghcup with GHC and cabal, the Hackage
    mirror and index, `check-native.sh` and `check-tex.sh`, and the deploy's
    `native` and `node` modes in full (so Node's install exists in both stages until
    the deploy moves). For `toolchain`, `build`, `all` and `warm` it builds the maker
    once and execs the binary (`cabal list-bin`, not `cabal run`, so a built maker
    costs no solver pass), passing its state as options and the lock as fd 9. The
    lock is `flock(2)` in both stages, so they exclude each other; the maker makes
    the state directory before taking it. Each component is a phony Shake rule run
    with one thread; the messages are the bootstrap's, word for word.
    `WIKI_MAKER` names a maker built elsewhere, for the bootstrap's tests. The TUI is
    a separate executable because brick's terminal library links libtinfo, which a
    deploy's machine need not have. `sh toolchain/maker.sh status`, `… toolchain
    install TARGET…` and `… tui` run it by hand. The package declares the MIT
    licence and ships its copy, as every package does.
52. **The builds and tests through the maker (WP5.68b).** `maker build
    native|wasm|wasm-opt`, `maker test native|wasm|all`, `maker serve` and `maker
    hspec-halogen` do what the build scripts did, with the same environment
    variables, build directories, messages and cabal cache workarounds; the npm
    scripts keep the readiness check and the locale in `npm-command.sh` and hand
    each command to the maker through `maker.sh`. The native and the wasm build's
    environments are computed once and passed to each tool. In the wasm build the
    JavaScript glue, wasm-opt's output and the islands' bundle are Shake file rules
    kept in `$WASM_BUILDDIR/maker` (Shake's database beside them, per checkout),
    with oracles for the versions of node and wasm-opt and for the binary's path
    and the wasm libdir; the service worker is written again over the page. The
    page is byte for byte the scripts' page; a rebuild with nothing changed takes
    seconds. Processes start through libraries: `typed-process` outside Shake,
    Shake's `cmd` inside its rules (the owner, 2026-11-05), in the first stage's
    modules too. `web/bundle.sh` and `changelog-stamp.sh` stay scripts the maker
    runs, since the deploy's `--bundle-locally` on a `node` machine, the browser
    suite's own bundle, the Dockerfile and the smoke test call them without the
    maker; `dev-test.sh` stays a script (a GHCi loop, not a build).
    `test-wasm.sh`, `run-tests.sh` and `serve-wasm.sh` are gone; `build-wasm.sh`,
    `test-native.sh` and `build-hspec-halogen.sh` are wrappers until (d).
53. **The native build supports GHC 9.10 and later (the owner, 2026-11-05: "cały
    blog ma wspierać dla wersji native ghc od 9.10").** The pins stay the tested
    versions; 9.10 is the floor `--system-tools` takes (decision 48), and CI checks
    it: a job that builds the wiki's packages and the maker with GHC 9.10 on every
    pull request, and the same with 9.12 weekly and by hand.
54. **Two cabal stores in CI, keyed by cabal's version (the owner, 2026-11-05: "jeden
    na native, który pisany jest tylko przez jeden z trzech (np. unit), jeden na wasm,
    osobno dist-newstyles"; #169).** The store keeps each compiler's packages in a
    directory of its own, so a key needs only cabal's version and the runner's OS and
    kind. The native store is saved by the unit job alone, which installs GHC 9.10.3's
    dependencies into it before saving, for `native (GHC 9.10.3)` to restore; the wasm
    store is saved by the wasm job alone, and `server-page.yml` restores it and saves
    nothing (its -O2 dependencies are built on top in each run, on main and tags
    only). The workflow "Delete a cabal store" (by hand) deletes every copy of one,
    under its key and the old ones, for the next run to build again. The build
    directories (`dist-newstyle/...`) stay cached per compiler. The first runs fell
    back on the old keys once; those restore keys go at the next bump of the tag.

55. **The two stages split at GHC (WP5.68 c1, #172; the owner, 2026-11-05).**
    `toolchain/bootstrap.sh` installs only what GHC needs before there is one
    (Debian's `build-essential curl libgmp-dev xz-utils`; elsewhere it checks
    `cc make curl tar xz`), then ghcup with GHC and cabal or checks the machine's
    own, the Hackage mirror and the index, and hands every installing mode but
    `node` to the maker, `native` included. The maker's first target in every
    mode, `system-packages`, installs the builds' Debian packages (git,
    pkg-config, zlib, libsodium, libpq unless `--without-postgres`, ncurses for
    the wizard, and jq, unzip and zstd where the wasm sysroot is set up); in
    `native` it then checks what wiki-server links (`Maker.Check.Native`, also
    `maker check native`), the same check as `toolchain/check-native.sh` word for
    word.

56. **The deploy hands its last part to the maker with a plan (WP5.68 c2a,
    #173; c2c, #175; c2d, #176; c2e, #177).** From the page CI built to the report
    at the end, the deploy is `maker deploy apply --plan FILE` (`Maker.Deploy.*`):
    the page CI built (`Page`: from GitHub with `--backend-only` or from a file
    with `--app-page`, through the page cache, and `--bundle-locally`'s copy of
    it; GitHub's answers read with aeson), the TeX step
    (`Tex`: whether the server can make PDFs, and the offer to install TeX Live,
    with a Perl built first, under the toolchain directory; a TeX Live just
    installed is checked again and kept only when it makes the probe's PDF), the builds and
    the checks of what they made, the service's Node, HTTPS through Tailscale,
    the ports, the adoption into a prefix and PostgreSQL's container
    (`Prepare`), then the change of the running deployment (`Apply`);
    `toolchain/deploy-local.sh` writes every variable that part reads, and every
    key the state file keeps, as `key=value` lines (`MAKER_PLAN_KEYS`) and runs the
    maker with them, through `WIKI_MAKER` or the maker built with its own cabal
    project. The messages, the unit, the state file, the console and the commands
    run are the shell's byte for byte, and `test-deploy-local.sh` runs every case
    with the maker. The plan loses keys as more of the deploy moves. Every deploy
    goes through it (c2b, #174): a demo whose page is not built on the machine
    runs `toolchain/bootstrap.sh static`, which installs GHC and cabal for the
    maker and Node, without the C libraries' packages, the native check or the
    wasm toolchain (`--system-tools` and `--hackage-mirror` as for `native`); a
    `--no-build` deploy on a machine with no cabal stops before anything changes.
    The maker reads and writes everything in one encoding, UTF-8 with ROUNDTRIP,
    set in its `main` for paths, arguments, files and the terminal (c2d): nothing
    a program prints can fail to decode, a byte that is not UTF-8 goes back out
    unchanged, program output is copied to the terminal and the log as bytes
    (`Maker.Process.relay`, `tailLog`), and output read as text is decoded the
    same way (`decodeFs`, with `encodeFs` back to bytes for JSON). Since #183
    the plan file is gone: the Plan is built in memory by the maker's front
    (decision 57).

57. **The deploy's front in the maker; the shell keeps what needs no GHC
    (WP5.68 c2 and d, #183).** `maker deploy [OPTION…]` reads the deploy's
    options (`Maker.Deploy.Options`: a table read in order, with the shell's
    messages; optparse-applicative only for the subcommand), resolves the
    layout (`Maker.Deploy.Layout`) and does the rest of the old front
    (`Maker.Deploy.Front`), the native check and the bootstrap included, then
    the page, the TeX step, the preparation and the change in process;
    `--rollback` too. `toolchain/deploy-local.sh` is stage 1: its option loop,
    the layout, the state reads and the toolchain directory stay in shell for
    `--status`, `--stop` and `--help`, which need no GHC; for everything else
    it finds the maker (through `WIKI_MAKER`, or built with its own cabal
    project, after `toolchain/bootstrap.sh maker` on a machine with no cabal)
    and execs `maker deploy` with its arguments. Stage 1 refuses root and
    claims the prefix directory before the bootstrap. The wizard is the TUI's
    deploy flow (`maker-tui deploy`, `maker/tui/Maker/Tui/Deploy.hs`, its pure
    parts in `Maker.Deploy.Wizard.*`); brick stays in `maker-tui` alone;
    `configure.sh` keeps its check and options and execs it; `configure.hs` is
    gone. `test-deploy-local.sh` stays the black-box oracle of every deploy
    behaviour, unported. Phase (d) moved no script: by the owner's rule
    (2026-11-06, what needs no GHC stays in shell) `check-tex.sh`,
    `changelog-stamp.sh`, `npm-command.sh`, `check-semaphore.sh`,
    `dev-test.sh` and `smoke-test.sh` stay scripts, and "the CI scripts as
    rules" is superseded.

58. **An upgrade is rehearsed on a copy before the deploy switches (WP5.75,
    #206; the owner, 2026-11-09; the design is issue #205).**
    `wiki-server rehearse --old PROGRAM` backs the running wiki up online
    into a scratch place (a directory, and on PostgreSQL a scratch database
    in the same container, `wiki_rehearsal` for the deploy) and restores it
    there. It then deletes the copy's `backup-*` (but `backup-last`) and
    `mail-*` settings, so that neither server started on it backs up to the
    running wiki's destination or sends its mail. The old program serves the
    copy on loopback; each check's `before` reads it through the admin
    listener (an administrator, no sign-in). This program then migrates and
    checks the copy, serves it with `--no-guide`, and each check's `after`
    runs. Exit 0 passed, 6 a check failed, 7 the old program could not be
    driven, 1 the rehearsal broke. A check is a pair of functions in
    `Wiki.Server.Rehearsal.checks`; the first, `pages`, compares every page's
    title and source outside the guide, and leaves out a space whose pages
    answer 404 to the administrator: the container of personal spaces, and a
    personal space its owner hid (#210, after the owner's deploy stopped on
    one). The maker runs it at the start of
    `apply`, before the service stops, for a server-mode upgrade with an old
    program; `--no-rehearsal` skips it (the wizard offers it). CI builds the
    base branch's `wiki-server`, seeds a wiki with it through the admin API
    (`toolchain/rehearse-ci.sh`) and rehearses the upgrade to the pull
    request's build, on SQLite and on PostgreSQL. The second check,
    `accounts` (WP5.74a's, below), signs in a password canary and an
    account through `FakeProvider` made on the old program; a test runs
    every check with this program as old and new (#222). What the checks
    drive on the old program (the `serve` and database options, `users
    add`, the admin listener's `info`, spaces and pages, the provider
    sign-in and its cookies, `session`) is documented as stable and changes
    only compatibly; a new check that drives something else marks it so.
    What a check writes into the copy goes through row types of its own,
    not the live schema, since the copy is at the old program's schema.
    #202's migrations in code are decision 64; each brings its own check.
    **The real accounts (WP5.85, #237, the last part of #205).** The
    check `ways in` compares the old program's `users list` with the new
    one's, and fails for each login that signed in with a password before
    the upgrade and does not after it; `users list` and its table (columns
    padded to their widths in characters, two spaces between, a line break
    in a name counted in the width) are stable for it. Beside it,
    `wiki-server check` refuses a stored password no sign-in can use (half
    an OPAQUE record, a record or stretch that does not decode, a hash the
    verifier does not read), read by the one function the sign-in reads
    the columns with, and a passing check ends by saying how the accounts
    sign in and which enabled ones have no way in (the first twenty by
    login). An account with no way in is never refused: one without a
    password, one from an import and one whose provider was removed are
    legitimate. `wiki-server` writes and reads UTF-8 whatever the locale,
    and the rehearsal gives the old program `LC_ALL=C.UTF-8` when the
    environment has no UTF-8 locale, since a GHC program under `C` dies on
    the first character outside ASCII it prints, a display name included.

59. **A password signs in through OPAQUE (WP5.74a, #184; the owner,
    2026-11-06 to 2026-11-09).** OPAQUE-3DH (RFC 9807) with ristretto255,
    SHA-512 and Argon2id. The server's side is the package `opaque-hs`,
    written over libsodium's primitives. It was `opaque/` in this
    repository and has had a repository of its own since #227 (the owner,
    2026-11-10), [Swordlash/opaque-hs](https://github.com/Swordlash/opaque-hs),
    pinned in `cabal.project` to one commit as haskell-halogen is, and
    bumped the same way. Its tests run there, in its own CI: the RFCs'
    vectors, `@serenity-kit/opaque` under Node, and libopaque with liboprf
    step by step (#212). The wiki's tests of it are the server's own, which
    sign in through its client. The messages are newtypes over their wire
    bytes, read through `HasField` slices, built with one `BS.concat`;
    secrets live in memory libsodium zeroes. The browser's client is
    opaque-hs's `Crypto.OPAQUE.Client` too (WP5.79, #230; the owner,
    2026-11-10; before that the wiki had a binding of its own). On wasm32
    the package is that client alone, and it calls `@serenity-kit/opaque`
    (opaque-ke compiled to wasm, audited), not the package's own protocol
    code built for wasm (the owner, 2026-11-06: libsodium publishes no
    build for wasm32-wasi; opaque-hs can since be built over one compiled
    for it, with its flag `wasm-libsodium`, which the wiki does not use:
    there a secret is zeroed but never locked). The finishing steps in the
    browser are `Crypto.OPAQUE.Client.WebCrypto`'s, which hand the export
    key straight to WebCrypto, for `deriveKey` only and not extractable;
    the page's key registry holds that key, and its bytes never reach the
    program. serenity-kit is pinned in `package.json`, bundled as
    `islands/opaque.js`, and found through `globalThis.opaqueHsSerenity`,
    which `islands.js` sets to its loader, so it is fetched the first time
    a password is used. Over plain HTTP, where a browser has no
    `crypto.subtle`, a sign-in and a new password still work and give no
    key: the owner's production wiki is served that way, and a browser
    test signs in so. Both clients raise Argon2id's parameters to at least
    one pass and 8 KiB, as the server's side does. The context is
    empty, because serenity-kit cannot set one. HKDF comes from libsodium
    1.0.19 or later, built from source by the toolchain
    (`toolchain/libsodium.sh`, the version and checksum in
    `toolchain/pins.env`) and linked into the server statically, so the
    machine it runs on needs no libsodium (WP5.74a2a, #211). Its `.pc` names
    the library `libsodium-static`, which no system library is called, and
    libsodium-bindings finds it through pkg-config, so that a system's
    1.0.18 is never linked. The `older-libsodium` flag (a Haskell HKDF over
    libsodium's HMAC) stays, off, for a build against an old system
    library.
    Argon2id runs with 4 passes and 128 MiB, stored with each record so that
    the defaults can change. An unknown login gets a fake record's answer. An
    account from before OPAQUE signs in the old way once, through a
    fallback the server offers only while such accounts exist, and the
    browser then registers its record; a record is replaced only after a
    proof by OPAQUE. The upgrade's rehearsal (decision 58) checks that an
    account with a password from before OPAQUE, and one through a provider,
    still sign in after the migration (the owner, 2026-11-09).

60. **Each user's keys live in the vault the assistant had (WP5.74b1, #185;
    the owner, 2026-11-06: "as generic as possible, married to what
    exists").** The assistant's vault (WP5.21) becomes the user's vault:
    format 2 seals named items (`assistant`, the old settings; `identity`,
    the user's X25519 private key) and is unlocked by wraps of kinds (one per
    passkey, and a password wrap from HKDF over OPAQUE's `export_key`).
    Format 1 is still read, and an old tab can neither overwrite a format-2
    vault nor delete its key pair. The key pair is made in WebCrypto,
    non-extractable, at the first OPAQUE sign-in. Its public key is in a
    directory any signed-in user reads (`account/public-keys/<user>`), under
    a key id (the first 16 bytes of the public key's SHA-256). A new vault
    gets a password wrap; a vault that opens with a passkey is offered one
    once per device. A password change carries the new wrap in the same
    request. A reset deletes only the password wrap when a passkey still
    opens the vault, and otherwise deletes the vault and retires the key pair
    (`retired_because = 'reset'`). Users who sign in only through a provider
    get keys through a passkey. `@hpke/core` is pinned for b2. As built, by
    the recommendations the owner merged: the vault's routes stay under
    `assistant/vault`; the password wrap is offered once per device; a
    password change over plain HTTP is refused where the vault opens with the
    password; the server does not refuse removing a vault's last passkey.

61. **A private space can be encrypted, its pages kept on the server only as
    ciphertext (WP5.74b2, #209; the owner, 2026-11-09).** A space has a
    random AES-256 key under a 16-byte id (`Space.encryption`), sealed to
    each member with HPKE (X25519, HKDF-SHA256, AES-256-GCM, `@hpke/core`)
    as a `KeyGrant`. Each page has a key of its own, wrapped by the space's
    (`PageKey`). Its title and text are AES-256-GCM with AADs that bind the
    space, the page, the key ids and a random per-version tag
    (`Wiki.Core.Encrypted`). On the server an encrypted page is an ordinary
    row with an empty title and body, its ciphertext in `key_grants`,
    `page_keys` and `sealed_versions` (migration `0011`). So the tree,
    permissions, history and cascades are reused, and no plain read can
    return text. The `encrypted/` routes carry only ciphertext. The plain
    page routes answer 409 for an encrypted space. Only a private space
    with nothing written in it can be encrypted: the generated home page is
    deleted, any other page refuses. It stays encrypted, its slugs are
    random, and the server's search, the whole-wiki export and import, and
    notifications' excerpts leave it out. The browser holds every key as a
    non-extractable WebCrypto handle and decrypts lists, pages, history,
    search hits and stars' titles. Opening a space's key also seals it to
    the readers waiting for it, at most 500 grants a request. Members are
    those the space's own grants let read it. The owner's choices: a space
    administrator, or a global administrator who grants themselves, is
    given the key automatically (the README says so); the writing assistant
    works in encrypted pages as everywhere; removing a member does not
    rotate the key (b3; the dialog warns); mentions in encrypted pages do
    not notify; global administrators are not members unless granted; a
    server that rolls a page back to an older version is not detected (b3
    can chain each version's AAD to the previous one).

62. **No second factor after a provider's sign-in (#199; the owner,
    2026-11-09: "bez opcji").** A sign-in through an external provider
    is complete when the provider confirms who signed in. The wiki asks
    for no code, and there is no setting to make it ask: the provider has
    its own second factor. The second factor stays for a password's
    sign-in. The setting to turn it on is disabled, with a line saying
    why, for an account without a password. Such an account that turned
    it on before keeps the way to turn it off. A linked provider account
    therefore signs in without the code the password asks for, by design.
    Done in #216.

63. **The index is pinned, and the everyday build is unoptimised (#207,
    #220; the owner, 2026-11-09: "pin cabal ma sens").** `cabal.project`
    and `maker/cabal.project` pin `index-state`, so a `cabal update` (the
    bootstrap's, a deploy's) changes no dependency: unpinned, one update
    replaced pandoc, tls, warp and fifty other packages. The pin is bumped
    deliberately, in its own commit, as the haskell-halogen pin. The
    everyday native build (`npm run build-native`, CI's native jobs)
    compiles the wiki's own packages at `-O0`: GHC's timings showed the
    optimiser took most of a full build (397 s at `-O1`, 171 s at `-O0`,
    on four cores), while the tests run about as fast (the database
    groups wait on the database). Optimisation is set per package, in
    `package` stanzas: a top-level `optimization: True` in a file that
    imports `cabal.project` changed the dependencies' hashes. What is
    deployed keeps it: the server at `-O2` (`cabal-native-opt.project`),
    the browser's application at `-O1` and `-O2`. opaque-hs is a
    dependency since #227, so every build compiles it with cabal's default
    optimisation (`-O1`), the everyday one included.

64. **A step of the schema may be Haskell (#202, #222; the owner,
    2026-11-09, with #205's design).** `Wiki.Server.Storage.Migrate.Code`
    holds `CodeStep`s: a number in the same sequence as the SQL files, a
    name, and `run` on the migration's connection. `migrate` applies the
    files and the code steps in the order of their numbers, in one
    transaction, and records each in `wiki_schema` as a file is; a failing
    step undoes the whole pass. The numbers of a database's steps, files
    and code together, must be 1, 2, 3… each once: a program whose steps
    are not refuses to start before touching the database
    (`StepsMisnumbered`), and a unit test checks the program's own, so CI
    catches it (a Template Haskell check would load the whole storage into
    the interpreter on a module recompiled every build). A step never uses
    the live schema (`wikiDb`, `Schema`'s rows, `Rows`): it declares the
    row shapes of its own number, in its own module, and never changes. A
    step that rewrites page syntax carries its own old-to-new rewriter,
    not the live parser. A step whose effect can be checked adds a check
    to `Wiki.Server.Rehearsal.checks`. None exists yet; the first comes
    with #201 (WP5.78), since #195 as built rewrote no page. `knownVersion` (the last step of either kind) is
    the program's schema version for the open check and restore's.

    **A step tells what it did (WP5.87, #242).** `CodeStep.run` returns the
    lines the step has to tell, which `wiki-server migrate` prints and
    `serve` logs as warnings; a step returns them and does not print, since
    its transaction may still roll back. Step 15 makes every login keep
    the rule of a login: one that breaks it (made before 2026-11-06, when
    a login came to be ASCII) becomes `user-` and the first eight ASCII
    letters or digits of the user's id, with an entry in the audit log
    (`user.rename`, address `migration`); the step applies a copy of the
    rule frozen inside it. `wiki-server check` refuses a login that breaks
    the rule, every way a login enters goes through `parseLogin` (the
    provider's first sign-in did not), and the import of a whole wiki
    refuses an archive holding such a login. A renamed user signs in with
    the same password: nothing but the failed sign-ins' limit is keyed by
    the login's text. The owner, 2026-11-10: there are probably none, so
    the step is a safety net and was decided as if there were none.

65. **One marker pair for the wiki's own blocks (WP5.77, #224; the owner,
    2026-11-10, reducing #195).** A block of the wiki's own is
    `[[!name]]{attributes}(Title)` on a line of its own, its blocks, then
    `[[/name]]`: `spoiler` (the only one with a description in
    parentheses), `notes`, `incremental` and `div`. Three are one line
    with no end marker: `[[!slides]]{theme=dark aspect=4:3}`, `[[!pause]]`
    and `[[!toc]]`. The exclamation mark keeps a block apart from a wiki
    link (the owner: every name added later, a plugin's too, would
    otherwise take a page's name from `[[page]]`): a page's address cannot
    hold one, so `[[!notes]]` is never a link and `[[notes]]` always is.
    It reads as a box's marker does, `> [!NOTE]`. Braces hold pandoc's
    attributes (`#id`, `.class`, `key=value`), read by
    commonmark-extensions' own reader, as a fence's and a heading's are. A
    spoiler's name is `{answer}` or `{#answer}`, a name and not an HTML
    id; the name in an end marker is optional. An end marker ends the
    innermost open block of its name; with no block of that name open it
    is the text it is. `:::`, `. . .`, `[[spoiler]]` and `[[toc]]` without
    the mark are no longer read, on the page or in an export, and no
    stored page was rewritten: nobody used them in production. The AST
    keeps `Div`, `Pause` and `TableOfContents`; `markerOpening`,
    `openingMarker` and `closingMarker` in `Wiki.Core.Markdown.Ast` are
    the one place that spells a marker. In the export pandoc reads no
    fenced div: each marker line is a placeholder paragraph that
    `markedBlocks` folds into a div or a pause after pandoc has read the
    page. Boxes stay `> [!KIND]`. Left for later: `[[!box]]{.warning}`
    and kinds of box with a look given on the page, and completion after
    `[[`, `[[!` and `{` (#187). Comments (`<!-- … -->`) already worked
    (#197); the reference has a section on them.

66. **A database is copied to the other backend in one transaction of the
    target (WP5.80a, #203, #232; the owner, 2026-11-10).**
    `wiki-server copy-database --data DIR [DATABASE] (--to-database URL
    [--to-database-password-file FILE] | --to-sqlite FILE)` copies a wiki's
    whole database into an empty one, in either direction
    (`Wiki.Server.Storage.Copy`). The source is read in one read
    transaction and never written. The target is written in one: the
    schema by this program's own steps (`migrateWithin`), every table's
    rows, the counters behind generated ids, then the checks (each table's
    row count and an order-free digest of its rows against the source's,
    and the database check `wiki-server check` runs), and only then the
    commit; a failure leaves the target empty. The list of tables,
    `copiedTables`, is written by hand in an order that writes a row after
    the rows it refers to; a table the list lacks is refused before
    anything is written, and a test compares the list with the tables a
    migrated database holds, so a package that adds a table adds it there
    (a `Copyable` instance and a place in the list). A row the target
    refuses is named by its table and primary key, never by its other
    columns. `--to-sqlite` makes a new file exclusively and deletes, on
    failure, only that file. Exit 0 copied and checked, 4 the source is at
    another schema version, 5 the source does not read whole, 6 refused
    before anything was written, 1 the copy failed and the target is as it
    was. CPP sits only in `Wiki.Server.CopyDatabase`, where it opens
    PostgreSQL (decision 34).

67. **The deploy moves a wiki from SQLite to PostgreSQL, and a move that
    fails loses nothing (WP5.80b, #203, #233; the owner, 2026-11-10).**
    `sh toolchain/deploy-local.sh --move-to-postgres` (`Maker.Deploy.Move`,
    offered by the wizard) works on a server this script deployed in
    SQLite, at the checkout's commit. It builds the server with the
    `postgres` flag, looks at PostgreSQL before it writes anything (a
    container on another port than `--db-port`, or a database that holds a
    wiki, is refused untouched), stops the service, backs up, runs
    `wiki-server copy-database` (decision 66), compares the wiki before and
    after with the rehearsal's checks, switches and starts. The comparison
    is `wiki-server rehearse --move-to-database`, on scratch copies and not
    on the database the move filled, since the checks write; the copy
    verifies the filled database itself. The invariant: after a move that
    did not succeed, either the service runs on exactly the SQLite
    database the move began with, or it is stopped and every copy is
    still there (the SQLite files, in `data/` or set aside in
    `data/replaced/<time>/`; the deployment in `previous/`; the copy in
    PostgreSQL), and `--rollback --yes` finishes. Five rounds of review
    each found one more way a failure broke that, so it now holds by
    construction, and a package that changes the move keeps these: the
    journal notes each step of the switch before its first operation, and
    each undo is right for none, some or all of the step; the switch back
    restores in one phase and deletes what it saved in a second, in one
    function (`discardSaved`), only when all of the first succeeded; it
    starts SQLite and empties PostgreSQL only when `data/` holds the bytes
    recorded by SHA-256 at the switch; it puts nothing back until systemd
    says the service is inactive; from its first write to its end the move
    is one guarded stretch; and every file operation and command goes
    through `Maker.Deploy.Operations`, whose counter the tests drive
    (`WIKI_TEST_MOVE_FAILPOINT`): `toolchain/test-deploy-local.sh` fails
    each operation once, 76 of them, asserts the invariant, and checks
    `Move.hs`'s source for an operation done any other way. The SQLite
    file is never deleted.

68. **A space's home page is the root of its pages (WP5.78, #201, #225 and
    #229; the owner, 2026-11-10).** Every space has one home page, the
    page it opens at, and every other page is under it. Only a space
    administrator changes it (`Wiki.Core.Permission.canEditPage`), and it
    cannot be chosen, deleted, moved or made a template. Two kinds of
    space have none and keep several top-level pages, each with its
    segment: the container of personal spaces, and an encrypted space
    (until #213). Step 12 of the schema gave every other space with none
    the default one; step 13 made each home page its space's only
    top-level page (`Storage.Migrate.Code.Step0012`, `Step0013`), and the
    storage refuses a second root, which `wiki-server check` reports. The
    home page has no segment in addresses: a space's address is its home
    page's, a page that was top-level kept its address, and a page that
    was under the home page lost the home page's segment.
    `Wiki.Core.Space.pagePath` is the one function that builds a page's
    path and `pagesAt` the one that reads one; the home page's editor,
    source, history, slides and live preview are under the space's
    address. An address of the time before is read again without the
    home page's slug when it names nothing as written, but only where a
    person typed or wrote it (reading a page, the shell's current page,
    links): whatever matches or compares pages (the merge import, the
    guide's update) reads paths exactly (`pageAtExactly`), since the
    first review found an import overwriting a home page through the old
    address. A blog shows its posts at its address, with its home page
    above them through the page view itself, comments and all, once
    someone has written it or commented on it; a home page nobody has
    written stays hidden, and commenting on it, watching, starring and
    exporting it are not offered until then (the owner, 2026-11-10: left
    so). An archive's layout follows the tree, a page that was top-level
    under its home page's directory, and an old archive is read by step
    13's rule (`rootedPages`). The rehearsal builds each path as the
    program it asks builds it, told by the schema version on `/healthz`,
    which is stable; its `roots` check is step 13's.
69. **Plugins: one interface, built-in plugins in the page and external
    ones in a sandboxed frame (#186; the owner, 2026-11-10).** The plan is
    the session's first comment on #186, and the owner's answers the same
    day settle its six questions. A plugin is a manifest (id, name,
    version, the API version it speaks, what it contributes, its options,
    the permissions it asks for) and code. The application has one small
    interface for each thing a plugin can contribute. A built-in plugin is
    Haskell compiled into the application, trusted, and implements the
    interface as Haskell values. An external plugin implements the same
    interface over versioned JSON messages, and runs in an
    `<iframe sandbox="allow-scripts">` without `allow-same-origin`: an
    origin of its own, so no cookie, no storage of the wiki's, no key and
    no DOM of the page; it talks with `postMessage` to a bridge that
    answers only what the plugin was granted, and a Content-Security-Policy
    on the frame closes its network but for the hosts its manifest names
    and the user approved. A sandboxed frame needs no secure context, so
    this works over plain HTTP. The answers: (1) the wiki's administrator
    turns external plugins on and may install some for everyone, and a user
    may add their own, with a warning before an external one is added;
    (2) a user may turn a built-in plugin off, and the administrator may
    turn one off for the whole wiki; (3) the first package is the interface
    and the two built-in plugins, with no external code; (4) a plugin's
    options are kept per user on the server in the clear, and its secrets
    (an assistant's API key) in the vault; (5) an external plugin's code is
    an uploaded bundle, kept by the server and pinned by its hash, before
    any loading from a URL; (6) a plugin sees only the page being edited,
    and only while its editor is open, and anything more is a permission of
    its own, which may be as fine as a contribution needs. The packages are
    under "Open work". **The interface is also how the code is cut into
    modules (the owner, 2026-11-11: "I would like to modularise the code
    a little through these plugins").** A built-in plugin imports the
    plugins' interface and nothing of the application's inside, kept by a
    test of the imports at first (`Wiki.App.Plugin.*`) and by packages of
    their own once the interface has settled. After the assistant and the
    errors, the features that go behind it, one a package and none
    changing what it does: the emoji picker, the islands (Mermaid, TikZ,
    the `html` frame), presentations, table views (#190); the calendar of
    #204 is the first plugin written as one from the start. **The shape
    of the interface (the owner, 2026-11-11; thinking only, the epic is
    built last; the whole is the session's second comment on #186).** A
    contribution is what a plugin gives the wiki, a capability what it
    may ask of the host and a permission in its manifest, a surface a
    rectangle it draws itself: a Halogen component for a built-in plugin,
    a frame for an external one. Buttons, the assistants' floating ones
    included, entries and marks are data the host draws. The same names
    are Haskell calls and `postMessage` messages; a plugin gets a record
    of capabilities, not the application's classes. Contributions:
    `diagnostics`, `agent`, `command`, `completion`, `block`, `pageKind`,
    `pageAction`, `sidebar`, `options`. A built-in plugin may have a
    server half under `/api/v1/plugins/<id>/`; an external one gets a
    generic store of JSON documents by user or by page. A kind of page is
    an explicit property chosen when the page is made; presentations
    become one with #191, before the plugins. An external plugin's block
    is in a frame of its own. The API is frozen when the first external
    plugin ships, not before.
70. **A permanent link is a page by its id, pinned to a version (WP5.81,
    #194, #235; the owner, 2026-11-10).** The owner's meaning of the issue:
    a link to the page as it was when the link was made ("link +
    &version=8"), not only a link that survives a move. "Copy permanent
    link" among a page's actions copies `/l/<page id>/?version=<time>`,
    and is the one thing in the interface that writes the form; the wiki's
    front page does not offer it, since it has no address for a version.
    A version is named by the time it was saved, as in the history's
    address: there are no version numbers. The page's own address takes
    `?version=` too (`PageAtVersion`) and shows that version as a page,
    with a note saying which it is and a link to the page as it is now,
    and without editing, comments or the live channel; the history links
    to it ("Read this version"). `/l/<page id>/` without a version leads
    to the page as it is now, wherever it has moved. The server answers a
    permanent address with a 302 when the session may view the page, and
    otherwise prerenders it as any address that names nothing; the
    application, reading the route itself, asks where the page is
    (`MonadWiki.pageLocation`, `GET api/v1/pages/<id>/location`) and
    replaces the address, fragment and history entry's number kept. The
    read by id answers a page its reader may not view exactly as an id no
    page has. An id is any text: nothing parses one, and a segment that
    would be empty, `.`, `..` or start with `~` is written with a `~`
    before it. `Wiki.Core.Markdown.Link.classifyDestination` reads the
    form (`ToPageId`), for the resolver, the exports and the packages
    after (#189, #187); a link by id to a page the browser does not hold
    is a link all the same, never shown as unresolved. The session had
    first read the issue as a link that survives a move and proposed a
    second package, a quote found again after edits; the owner dropped it.
71. **Backlinks are the links as they lead now, kept in a table the
    program fills (WP5.88, #189, #239; the owner, 2026-11-11: a list in
    the left panel, counted when a page is saved, no graph).** Each page
    lists the pages that link to it, "Linked from", below the space's
    pages. A link counts as the page view follows it: one function reads
    a destination (`Wiki.App.Route.readLink`), and both the resolver and
    the name a link is kept under come from that reading, since two
    readings disagreed once (a percent-encoded address) and the list went
    stale. `Wiki.Core.Markdown.Render.linkDestinations` extracts a text's
    links and matches every block and inline constructor by name, so a
    new one does not compile until someone decides for it; an `html`
    block, code, mathematics and diagrams contribute none. The server
    keeps a row per link (`page_links`, step 14: the destination as
    written, its name, the page it leads to now, a flag `pending`),
    written by the only two writers of a page's text; a change to the
    tree marks the rows it can affect, and the end of every write
    transaction resolves them again without parsing Markdown. What the
    server answers must equal resolving now: the demo has no table and
    resolves each time, and the contract suite runs both. The list holds
    only sources the reader may view, with no count of the others, and a
    path from the top that a hidden space would catch is resolved again
    among the reader's spaces. No code step fills the table: a step must
    mean the same whatever the parser becomes (decision 64), so step 14
    makes the table empty and the program fills it when the setting
    `links-version` is not its own, at `migrate` and at opening the
    storage; a change to how links are read bumps the version. The front
    page is neither a source nor a target, and an encrypted space's pages
    have no list and are in none.
72. **An `html` fence is rendered in a frame that runs no script; derived
    data is made again by a version stamp (WP5.89, #196, #238; the owner,
    2026-11-11).** A fenced block `html` is shown with the author's own
    CSS (a `style` attribute, `<style>` elements) in an `<iframe>` whose
    document is the block, so no style of it reaches the wiki around it;
    the owner chose the frame over a filter of CSS in the page. The
    block's HTML goes through the allowlist of decision 13, widened by
    styles only, and the frame's sandbox never has `allow-scripts`. It has
    the wiki's origin (`allow-same-origin`): Chromium, tried before the
    design, cannot measure the content's height or load a private space's
    attachment without it, and it is safe only because nothing in the
    frame runs. `Wiki.Core.Markdown.Frame` holds the two sandboxes, this
    one and the one kept for a frame that runs scripts (#200, then the
    plugins: scripts, never the wiki's origin), and a test that no
    sandbox has both. A `srcdoc` frame loads under the page's policy with
    no `frame-src`, so the policy is unchanged. The frame's document is
    the wiki's stylesheet in a cascade layer, then the block: the wiki's
    classes look as in the page, in the page's colours or the slide's,
    and any rule of the author's wins. The height: `{height=N}` on the
    fence sets it; a block with anything placed `fixed` is shown at the
    cap, 80% of the window's height; otherwise an estimate taken with the
    frame at its cap (so `vh` inside means the frame at its largest), then
    a check that grows the frame while its document has more to scroll
    to; after any fit the document does not overflow the frame or the
    frame is at its cap. A fence `latex` is display mathematics, as `$$`
    is (the owner); `{.norender}` on a fence that would be rendered shows
    it as a listing. A page that had an `html` or `latex` listing shows it
    rendered (the owner: no migration). Raw HTML, in the page and in the
    frame, is read as a browser reads it: the content of `style`,
    `script`, `textarea` and the other raw-text elements is cut out by
    the browser's rule before tagsoup, in linear time, with elements
    nested 512 deep at most. **Derived data and its version.** What is
    made from a page's text and stored is made again by the program when
    a version stamped in the settings is not its own, at `migrate` and at
    opening the storage, and not by a code step: the links (decision 71,
    `links-version`) and now the search text (`search-version`, beside
    `Wiki.Core.Search.bodyText`). A change to how either is read bumps
    its version.
73. **An interactive SVG runs in a frame without the wiki's origin, and
    only a frame gets it (WP5.90, #200, #249; the owner, 2026-11-11: only
    when asked for).** `![flame](attachment:flame.svg){.interactive}`
    shows an SVG attachment in an `<iframe sandbox="allow-scripts">`
    (`scriptSandbox`, which the plugins' frames of decision 69 will have
    too) that loads the attachment's interactive form, its own address
    with `?interactive`; without the class an SVG stays an `<img>`. The
    server answers the interactive form only for an attachment stored as
    `image/svg+xml`, under `interactiveSvgPolicy`: `sandbox allow-scripts`
    again, `default-src 'none'`, inline scripts and styles, `data:`
    images, `frame-ancestors 'self'`. So the SVG's scripts have an opaque
    origin (no cookie, no storage, no way into the page), no fetch, XHR,
    beacon or WebSocket, no tab, dialog or form. The session's cookie
    reaches the frame's first load, so a private space's SVG loads (tried
    in Chromium before the design). **Only a frame gets it**: the answer
    is given only to a request with `Sec-Fetch-Dest: iframe`, and
    anything else asking with `?interactive` (a tab, an `<img>`, a
    request without the header) gets the plain answer, a download;
    otherwise anyone who may upload an SVG could hand out a scripted
    page under the wiki's host name. The two answers of one address
    carry `Vary: Sec-Fetch-Dest` and tags of their own. The page's
    policy gains `frame-src 'self'`, not narrowed to the attachments'
    path (`'self'` takes no path, and the origin written into every
    page's policy would break behind a proxy that rewrites the host).
    The frame is an island whose `src` the island sets, since setting a
    frame's `src` again loads it again. The embed is a frame only where
    the frame's load can reach the server: a secure context (Chromium
    sends `Sec-Fetch-Dest` to no other), the browser online, the page
    not the copy the service worker kept; and not inside a link.
    Elsewhere, and in the demo, feeds and exports, it is the image. The
    smoke test's part 9 tries each claim in Chromium against the real
    server with a hostile SVG.
74. **A task is ticked in the page, and ticks are saved together
    (WP5.91, #204, #243; the owner, 2026-11-11).** Whoever may edit a
    page ticks its tasks (`- [ ]`, the syntax kept) in the page view. A
    tick does not save: the ticks are staged in the view, with a bar
    saying how many and "Save" and "Discard", and a save writes one
    version (the owner: staging as in the editor, since a version is a
    whole copy). One pure function in wiki-core turns the text and the
    ticks into the new text, changing nothing but the boxes
    (`Wiki.Core.Markdown.Tasks`); a parent's and its children's boxes
    follow each other; `{.sorted}` on the line before a list shows its
    ticked tasks last, in the view only. The ticks live in one pure state
    machine (`Wiki.App.View.Ticking`): they leave it only through a save
    of this visit, Discard, a Leave the reader confirmed, a reload the
    reader asked for, or the right to edit lost. The rules the thirteen
    review rounds left, each closing a class rather than a case: every
    asynchronous answer carries its visit's number and a save's its own;
    while any write of the page the view started is out (rename, move,
    delete, the template switch, the ticks' save) the boxes are disabled
    and no form opens or closes; the boxes' state reads nothing that
    `Initialize` sets, so the server's page and the program's first
    render draw the same boxes; the view never replaces the page it
    shows with an older version of it (`takesPage`); the shell and the
    blog keep what they show when a reload fails under unsaved changes.
    A line of attributes before a list now makes a `Div` around it, as
    pandoc reads it, and the parser says which block took a line's
    attributes.
75. **No script or test chooses a port by number (WP5.94, #244; the
    owner, 2026-11-11).** Wherever one needs a port, the system or Docker
    chooses it and the script reads it back: Docker's `--publish
    127.0.0.1::5432` with `docker port`, the server's `--listen
    127.0.0.1:0` with the address it logs (`event=listening`), a socket
    bound to port 0. `toolchain/ci-postgres.sh start` leaves a running
    container as it is and takes a lock, so agents that share it by name
    read its port and never restart it; each run of the PostgreSQL tests
    has databases of its own name, swept after six hours. A deployment's
    own ports stay what the operator sets.
76. **Encrypted spaces: a version chain, key renewal, comments,
    attachments and subspaces (WP5.74b3's first part, #213, #251; the
    owner asleep while it was designed, his word that it merges in
    parts, 2026-11-12).** **Rollback.** Each version of an encrypted page
    carries its number and the tag of the version before, bound into its
    AAD (`wiki-page/2`, step 16); the browser remembers the latest
    version it read of each page, and accepts a later one only through
    an unbroken, authenticated run of history from that very version
    down to the one remembered. Detected: an older latest version,
    another under the same number, a later one its history does not
    join, a version missing or out of order. Not detected: an old
    version served to a browser that never read the page, a page hidden,
    comments and attachments served as before. **Renewal.** A space's
    key must be renewed when anyone holding a grant of it can no longer
    read the space or has another key pair (`Wiki.Server.Storage.Renewal`);
    until then sealed writes are refused, saying why. Only someone who
    may administer the space and holds the key renews (the server cannot
    check that a wrap opens, so a reader's renewal could destroy the
    space); that browser renews when it opens the space, and at once
    after its own removal of a reader. A renewal re-wraps every page key
    under the new space key, gives each page a new current page key, and
    deletes the older grants (step 17); the browser opens every new wrap
    from the bytes it sends before sending. **A ciphertext is opened with
    the key its own key id names**, never "the current key". **Comments
    and attachments** are ciphertext under the page's key, each kind with
    an AAD of its own, in side tables (step 18); an encrypted attachment
    is shown from an object URL that belongs to the view showing it, and
    an SVG's link downloads it. **Subspaces and home pages.** Every space
    below an encrypted space is encrypted, with a key of its own sealed
    to its own readers, and an encrypted space shares its readers only
    with encrypted spaces that are not public
    (`Wiki.Core.Permission.encryptionProblem`, checked on the result of
    every write that could break it); every encrypted space has a sealed
    home page, made by the browser. **Each sealed route asks for exactly
    what its plain counterpart asks**, by the same named function. A
    database whose recorded schema steps have a hole is refused, naming
    the step. The canary (wiki-smoke's `Server.Canary` since #267)
    writes a marker into each protected place through the browser
    against a real server and looks for it in every file of the data
    directory, a dump of PostgreSQL, and every request, answer and
    WebSocket frame (the answers by asking each GET again with the
    browser's session, since the driver gives no response bodies; the
    answers to the browsers' own writes are not read).
77. **A page has a kind: a document or a presentation (WP5.97, #191,
    #253; the owner's answers of 2026-11-11, the rest decided while he
    slept).** The kind is a column of the page (step 19, no `CHECK`:
    plugins will bring kinds; one this program does not know is kept and
    shown as a document), not part of a version: changing it is not a
    save. In an encrypted space it is in the clear. Wherever two pages
    are compared (an import, the guide's update), the kind is part of the
    page. "New page" asks the kind first, then what to start from; a
    space's home page is always a document. **Syntax.** The parser does
    not know the kind; the kind decides how a page is shown. In a
    presentation every top-level heading of level 1 or 2 opens a slide
    (`#` a title slide), `---` is a rule on its slide, the look is one
    line `[[!style]]{theme=… aspect=…}`, `[[!pause]]` is read on a line
    of its own (in a quotation too) and among a paragraph's words, where
    Beamer's `\pause` works (not in a table cell, a heading, emphasis or
    a link: the wiki's rule), and `{.incremental}` on the line before a
    list steps through it. A marker a page's kind does not read is a
    warning in the editor. What "top level" is for slides is defined
    once, and the cutting, the warnings and the editor's slides read it.
    **The editor** has two modes over the same Markdown for a
    presentation: raw, and slide by slide. Slide by slide is a list of
    rows drawn by Halogen, one a slide, each a card: its header holds
    a handle, a chevron, the number, the title, the problems' count,
    the fit and a delete; an open row holds a CodeMirror over that
    slide's Markdown, and several may be open (#259, after the owner
    used #253's one editor with folds: "raczej jako listę rozwijalnych
    wierszy z których każda ma osobny edytor"). Raw's CodeMirror stays
    mounted, hidden: the master. It holds the whole text, the one undo
    history, the problems and the assistant's tracked changes; a row is
    a view over a range of it that forwards every transaction, and the
    master mirrors into the rows what they did not make. The invariant,
    held in the master's one update listener: the focused row's
    selection is the master's; any other change either brings the
    row's selection along or moves the focus to the cursor's row,
    opening it, and after an undo, a redo or "next problem" the row
    left closes. A move, a delete and a new slide are entries of the
    same history, with the rows' layout and keys. Where the text is
    cut is `Wiki.Core.SlideRows`: a row starts at a slide's heading,
    the line break before it belongs to no row, and after an edit only
    the changed rows are cut again, each on its own text, so that a
    block left open in one row does not take the rows below (they are
    marked "part of slide N", and the slide that swallows them gets a
    problem). Whatever a row decides from text (may a completion open
    here) it asks of the whole document. **The search** (#263) is the
    wiki's own, over the whole text, in Raw, in a document and slide by
    slide: a panel above the text (query, case, regular expression,
    whole word, a count, steps, Replace and Replace all), opened by
    Ctrl+F from anywhere in the editor; the browser's find stays in the
    browser's menu. One sequence of matches (`eachMatch`) serves the
    count, the marks, the steps and both replacements; a match that
    starts in a titled page's guarded `# ` is not one; a step opens the
    row a match starts in and closes none; Replace all is one step of
    the history. Its state lives in the editor component, so a reload
    keeps it. The preview renders the whole
    deck as one document and shows the card asked for. **Overflow.** Every slide is laid out
    1024 px wide and measured against its own box, heading included,
    with nothing that depends on the window taking part: fits, yellow
    (less than half a line to spare up to one line cut) or red, grey
    while not measured; the promise is for a projector at least that
    wide. The room is counted down to the bottom of the body's padding,
    the edge where the body cuts its text and the slides view counts a
    cut from (#258: counted to the content edge, 0.57 line higher, the
    mark was yellow on a slide with 0.78 line to spare). **Embedding.** `![Caption](page){.presentation}` is the link
    until it comes near the window in a browser, then a viewer of the
    slides, drawn in the page; the server's render and adoption ask for
    nothing. What a viewer shows belongs to one reader at one revision
    and is dropped when either changes; its ids and fragment links live
    under a prefix of its own. A presentation's page shows its viewer
    above the page as a document. A document's address of slides shows a
    note with a link.
78. **"What's new?" leaves technical changelog entries out (WP5.99,
    #254; the owner, 2026-11-12).** The page is for what makes someone
    using the wiki in a browser think "a new feature, I will try it" or
    "that bug is fixed now". An entry that gives neither thought carries
    `technical: true` in its front matter: nothing of it is seen on the
    wiki's pages (CI, tests, build and deploy scripts, the console,
    upgrades, dependencies). A technical entry is still required and
    checked, and is not compiled into the programs: it is not shown, not
    counted among the newest twelve, and never lights the link's dot. The
    session marks its own entry by that rule (`AGENTS.md`). The owner was
    offered leaving them out or showing them as one line marked
    technical; this leaves them out.
79. **The server links the system's SQLite; its SHA-256 is crypton's; no
    constraint holds network back (WP5.100, #256; the owner,
    2026-11-12, after an audit of the transitive dependencies).**
    `direct-sqlite` is built with `systemlib`: the copy it bundles was
    SQLite 3.45.0 of January 2024, with no release since, and a
    distribution keeps its SQLite patched. So each machine runs its own
    SQLite, the machine that builds the server needs SQLite's
    development files, and the server refuses, before opening any file,
    a library older than 3.32.0 (upsert, `VACUUM INTO`, more than 999
    parameters in a statement) or built without threads, the write-ahead
    log or foreign keys (`Wiki.Server.Storage.SqliteLibrary`); it says
    which SQLite it runs on at start and in `wiki-server check`. The
    library is judged twice before a deploy changes anything (#257):
    `toolchain/check-native.sh` and the maker's `check native` build and
    run a probe and judge the library it loads by the server's own
    rules, naming its file and the header's version when the two
    differ (the floors are in `toolchain/pins.env` and in
    `SqliteLibrary.hs`, and the maker's tests hold them equal); and the
    deploy runs the new server's `wiki-server sqlite` in the service's
    environment (the systemd user manager's, read back through
    systemd's own quoting, with the unit's `Environment=` lines over
    it, the copied `LD_LIBRARY_PATH` among them) before the rehearsal,
    so with `--no-rehearsal` too: a server that does not start there
    stops the deploy, and so does a refused library for a wiki in
    SQLite; for one in PostgreSQL a refusal is a warning. SHA-256
    goes through one module, `Wiki.Server.Sha256`, over crypton; the
    stored digests (a blob's id, a session id's hash, a vault key's id,
    the guide's record) are pinned by constants the earlier library
    computed. `constraints: network < 3.2.10` is gone and
    `wiki-server.cabal` asks for warp 3.4.19, warp-tls 3.4.16 and
    smtp-mail 0.5.0.2 or later: an HTTP/1.1 request without a `Host`
    header, or any with two, is answered 400.

80. **Encrypted spaces, the second part (#255, issue #213 closed).**
    On decision 76. **Export.** "Export, decrypted here" is made in the
    browser of any reader who holds the key: a space-only archive in
    the wiki's own format (latest titles and texts, attachments,
    comments with their authors' names; no versions, users or grants),
    zipped, read back and compared before the file is handed over; not
    offered during a conversion. **Conversion.** A space with pages is
    encrypted, and encryption turned off, page by page by the browser
    of an administrator who holds the key: it stages a page's
    ciphertext (every version as a chain, comments, attachments), reads
    the staging back and opens it, and commits with the server's digest
    of what is staged, which names each blob's hash and size. One
    browser converts at a time: the server holds a lease (holder, token,
    expiry; step 23) required on every stage, upload, read-back and
    commit; "Take over here" is the same user's way to take it. A
    conversion can be stopped and turned back. It is finished only once
    SQLite's truncating checkpoint has run after its last commit, tried
    without waiting and owed after every write and at start when a
    reader holds it back (`clearing`); on PostgreSQL the plain text is
    gone only once the database is vacuumed, which the dialog and the
    README say. A conversion that ends as plain writes every page's
    links again. **Chains.** A chain of versions carries an origin, a
    random id bound in every version's encryption (`wiki-page/3`, step
    22): a page encrypted again starts a new chain, which a browser
    accepts; an earlier chain shown again is `Superseded`, a history
    whose oldest version is not a chain's first is `Truncated`; export
    and decryption check head, links and start through one function
    (`pageTrusted`) before anything is written. **The gate.** A space's
    administrators may have it ask for a passkey or the password each
    time it is opened (step 21; every way the vault unlocks is
    offered). The gate is the interface's, not the encryption's: behind
    a gate not confirmed in this tab nothing of the space is decrypted,
    read by a plain route or shown, a decryption's result is given back
    only if the reader and the gate are as they were when it started,
    and on leaving, at a sign-out here or in another tab and at the
    session's end what is shown of an encrypted space, the tab's title
    included, is taken off the screen before any request is made
    (`sealScreen`); unsaved changes to an encrypted page are dropped
    then and said so. Signing out removes the user's vault key and
    private key from the device and the other tabs; a page that starts
    with nobody signed in drops every user's. **Titles.** The bell and
    the stars show a decrypted title only through the gate, from one
    request for headings by ids (`POST encrypted/headings`); mentions
    in an encrypted space are named from the space's readers, asked for
    by the space's id. **What is offered.** One rule, `Wiki.Core.Offered`,
    for the server's refusals and the interface's controls. **A tab
    left behind.** The server's refusals that mean "the space is not in
    the state you believe" carry a code (409 `Stale`); a tab that gets
    one reads the spaces again and sends a read once more by the right
    route, learning a page encrypted since first; a write is never sent
    again. Steps 20 to 23. Ten Codex rounds were started and nine
    finished (5, 3, 4, 3, 3, 1, 1, 2, 1 findings, all fixed); the owner
    merged before the tenth.

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
components with class constraints, `RefLabel`s from `newRefLabel`, one changelog
entry per pull request under `changelog/`. The packages' `CHANGELOG.md` files are
frozen (the owner, 2026-11-11, #245): two open pull requests collided in them every
time, and the entries under `changelog/` say the same in finer grain.

## How work is organised

The session the owner talks to owns the work, one package at a time. Who writes the
code depends on the session's model, as `AGENTS.md` says (the owner, 2026-11-03,
confirmed 2026-11-10; before that the session implemented everything itself): a
session on Fable plans, briefs and reviews, and one Opus subagent in a worktree of
its own implements each package; a session on another model implements itself.
Before a pull request merges, it is reviewed by Codex, as `AGENTS.md` says: the
session runs the Codex CLI on the pushed head, `gpt-6.1-sol` at high reasoning
effort, and when its quota has run out asks the GitHub Codex bot instead, with a
comment of `@codex review` on the pull request (the owner, 2026-11-10: the CLI is
the default; on the owner's machine it is signed in with the owner's account, so
there is no key to give and no credential to remove). The session fixes the real findings and pushes, for about three rounds
(the owner, 2026-11-02: "Zmniejsz max liczbe przebiegów do 3"; four before). Three
is a rule of thumb (the owner, 2026-11-10): when the third round finds only
trifles, they may be left, and said so in the pull request; when it still finds
something serious, or the same kind of mistake in another place, the rounds go on.
A session on Fable reviews the subagent's branch itself first, before the pull
request is opened, so each package has two reviews, the session's and Codex's (the
owner, the same day). The owner merges; the session
merges only when asked ("nie merguj sam, chyba że poproszę"). When the owner says to
merge a pull request as it is, without waiting for its checks, the session merges it
past the branch's rules (`gh pr merge --admin`; the owner, 2026-11-10).

Pull requests that are open together and touch common files are stacked, each on the
branch of the one before (the owner, 2026-11-11; `AGENTS.md` has the rule, #246 made
CI run for a pull request whatever its base). GitHub knows such a chain as a stack,
and merges it by its own rules, learned on the first one (#247 to #249, 2026-11-11):
`gh pr merge` refuses a stacked pull request; the merge is
`PUT /repos/{owner}/{repo}/pulls/{n}/merge-async` with `merge_method`, `merge_action:
direct_merge` and `bypass_rules: true`; the rules can be bypassed only for the lowest
pull request not yet merged, so a stack is merged from the bottom, one request each;
and after each merge GitHub rebases the branches above onto `main` itself, which
changes their heads and starts their CI again, but no file of their trees (checked on
each). The owner could not merge the stack in the web page for the required reviews,
and had the session do it.

The gate runs on CI, not on the machine (the owner, 2026-11-10; before that a
package's whole gate was run locally first). All of CI runs on GitHub's runners
since #228: the repository variable `WASM_RUNNER` is `hosted`, so the wasm job no
longer shares the owner's machine with the sessions, where the two slowed each
other down. Locally a package owes the type-check (`npm run build-native`, and
`npm run build-wasm` where it changed code only wasm compiles), the formatter, and
whichever test suites its author judges worth running before the push; the pull
request is opened then, and CI's run on its head is the gate. A package's local
gate, run one suite after another on a machine other builds share, took 30 to 40
minutes; CI's jobs run side by side in about 12.

A work package starts from its text under "Open work", the decisions it builds on and
the haskell-halogen modules it uses, and ends with the verification gate of `AGENTS.md`
and one pull request ready for review, whose description says what was built, the
choices made, and what differs from the plan. When it merges, the plan changes only
where something stays true afterwards: the package leaves "Open work", a decision taken
or changed goes under "Decisions", and what the package could not do or found and left
goes under "Known gaps and notes" (the owner, 2026-10-31: the plan keeps decisions and
what is planned, not a log).

## Open work

In the order to do it, unless the owner says otherwise.

**The issues' order (the owner, 2026-11-09).** Stage 0 is done: #192
(menus close on a click away, #219), #193 (the draft's "saved" as a notice
that moves no button, #217), #199 (decision 62, #216), #214 (libsodium
from a local file, #215) and WP5.76 (#218); #198 was closed as already
done. Stage 1,
foundations, is done: #207 (compile times, #220, decision 63), #202
(migrations in code, with the rest of #205: #222, decisions 58 and 64),
and the PostgreSQL tests copying a migrated template (#221). Stage 2,
the content's structure, on #202: #195 is done (decision 65, #224) and
#197 was closed, since comments worked already; #201 (one home page per
space, the root of its pages) is done (decision 68, #225 and #229). So
stage 2 is done.

**The smaller issues first (the owner, 2026-11-10, in the evening):** the
smaller issues are closed before plugins (#186), autocompletion (#187)
and presentations (#191) are started. In this order: #194 (persistent
links, done: decision 70, #235); #205's last part (done: WP5.85, #237,
decision 58); #188 (emojis: the
done and closed: WP5.86, #236; the owner, 2026-11-11: Slack's names that
GitHub's list does not have are not needed); #189 (backlinks, done: decision 71, #239); #196 (done: decision 72, #238); #200 (done: decision 73, #249: an interactive SVG in a frame
that runs scripts and shares no origin, the frame the plugins will run
in); #204's TODO lists (done: decision 74, #243; its day's page and calendar, WP5.92 and WP5.93, wait for the plugins' interface and are built as a plugin); #213 (WP5.74b3), started 2026-11-11 at night, with the editor's folding (WP5.96) and #191 (WP5.97) beside it by the owner's word, ahead of #187. WP5.96 is done (#252); #213's first part is done (#251, decision 76) and its second part is open; #191 is done (#253, decision 77). Then the three large ones, in the owner's order of
2026-11-11: #187 (autocompletion); #191 (presentations, which bring the
notion of a kind of page); and last #186 (plugins: decision 69, WP5.84
first), with #190 (table views) and #204's calendar after it as plugins.
Which of #204 and #213 count as smaller is the session's reading, not
the owner's word.

Done beside the stages: #203 (SQLite to PostgreSQL, WP5.80; decisions 66
and 67); WP5.79, the browser's OPAQUE client from opaque-hs (#230,
decision 59); #212 (WP5.74a2b), closed in opaque-hs's own repository,
which the wiki pins since #227.

- **WP5.106 Components without JavaScript tested natively, over
  haskell-halogen's `remote` (the owner, 2026-11-13: "jeśli będzie to
  szybsze. Wszystkie pure halogen testy").** The spike is done (branch
  `wp5106-remote-tests-spike`, one commit, not pushed: a test-suite
  `wiki-app-remote-test` with a harness and the permissions spec
  written a second time). **It is faster**: from an edit to a result
  18.6 s natively against 50.5 s on wasm, cold 139 s against 446 s,
  the run alone 6.9 s against 22 s (each example about 0.2 s slower
  natively, and the examples run one at a time). **But one module of
  53 can move today.** Of 674 examples, 436 in 27 modules stay in wasm
  whatever happens (the editor, the islands, the vault, the HTTP
  backend); about 103 are of Halogen alone, and all but the 5 of the
  permissions spec follow a router link, which does nothing over the
  wire: `Router.isPlainLeftClick` is never true natively. **Waits for
  haskell-halogen**: the router's plain click read from the event's
  JSON, the probe answered by the session (per session), a mount per
  connection, a client that does not reconnect, and `focus`,
  `showModal` and `scrollIntoView` forwarded as operations (the list
  is with the spike's notes). With those: new specs of such views are
  written natively, the three pure modules and the pure parts of
  Shell, Tasks, Spaces, Slides, Search and Notifications move (about
  70 examples), and AGENTS.md's gate names the native suite. Until
  then nothing moves.
- **WP5.108 The pause after typing in a long presentation (found by
  WP5.105's measures, #269).** On the deck of 60 slides of 100 lines,
  the pause after a keystroke holds the page 7 to 11 seconds at its
  longest and 12 to 18 in all; the 4.6, 11.5 and 23.6 seconds WP5.105
  began from were jumps that fell into it. Measured, each alone: the
  check (`Problems.checkText`) about 4.5 s; `publishProblems` run
  three times in one pause (after the slides' measures, after the
  re-cut, after the check), each time `problemsOf` 1.8 to 3.4 s and
  `headsOf` 4.6 to 6.4 s. A lead, not timed: `Wiki.Core.Slides
  .slideLines` splits the whole text once for each slide, and
  `fitsNow` and `measuresFor` call it for every slide, so they cost
  slides times text. Publish once for a pause, split the text once,
  then measure again and take what is next; a test holds the pause's
  longest hold on that deck.
- **WP5.109 A resource made on a worker and kept a step later (found
  by #268).** #268 fixed the owners of addresses and the embedded
  deck's watch: a view's program made a resource through `lift` or
  `liftIO` (which run on a worker thread) and wrote it into its state
  in the next step, so a view closed between the two left it behind.
  The same shape is still in `Preview.startWatch` (`watchFits` makes
  the callback and the measuring, the `modify` after keeps them), and
  nobody has read the other views for it: every callback
  (`mkSyncCallback`), observer, listener and timer a view keeps in its
  state to stop in `Finalize`. Read them all, make each in the step
  that keeps it (`H.liftEffect`), and say the rule in AGENTS.md's
  conventions.
- **WP5.98 The smoke tests wait on the program, and run slowed down
  (the owner, 2026-11-12: "mamy bardzo dużo timing issues w testach
  dymnych"; after #251 and #253).** Two days of red runs fell into two
  kinds. Real faults of the application that a slow machine only showed
  (task boxes disabled and enabled again at adoption, #243; a slide's
  controls replaced under a click, #253; the history entry's number lost
  in a race, #240): there the tests did their work. And tests racing the
  page or the system: a comparison after a fixed 300 ms, a click on
  `.sign-in-toggle` right after `goto`, a check for dead processes half a
  second after the kill. The second kind has one mechanism: a test waits
  on time, or on nothing, where the program has a signal. So: one place
  where both smoke tests wait after every navigation, until the program
  says it has started and settled, before anything is clicked or
  compared; every fixed pause in them replaced by a condition; and a run
  of the smoke tests with the processor throttled (Playwright's CDP
  session can slow it four times), as a job of its own or weekly, so that
  races are found on purpose and not by chance on someone's pull
  request. The throttled run is the part that also finds the first kind.
  **On haskell-halogen's `playwright` package (the owner, 2026-11-12:
  it has landed, with `H.delay` and the adoption check; pull requests
  108 to 110 there).** Its driver waits on the program: `visit` after a
  navigation, every action settled, `waitQuiet` until no fiber of the
  program waits in a `liftIO`. So the smoke tests are ported to it as
  native test-suites, and the scripts go; helpers of the wiki's own
  for waiting are not written (libraries over hand-rolled code). The
  application's part: a pause that only takes a notice off the screen
  or ticks becomes `H.delay`, which `waitQuiet` does not count; a pause
  followed by work a test waits for (a debounce, the autosave, the
  backups' re-look) stays `threadDelay`. Four pull requests: (a) the
  pin's bump as its own commit with `playwright` among its
  subdirectories, the pauses, `screenshots.mjs` ported as the first
  suite, proofs that `waitQuiet` returns after a save, with the
  assistant's ticker running and after typing; (b) `smoke-test.mjs`
  ported, with the adoption check through the library's `adoptWith`,
  and the throttled run (`HALOGEN_PLAYWRIGHT_THROTTLE=4`) as a job of
  its own or weekly; (c) `test-passkeys.mjs` and `smoke-test-server.mjs`
  with the encrypted walk and the canary, after #255; (d) what is left
  of the scripts' helpers and the README. `test-assistant.mjs` and
  `test-tikz-letters.mjs` test JavaScript modules without a browser and
  stay in node. The driver's author's notes on the port are kept with
  pull request (a). **(a) is done (#260, merged with #259):** the pin
  is at ed83131, the pauses follow the rule (stated in
  `Wiki.App.View.Common`), and `wiki-smoke`, a native-only package,
  has two suites run in CI's wasm job: the README's screenshots, and
  proofs of the waits, both also with `HALOGEN_PLAYWRIGHT_THROTTLE=4`.
  One thing in the notes did not hold: the assistant's turn reaches
  its view through an emitter, so `waitQuiet` returns right after
  Send; (b) begins by giving the turn a counted wait in
  `Assistant.hs`. For (b) and (c), three tests that raced in CI on the
  night of 2026-11-12: `DeckViewer` "when the server refuses the
  page" (the request an `IntersectionObserver` starts after
  `bringNear`, waited for two seconds), the Vault suite's check for an
  exportable key (one example's leak fails every later one), and
  `page.goBack` in the server smoke test's interactive SVG walk
  (it timed out four times that day). Two more that day, neither a
  browser's wait: wiki-core's `Markdown.Html, its cost grows no faster
  than the HTML` measures times on a shared runner and failed once on a
  pull request that did not touch it (it needs a count, not a clock);
  and the editor's scroll listener posted to the live preview's channel
  after the editor had closed it, an old race in the application that
  #263's tests made show and fixed. **(b) is done (#262):**
  `toolchain/smoke-test.mjs` is gone; `wiki-smoke-demo` does what it
  did in 82 examples with no fixed pause (of the script's 20
  `eventually` calls 5 stay, each on something that is not the
  program's), the adoption check through the library's two halves and
  `Wiki.Smoke.Adoption`, which (c) uses too. The assistant's turn
  counts as the program's work, so `waitQuiet` after Send means the
  answer has ended. The call timeout is the plain one times the
  throttle. The throttled run is the job `smoke-throttled`, weekly and
  by hand. `npm run smoke-test` runs the Haskell suite for the demo and
  then the node runner for the server's script, where three reads of
  the address straight after a view now wait for the router. The
  driver lacks response sizes on a request (the suite reads the files'
  sizes) and a count of what `leaveOutContents` left out. **(c) is
  done (#267):** `test-passkeys.mjs`, `smoke-test-server.mjs` and the
  scripts of the encrypted walk, the canary, the adoption and
  PostgreSQL are gone; `wiki-smoke-passkeys` (6 examples) and
  `wiki-smoke-server` (49) do what they did, section for section, on a
  harness for a real server (`Wiki.Smoke.Server`, `Api`, `Browser`,
  `Walk`), with no fixed pause. `page.goBack` in the SVG walk is
  explained: the SVG navigates its own frame, which adds an entry to
  the page's history, and Back then moved the frame and the page never
  loaded; the suite goes back two entries and waits for `popstate`.
  `npm run smoke-test` runs the demo, the passkeys and the server (on
  PostgreSQL too when a database is given), then the node runner for
  the two tests of JavaScript modules. A path given to the smoke
  scripts is read from the caller's directory
  (`toolchain/caller-paths.sh`). **(d)**: the late events in the
  server's suites, the node scripts that stay and the README's section
  are #270; the three tests that raced on a clock or on each other are
  a pull request of their own.
- **WP5.95 No view takes an older answer over a newer one (found by
  Codex on #243, rounds 12 and 13; left there on purpose).** The page view
  drops a fetched page older than the one it shows (`takesPage`, by
  `updatedAt`). The same mechanism is open elsewhere, and was before
  #243: the comments' threads (`loadThreads` checks the page's id, not the
  order of answers), the space's tree in the side panel (`loadHere`), the
  backlinks (`loadBacklinks`), and the shell's session, spaces and users
  (`loadWorld`) each take an answer whenever it comes. And one case in the
  page view itself: a save's own answer, arriving after the reader chose
  to see a newer version another editor saved meanwhile, replaces the
  page the ticks are staged on before `takesPage` looks, so the article
  shows the older text under the newer title until the next reload. One
  rule for all of them, stated once (an answer of a kind is taken only if
  no newer answer of that kind was taken already), rather than a counter
  for each request.
- **WP5.92 A day's page: entries with a time, all-day entries, highlights
  (#204, the second of three; after the plugins' interface, see WP5.93).** As other tools do it (Obsidian's Day
  Planner, Logseq's journal), the time belongs to the entry, not to a
  place on the page: the owner first thought of fixed sections for the
  parts of the day and agreed to this instead. A day's page is an
  ordinary page from a template, its title the date, with a list: an item
  that starts with a time (`- 09:00 Standup`, `- 09:00-10:30 Review`) is
  an entry at that time, an item without one is an entry for the whole
  day, and a mark at the start of an item highlights it. The page view
  shows the entries in the order of their times under the parts of the
  day (the owner's: Dawn 6-9, Morning 9-12, Noon 12-15, Afternoon 15-18,
  Evening 18-21, Night 21-6), with "Highlights" above them, all read from
  the list; nothing is moved in the source. A pure function in wiki-core
  reads a text's entries. To settle with the owner before briefing: the
  mark that highlights, and what an item with a task box and a time is.
- **WP5.93 The calendar, a kind of page (#204, the third of three).** The
  owner, 2026-11-11: "the calendar is a nice next example of a plugin".
  So the day's page and the calendar are not built before the plugins'
  interface (WP5.84): they become the third built-in plugin, after the
  assistant and the errors, and show what the interface must give a
  plugin that contributes a kind of page and a view of it, as #190's
  table views will. Only the TODO lists of #204 (WP5.91) are built before
  the plugins. A
  page of the kind "calendar" (a kind of page as presentations are, so
  one calendar a page; the owner asked what two calendars on one page
  would mean) shows its days, which are the pages under it. Views as in
  Outlook, from a library (FullCalendar, if its licence and size hold up
  when checked): the month, with the highlighted entries only; the working
  week of five days and the week of seven, with the entries at their
  hours and the all-day ones above; the day, with all of them. Today is
  marked, with the line of the present time. The server answers the
  entries of a range of dates read from the days' pages, so that a month
  is one request. Read-only at first: a click on an entry or a day opens
  the day's page, and makes it from the template when there is none;
  entries are edited in the day's Markdown. Dragging an entry to another
  time is a later package, since it rewrites a page's text. Notifications
  for tasks: later, as the issue says.
- **WP5.84 Plugins, the first package (#186, decision 69; stage 4).** The
  registry of plugins in the application and the two interfaces of the
  first step, an editing agent and diagnostics. The assistant moves behind
  the first and the errors of KaTeX, TikZ and Mermaid behind the second,
  with no change in what either does. Which plugins are on and their
  options are kept per user on the server, and the administrator can turn
  a built-in plugin off for the whole wiki. Settings gets a tab "Plugins"
  that lists the built-in plugins, turns them on and off and shows their
  options. No external code yet: that is the package after (the manifest,
  the upload, the sandboxed frame, the bridge and protocol version 1, an
  example plugin and a page of the guide on writing one). After the two
  built-in plugins of the first step, the calendar of #204 (WP5.92,
  WP5.93) is the third, and tells what a contribution of a kind of page
  needs.
- **WP5.74 End-to-end encrypted private spaces** (the owner, 2026-11-06,
  rewritten the same day). Two packages, a then b, built so that a single page
  can later be shared with another user.
  - **a is done (decision 59, #184; libsodium from source, #211; the
    oracle test against libopaque and liboprf, a2b, #212, in opaque-hs's
    own repository, which #227 pins).** A deploy with `--system-tools` downloads libsodium's
    release (checked by its checksum) unless `--libsodium-source FILE`
    gives the tarball (#215).
  - **b is done**: b1, each user's key pair in the vault the assistant
    already had (decision 60, #185), and b2, encrypted spaces over it
    (decision 61, #209). What remains is **b3** (#213): encrypted attachments and
    comments; rotating the key when a member is removed; an export
    decrypted in the browser; encrypting a space that already has pages,
    and turning encryption off; subspaces inside an encrypted space;
    decrypted titles in recent changes and notifications; detecting a
    rolled-back version; hiding the controls the server refuses anyway
    (attachment upload, the template toggle, move dialogs, "New subspace").
  - **b, encrypted spaces, with a key per page.** Each user has a long-term
    key pair (X25519, for libsodium's sealed boxes). The server keeps every
    user's public key; the private key is stored on the server wrapped by the
    account key, and the account key is wrapped by a key derived from
    OPAQUE's `export_key` (which only the client knows) and, as the AI keys'
    vault does already, by a passkey's PRF. Every page of an encrypted
    (sub)space has a key of its own (random, 256 bits). The key encrypts the
    page's text, title, versions, comments and attachments
    (XChaCha20-Poly1305), and carries an id, so that keys can be rotated. A
    page's key is wrapped by its encrypted (sub)space's key. The (sub)space's
    key is sealed to each member's public key. Turning encryption on at a
    (sub)space's home page encrypts the whole subspace.
  - **Later, kept possible: sharing a single page.** The page's key is sealed
    to the recipient's public key and kept by the server as a grant, so that
    sharing is asynchronous (the recipient need not be online). Two things
    are left for that package: verifying a public key (the server could
    substitute one; fingerprints or safety numbers), and revocation (new
    versions under a new key; old ones stay readable by whoever held them).
  - **The browser.** The keys held in the browser are non-extractable
    WebCrypto keys where the page is a secure context (HTTPS or the
    machine's own address). WebCrypto (`crypto.subtle`) does not exist over
    plain HTTP, and its non-extractability is the one property no polyfill
    can give (a key in wasm memory is readable by any script on the page),
    so encrypted spaces need HTTPS, as passkeys do. OPAQUE itself (a) runs on
    libsodium in wasm and works over plain HTTP too.
  - **Unchanged from the first version of this entry.** A password reset loses
    the encrypted pages, and says so before it is done ("if you have
    encrypted pages, they will be destroyed"); an export, decrypted in the
    browser, is the way to keep them. What the server does with a page's
    text does not work in an encrypted subspace, and says so: search on the
    server, PDF and Word exports, feeds, link previews, notifications'
    excerpts. Search runs in the browser over the decrypted pages. Slugs are
    random there, since a title's slug would show the title. Not protected:
    an administrator who changes the JavaScript the server sends, which then
    reads what the user decrypts.

### Later, or waiting for the owner

- **`deploy-local.sh` adopts a deployment whose directory was moved (the
  owner, 2026-11-12, after moving one at work one directory up and
  repairing it by hand).** A deployment holds its own absolute paths in
  five places: the systemd unit (`ExecStart`, `WorkingDirectory`, the
  `# Prefix:` line), the state file `<prefix>/state/<name>.state`, the
  `bin/wiki` wrapper, PostgreSQL's compose file and wrapper, and the
  toolchain's env files (`~/.wiki-toolchain/env` and what it names:
  after his move the deploy still wanted to install ghcup at the old
  path). Today the deploy refuses, saying the deployment is under
  another prefix, and the repair is by hand. Wanted: the deploy sees
  that the unit's prefix no longer exists while the checkout it runs
  from holds that deployment's state, says so, and with a flag
  (`--adopt-moved`) rewrites the five places to the new path, stops and
  starts the service once, and changes nothing of the data. Not started:
  he has no second move ahead; the package is small, of the maker's
  deploy and its script tests, with a `technical: true` entry.

- **Compressing the text of page versions (#241; the owner, 2026-11-11: not
  now).** A version is a whole copy of the page. Versions as diffs were
  weighed and refused (reading a version would need a chain, one bad diff
  would break the later ones, sealed versions could not follow); if the
  size ever hurts, a version's body is compressed when stored, above a
  threshold, and stays a row that stands alone. Measure first. The issue
  holds what would have to be settled.

- **Issue #120, the owner's editor improvements** (the owner, 2026-10-31; closed
  2026-11-04). WP5.37 to WP5.45 did all of it, and WP5.53 the three requests added on
  2026-11-03 (a link to a page from the editor, links to sections and selected text,
  the home page's options in its editor); an editor that did not widen when the
  sidebar is folded was not reproduced by either side and is dropped (the owner,
  2026-11-03). Left out:
  C-like preprocessor macros (the owner: "probably not"; math macros and boxes cover
  the need); grammar checking beyond the browser's spelling, which CodeMirror already
  has on (later, perhaps LanguageTool; Grammarly offers no SDK any more).
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

## Known gaps and notes

- **The editor's tooltips, gutters and panels take the wiki's colours
  from a base rule (#258).** CodeMirror's own theme gives `.cm-tooltip`,
  `.cm-gutters` and `.cm-panels` a light grey in either scheme, and the
  text takes the editor's colour: in the dark scheme a problem's box was
  nearly white on white. `web/style.css` sets the colours on
  `.editor-cm .cm-editor .cm-tooltip` itself, and each kind adds only its
  own; a new kind of tooltip, or a second CodeMirror elsewhere, needs
  nothing more inside `.editor-cm` and the same rule outside it. The
  browser specs check a contrast of 4.5 for a problem's box and the
  completion list in both schemes; hspec-halogen cannot emulate a colour
  scheme, so the spec copies the dark tokens onto the editor's host. The
  gutters and panels are not pinned by a test.
- **A key pair left exportable until a reload (WP5.74b1).** A step that
  holds the vault's key (`withKey`) is not exception-safe: when the
  component running it is unmounted mid-step (the sign-in dialog closed),
  the unwrapped key stays in the page as an exportable WebCrypto key until
  the page is reloaded. The browser tests wait for it to go before each
  test ends; the code does not make it go. A bracket around the step, or a
  finalizer the shell runs, is the fix.

What the work done so far left out, found and did not fix, or learnt that later work
needs. Each was true when its package merged; check before relying on one.

- **Presence checked only when permissions change (WP5.76, #218).** The
  hub keeps an epoch, raised by `permissionsChanged`: the storage calls it
  after a write that bumped the permission context's generation, moved or
  deleted a page, or changed whom the wiki is open to or the home page's
  visibility. A subscription remembers the epoch of its last passed check;
  `Reading` and `Editing` go out without a check while it is current, and
  otherwise the check is made once and shared by the page's subscribers.
  A failed check drops the subscription and its presence and sends a late
  `Refused`; the browser then clears the page's readers and editors, drops
  its cached threads, asks again after 1 s doubling to 30 s, and says again
  that it edits the page once the server answers. Any write that bumps the
  generation raises the epoch for every page, so a busy wiki checks more
  than it must; an epoch per space would narrow it.
- **Compile times and CI (#220).** At `-O0` the build prints `ld`
  warnings ("type and size of dynamic symbol … are not defined") where
  Template Haskell loads the dynamic objects (the two `WhatsNew` modules)
  and where `wiki-app-test` links; they are not GHC's, `-Werror` does not
  see them, and `-O1` has none. The longest CI step is the server's
  tests on PostgreSQL (four to six minutes). Since #221 each example's
  database is a copy (`STRATEGY FILE_COPY`, PostgreSQL 15 or newer) of a
  template migrated once per run, which saved only about 12% (276 s to
  244 s on four cores): the migrations were about 70 ms of an example's
  940 ms. The rest is a fixed price per example, largest in the HttpWiki
  and StoredWiki contracts: making and dropping the database and opening
  the storage's connections. Reusing databases across examples (truncate
  rather than drop), or the postgres group split over two jobs, is what
  is left to try. The deploy scripts' tests run in a
  native job of their own (`deploy`, which builds `wiki-server` alone), and
  only the sqlite job builds the base branch's server and rehearses the
  upgrade, on SQLite and then on a PostgreSQL it starts after its tests. A
  machine whose store was built from an older index can keep it with a
  `cabal.project.local` naming that `index-state`.
- **Test databases and steps in code (#221, #222).** On PostgreSQL
  `withPlace` and `withPlaceIn` give a database already at the current
  schema; an example about migrations, schema versions or restores, or
  one that looks at a database no program has migrated, uses
  `withEmptyPlace` or `withEmptyPlaceIn`. `withPlaceIn` there still
  compiles and passes on SQLite, so a new example in `Test.Storage.Migrate`
  or `Test.Storage.CodeSteps` must be checked to use the empty one.
  `Test.Storage.Migrate`'s "numbered from 1 with no gaps" checks the SQL
  files only (`migrationsFor`), and other examples there take their count
  as the program's version: they move to `stepsFor` and `knownVersion`
  with the first real code step. The browser test "counts a notification
  the live channel tells of, with no page shown" failed once on #221's
  wasm job, whose change touched no application code.
- **Marker blocks (WP5.77, #224).** A block other than a spoiler that is
  never closed is a `MarkerError` line and then a `Div` with the class
  `spoiler-unclosed`, so a stylesheet class is in the tree; the classes
  `.spoiler-error` and `.spoiler-unclosed` serve every block's errors now.
  `[[!toc]]` is read in a quotation or a list item too, where `[[toc]]`
  was read at the top level only. `[[!div]]{.notes}` and
  `[[!div]]{.slides}` act as notes and the deck's look. An end marker
  indented inside a list item closes its block on the page, but the
  export may then find the two placeholders in different lists and write
  both lines as written; not tested. `docs/screenshots/page.png` shows
  the Markdown guide before its contents panel gained two headings.
  Fixed after the merge (#226, found by the Codex CLI on the merged
  change): an end marker right after indented code or a one-line block of
  HTML was not read, and a marker line indented with a tab was exported
  as text (the export split the line by commonmark's column, which is
  not an index where a tab comes before it). Left: a marker after a tab
  that follows a quotation's `>` is a block on the page and not in an
  export, where pandoc appears to read the tab as code, so the content
  differs there too.
- **Home pages (WP5.78, #225 and #229).** An import's preview and summary
  do not count the home pages it creates. A space set to "None" before
  the upgrade opens at the default home page, not at its list of pages.
  Step 12's search text is made without a parser, so a space's name with
  Markdown in it (`*x*`) keeps those characters there until the page is
  next saved. Not tested: that encrypting a space deletes the home page
  step 12 gave it. After step 13, the old address of a child that was
  renamed because a top-level page had its slug leads to that top-level
  page, and old addresses below the renamed child lead nowhere. A home
  page that was under another page lost its old address. A relative link
  that climbs with `..` from the home page, or from a page that was under
  it, starts one level higher than before; no page's text was rewritten.
  Old addresses are not prerendered for a static host: its `404.html` is
  the application, which reads them. The key under which a browser
  remembers the home page's open spoilers changed, so those opened before
  are forgotten. The refusals for "a page with the home page under it"
  can only be reached through a hand-edited database now; their tests
  make that state with SQL. When a rehearsal's old program is itself at
  step 13 or later, `roots` has only home pages to check.
- **The rehearsal's ports on CI.** `toolchain/rehearse-ci.sh` picked its
  ports up to 39999, in the range Linux gives outgoing connections, and
  one CI run failed on a port in use (#229). They are below 32768 now,
  with another pair tried when one is taken;
  `toolchain/test-rehearse-ci.sh` tests it.
- **The browser's OPAQUE client (WP5.79, #230).** A step that fails for
  any reason but a wrong password says so on the console as a warning
  with the error's name ("OPAQUE: the sign-in could not finish:
  KsfError"); the wiki's old binding logged an error with the JavaScript
  exception's text. `keyRefOf` is still exported from
  `Wiki.App.Assistant`, though nothing outside it uses it. In
  `Test.Browser.Vault` the examples of the user's keys share one page, and
  one that leaves a key on the device changes what a later one finds: an
  example that reads the device starts as a new device (`js_new_device`).
- **Copying a database (WP5.80a, #232).** A SQLite source in use is
  found through its data directory's lock only, as `restore` finds it: a
  server on the same file under another `--data` is not found, and the
  console's commands hold no lock. The source is read as one snapshot, so
  a write during the copy is not in it. When a table's verification fails,
  the diagnosis holds one digest for each row of that table in memory.
- **PostgreSQL on the session's machine.** The server's PostgreSQL tests
  can run locally since 2026-11-10: rootless Docker under the session's
  account, started by its systemd session, and
  `toolchain/ci-postgres.sh start` for the container CI uses. One
  container is shared by every agent that runs them; its port is the one
  Docker chose, read with `docker port` (decision 75), and `start`
  leaves a running container alone.
- **The move to PostgreSQL (WP5.80b, #233).** It ran end to end once, on
  2026-11-10, on a scratch deployment under the session's account (a real
  unit, rootless Docker, a wiki with an account, pages, an attachment and
  a comment): the move, with the same password signing in after it and
  the wiki reading the same but for the search's kind; a page written on
  PostgreSQL and then `--rollback --yes`, which brought back the wiki
  exactly as it was before the move; a second move, refused because
  PostgreSQL still held the first one's wiki, with nothing changed. The
  failures in the switch have run against the deploy's fakes only. Two
  trifles seen there: that refusal prints the container's id on a line of
  its own (Docker's answer to stopping it), and `undeploy-local.sh
  --purge-data` says it deleted "the state and the toolchain under it"
  when the toolchain was elsewhere (`--toolchain`) and was not touched.
  The maker reads two variables for
  its tests in the program that is deployed with
  (`WIKI_TEST_MOVE_FAILPOINT`, `WIKI_TEST_MOVE_OPERATIONS`). The tests
  fail one operation in each run, not two. A move killed during the
  switch needs a person, and the next move refuses until then. Nothing
  locks a move against a deploy that rehearses at the same moment (both
  use `<state>/<name>.rehearsal` and the database `wiki_rehearsal`). After
  a switch back that stopped part way with the state back on SQLite,
  `--rollback` leaves PostgreSQL's container running with the copy. The
  guard needs `sha256sum`.
- **The maker's test variables stay in the deployed program (WP5.83,
  #234; left to the session by the owner, 2026-11-10).**
  `WIKI_TEST_MOVE_FAILPOINT` and `WIKI_TEST_MOVE_OPERATIONS` have no
  build flag: a flag would mean the tests run another program than the one
  deployed, and a failpoint set by mistake only makes a move fail and
  switch back. The README's paragraph on native CI's "three independent
  hosted jobs" is from before the `deploy` group.
- **The `html` frame (WP5.89, #238).** Each frame is a document that
  parses the stylesheet and holds a `ResizeObserver`; nothing loads frames
  lazily. Typing in the preview makes a new frame at each keystroke, as it
  does for a diagram. A link to a place in the page loses its address in
  the frame, and an attachment's link opens the file in a new tab, since
  the sandbox blocks downloads. A link in the block is not a backlink.
  Painting outside a box (an outline, a shadow) does not count for the
  height. The fit follows the content's size, the window's, and the
  `load`, `toggle` and animation-end events of the frame, not an
  animation that never ends. Not tested: adopting a prerendered frame
  that has `{height=N}`, in the browser. The editor's "Math macros" panel
  knows the page's macros in a `math` fence only, not a `latex` one. The
  demo's attachments are `data:` addresses in the prerender and `blob:`
  ones in the application, so such a frame reloads on adoption, in the
  demo only.
- **The upgrade reads every page twice when both versions change
  (#238).** The links' fill and the search text's each parse every page:
  about 50 ms a page of 15 KB in an unoptimised build, so minutes on
  thousands of large pages, with the service stopped while the deploy
  migrates. One pass for both, when both stamps are stale, is a small
  change left for when it hurts.
- **A page's text has no size limit on the server.** A save's body is not
  capped; an encrypted page's ciphertext is (8 MiB), and an import is
  (512 MiB). So megabytes of text can reach the parser on the server (the
  prerender, the search text, the links, the upgrade). The owner was
  asked on 2026-11-11 whether to open an issue for a limit.
- **Logins (WP5.87, #242).** An `@login` written in a page before a
  rename names nobody afterwards; pages are not rewritten. The person is
  told nothing by the wiki: the administrator passes the new login on,
  from the migration's line or the audit log, and the old login answers
  "wrong login or password". There is no command that renames a login, so
  one that `check` refuses later has no remedy but a step or SQL. A
  renamed user's authenticator label and passkey name keep the old login,
  and their personal space keeps its slug, so "Find another" finds it by
  name only. A console command that happens to migrate drops the step's
  lines; the audit log keeps them. Neither the storage nor `check`
  refuses two logins that differ only by case. Two tests go back in time
  by deleting `wiki_schema` rows, which holds while later steps make no
  table.
- **Backlinks (WP5.88, #239).** A save of a page that has links reads its
  space's pages once (about 55 ms for 5,000 pages in an unoptimised
  build), creating a page there costs 0.12 to 0.27 s, and the fill at an
  upgrade 12 to 29 s for 5,000 pages with 50,000 links. A long list is
  not capped. The list is not updated live. The demo computes its lists
  before the first render and keeps each page's parsed links beside its
  search text; the smoke test failed 9 times in 11 before that, the first
  action after a load being lost, and once in 6 after it at another step
  (a history page fetching TikZJax), which was not shown to be unrelated.
- **The history's entry numbers (#240).** Following a permanent link ran
  its redirect on a worker thread, and for a moment the entry had no
  number in the history and none kept aside, so the shell numbered it
  twice and "Stay" asked the browser to go further than the history
  reaches; fixed by running the redirect on the component's loop and by
  writing the number back before the kept one is cleared. The same
  mechanism, read from the code and not reproduced, is in three other
  redirects that do not go through `replacingEntry`: the redirect to a
  space's canonical home address in `announce`, the administration's
  canonical redirect, and Stay's own fallback. A small package of its
  own. Two examples fail now and then for other reasons: "copies the
  permanent link of the version shown…" reads the notice without
  waiting, and "counts a notification the live channel tells of, with no
  page shown".
- **`check` and the accounts (WP5.85, #237).** `ways in` reads a column
  that knows of passwords alone: an account that signs in through a
  provider or with a passkey only reads "no (no password)" before and
  after, and nothing in the rehearsal covers a passkey-only account (the
  `accounts` canaries cover a password and a provider). On a machine with
  no UTF-8 locale at all the rehearsal cannot drive a program from before
  #237 and says so; the deploy then goes on with `--no-rehearsal`. A data
  directory whose path is not UTF-8 fails to open, as before. Three
  places still read the password columns in SQL rather than through
  `readPasswordColumns`: `Rows.loadAccountFlags`, `legacyPasswordCount`
  (which counts a hash left beside a record) and `SecondFactor.hs`. A
  wiki that has a broken credential now stops its deploy's rehearsal at
  the check, as a broken rehearsal (exit 1), not a failed check.
- **Permanent links (WP5.81, #235).** Not tested: a pinned link to a
  version of an encrypted page, and the page view's guard against an
  older load finishing last (nothing orders two answers cheaply). The
  browser specs run under the hash router, so a fragment kept and
  scrolled to is checked by the demo's smoke test and the server's
  `Location` headers only. Signing in through a provider loses the
  fragment, as it does for a path address. A hand-written `/l/x` means
  the page with id `x` even where a top-level space has the slug `l`,
  which is still reached through `/s/l/…`. The merge import gives the
  pages it creates new ids, so a link by id in imported text names the
  page it named where the archive came from. The help dialog's own
  resolver drops a path's query, version included; the guide writes none.
  `Contents`' "ends each heading with a link to itself" read the notice
  while it still said "Copying the link…" once under load.
- **Emoji in the editor (WP5.86, #236).** Enter chooses an emoji only once
  two letters of its name are typed or the list was moved in, so that `:p`
  and a colon at a line's end stay text; after two letters it still
  chooses (`12 :10` then Enter gives `:100:`). The colon's list does not
  open inside a link's text, since it uses the mentions' guards. `-:`
  stays closed when the line before holds any `|`, prose included. The
  comment boxes are plain text areas and complete nothing. The PDF and
  Word exports keep their bullet before an emoji that the page shows as
  the bullet. Not tested: an input method composing (Safari ends a
  composition with an Enter that does not say so, and haskell-halogen's
  `KeyboardEvent` has no `keyCode` to tell it by), touch keyboards, and a
  real window 375px wide (the test narrows the editor instead). On a
  toolbar narrower than 40rem every toolbar menu opens under the whole
  toolbar, by a container query.
- **Stage 0's small fixes.** The server does not refuse turning on a second
  factor for an account without a password; only the panel's button is
  disabled (#216). `.editor-pending-note` and the problems count are still
  in the editor's row of buttons and move them when they appear (#217).
  Closing a menu with Escape does not put the focus back on its button
  (#219).

- **Encrypted spaces (WP5.74b2, #209).** Not tested: a click test of the
  vault unlock and of "Encrypt this space…" (the browser test puts the
  user's private key back on the device instead), the smoke test against a
  real server, and archive export and import and the sitemap with an
  encrypted space. The browser's search fetches every page of a readable
  encrypted space at its first search and keeps them decrypted in memory
  until a write, which suits small spaces. Stars' titles are decrypted only
  after the prerendered page, one request per encrypted space with a star.

**The application**
- Drafts: what is typed in the last two seconds before the tab closes is not in the
  draft; Back from a new page's editor returns to the new page form, where a second
  submit makes a second page (WP1.18).
- Ordering by hand: the move buttons' ends are computed from the spaces the user can
  see, and the backend reorders over all siblings, so a move can pass a sibling the user
  cannot see (WP1.17).
- The administration panel neither shows nor toggles group grants of the global
  permissions; they count by the rules all the same (WP3.4, carried since).
- Slides: no theme from the space's settings (it needs a space field and a migration),
  no speaker notes in a second window (WP4.2, carried).
- The session history's entries: the shell keeps an entry's number and the preview's
  mark as text in the entry's state (`"12+preview"`), and still reads the objects the
  versions before WP5.47 wrote, for a tab open across that deployment; that decoder
  (`PreviousEntry` in `Wiki.App.Browser`) can go once no such tab can remain. The search
  box's closing on a press outside is heard in the bubble phase now, not capture; a
  `pointerdown` stopped on its way to the document would leave the box open (WP5.47).
- Settings: one changed by another process is seen only after a restart; there is no
  console `settings` command (the admin listener is the recovery); a secret travels once
  in the `PUT` body over the admin listener (plain HTTP on the private network, decision
  20) (WP3.5, WP4.4).
- Export: no ZIP64 (4 GiB or 65,535 files are refused with a message); the export holds
  every page body in memory (WP5.16c).
- The demo: the first search after a load or an import parses every page once on the
  loop (seconds at 1000 pages on wasm; the server has its index) (WP1.23). Each demo tab
  keeps its wiki in memory from what was stored when it loaded, so the live preview in
  another window does not see a file uploaded after it opened (WP5.36).
- Offline: under Playwright, a page a service worker serves offline reads
  `navigator.onLine` as true; a retry on `online` is a small follow-up (WP4.17).
- The live preview (WP5.36): no "Detach preview" on the front page (no space path for
  its address); the side by side pane does not close while a window is open; the line
  markers are on the editor's previews only.
- Passkeys (WP5.30) differ from the plan's text by design: no audit entry for a sign-in
  (a password's writes none either) and no refusal in a closed wiki (a password's sign-in
  is not refused there either). The wiki-app `Accounts` record carries four passkey
  methods; the assistant's settings always show the password field, since they do not
  know whether the user has one.
- Footnotes (WP5.42): in the editor's "Show preview" a footnote's number only scrolls
  to the note, with no history entry, since an entry there would take the Back that
  "Back to edit" makes. The hover is a native `title` with the note's plain text.
- Unclosed math in the editor (WP5.42): `$` before a number is read as a price when a
  word, punctuation or the line's end follows the number (`$5 each`, `$3.50`), so a
  formula such as `$5.` left open is not underlined. Multi-line `$$` or `\[` blocks are
  never checked.
- `Wiki.App.Browser.copyText`'s fallback without the clipboard API selects an
  `<input>` with its own `select` and any other element with a range; a `<textarea>`
  would need `selectionStart`/`selectionEnd`, which no caller passes today (WP5.31).
- The server could cache `template.html` (optional, WP5.14).
- A second deployment (`--name`) on one machine cannot share port 443 and should use
  `--http` (WP4.18).

**Tests and CI**
- Seen once, not reproduced (WP5.44): the PostgreSQL test "restore keeps the database
  it replaces" failed with `DataDirInUse` in a full local run. It passed on every run
  after.
- A press is lost when a render moves the pressed element's ancestor out of the tree
  and back during the press: the browser then sends no click. On wasm a render can run
  inside the press, since a `pointerdown` listener that calls into the program (the
  search box's) also runs the work waiting for it. Unkeyed children move when an
  earlier sibling changes between a component and an element; #130 gave the front
  page's document a holder of its own for this. Other views with a slot after a child
  that changes kind can lose a press the same way.
- The editor's browser test "loses no keystroke while the preview catches up with a long
  page" types its keys 12 ms apart. Typed with no pause, about one run in ten
  CodeMirror (`@codemirror/view` 6.43.15) throws "Selection points outside of document"
  from its scroll handler, which flushes DOM changes it has not yet read
  (`flush(pendingRecords > 0)`, new in 6.43.15; 6.43.14 throws less often). The side by
  side pane's scrolling brings it out; no change of ours prevents it. Catching the
  error in the page was tried and dropped: it put a typed key at the wrong place. Not
  reported upstream yet (WP5.37).
- Known flake: `Test.Server.Api` "logs each request…" races the log line written after
  the response under full-suite load.
- Under load: `Test.Browser.Vault`'s check that no WebCrypto key can still be
  exported when an example ends ("expected: 0 but got: 1") failed in 30 of
  the file's examples in one local `npm run test-wasm` while CI's wasm job
  ran on the same machine, and in none in the rerun on the same tree
  (#227, 2026-11-10). CI passed on that head. Not looked into: whether the
  check reads the page before a step that makes a key non-exportable has
  finished.
- The smoke tests open pages with `serviceWorkers: "block"` (their Playwright routes do
  not see a worker's traffic); new parts need the same or a context of their own.
- The demo's address is in the README's links and in `Test.Readme.demoAddress`, and the
  README's examples quote demo pages: a change to a demo page under an example, or a
  renamed heading, fails the test, so the two change together. After a change to the
  wiki's look: `npm run build-wasm`, then `npm run screenshots`, and commit.

**Building**
- A deploy builds the page's prerender with the server's build
  (`NATIVE_PROJECT=cabal-native-opt.project`, `NATIVE_BUILDDIR`, and the
  server's `wiki-server ±postgres` in `NATIVE_CONSTRAINTS`, one per line), so
  `wiki-app` is compiled once; the demo keeps the `-O0` build. The maker's own
  build shows cabal's progress (#210).
- A new `migrations/*.sql` does not recompile `Storage/Migrate.hs` incrementally
  (`embedDir` tracks only the files it saw): delete its `.o`.
- A deployment under a prefix (`deploy-local.sh --prefix`, WP5.48) leaves one thing in
  the home directory, its systemd user unit, since systemd reads units from
  `~/.config/systemd/user` alone (`systemctl --user link` would leave a symlink there
  all the same); the unit names its prefix, and every later run is given `--prefix`.
  Two deployments of one `--name` cannot coexist, whatever their prefixes: the name
  is the unit's. The toolchain under a prefix is a second copy (several gigabytes)
  unless `--toolchain` names a shared one.
- The page workflow (WP5.49) keeps one run per ref without cancelling, and GitHub
  keeps only the newest pending run, so two quick pushes to `main` during a build lose
  the middle commit's pages; `--backend-only` says "no page was built" for it. A
  checkout at a tag whose commit is not among `main`'s newest five needs
  `--backend-only=<tag>`. Commits and tags from before the demo's page was added have
  the server's page only. A Node 24 without npm is not reused for the demo's
  deployment (the version check wants npm); the managed Node is installed instead.
  `--no-build` refuses a page of the other mode, so a switch between `--server` and
  `--static` needs a run that builds or downloads.
- HTTPS with a certificate of one's own (WP5.50): checked with certificates `openssl`
  made, not yet with a company CA's chain or a real DNS name through `--tls-ca`;
  Caddy or nginx in front of `--behind-proxy` was not run. The ufw rule for a
  LAN-facing `0.0.0.0` bind opens the port on `tailscale0` alone, so a LAN at work
  needs `--no-firewall` or a rule of its own. The TLS files are read at start only:
  a renewal needs `systemctl --user restart`.
- The deployment's server build (`cabal-native-opt.project`) builds with `jobs: $ncpus`
  and turns cabal's build semaphore on only when it works: on the owner's RHEL 9
  machine GHC could not open the semaphore cabal made (`semOpen: does not exist`), so
  the opt project says `semaphore: False` and the deploy first runs
  `toolchain/check-semaphore.sh` (a C helper creates a named semaphore as cabal does
  and the toolchain's `ghc -jsem` compiles a one-line module; #144) and passes
  `--semaphore` or `--no-semaphore` to cabal; `--semaphore`/`--no-semaphore` on the
  deploy, and the wizard's choice, decide instead of the probe. Without the semaphore
  the four own packages compile one module at a time (no `-j`, which on top of
  `$ncpus` GHCs would oversubscribe); the Dockerfile's builds run without it. The
  deploy streams cabal's output and, after a failure, prints the newest cabal log's tail
  (cabal's console says only "see the build log above"). Downloaded pages are cached
  per commit (a tag's by GitHub's asset id and time); `--refresh-page` downloads anew.
  libpq is found through `pg_config` on PATH alone (`postgresql-libpq` does not use
  pkg-config), and `check-native.sh` names a `pg_config` found under `/usr/pgsql-*/bin`
  (#140).
- CI's hosted caches (#153, the owner, 2026-11-04): the four build caches (the native
  and wasm cabal stores, the native and wasm `dist-newstyle` snapshots) are keyed by
  the compiler pins, the runner kind, a hand-bumped tag and the run id, never by a hash
  of the sources: a run restores the newest copy under the prefix and cabal and GHC
  decide what to rebuild; `toolchain/ci-prune-caches.sh` deletes the ref's older
  copies, so each ref holds one copy per cache and the repository's 10 GB limit no
  longer evicts `main`'s. Since #179 (the owner, 2026-11-06) it runs in a job of its
  own, `prune-caches`, after every job that restores a cache (`native`,
  `native-floor`, `wasm`, `wasm-warm`), never beside them: deleted right after the
  save, the older copy vanished while another group was still looking it up, which
  then built every dependency. Only `prune-caches` holds `actions: write`. A pull
  request's run sees only its own ref's copies and `main`'s; `main`'s hosted wasm
  copies come from `wasm-warm` ("wasm (hosted cache)"), the wasm job's steps through
  a YAML anchor on a hosted runner, untested, on every push to `main` whose page was
  not built on one; deploy does not wait for it. `server-page.yml` keeps a store of
  its own for its `-O2` dependencies (`Linux-wasm-opt-store-…`, started from the wasm
  store, pruned by its own `prune-caches` job), since they have unit ids of their
  own. The stores keep a transitional restore key for the copies saved before
  the tag; drop it at the next tag bump. The self-hosted runner's store and build
  directories live on its disk and are untouched.
- Without PostgreSQL (WP5.52): `toolchain/test-native-groups.mjs` expects a binary
  built with the flag on (its postgres group asks for `WIKI_TEST_DATABASE_URL`); a
  haddock on `Storage.release` names `Postgres.holdDatabaseShared`, which a flag-off
  build lacks; `bootstrap.sh all` and `toolchain`, the developer install, still ask
  Debian for `libpq-dev`, and the demo's `bootstrap.sh build` too, on purpose.
- The wizard (WP5.51) needs GHC even for a demo-only deployment (`--static
  --backend-only`), and on a machine other than Debian stops when libsodium or zlib
  is missing, as the bootstrap's own check would; brick and vty compile once, some
  minutes. Its command-line tests run only with `WIKI_TEST_WIZARD=1` (not in CI).
- Links and text fragments (WP5.53): a hand-written `/s/x/p/y` is read as the route
  `Page [x] [y]`, so a top-level space slugged `s` with that layout is reached through
  its route address only; a hit in the home space gets a route path rather than `/`;
  the "occurs more than once" check looks at a quote's first part, so a long quote
  that repeats only later is written without context; an image with no space around
  it inside a word assumes the browser's matcher sees a non-word character there;
  Ctrl+Shift+K is Firefox's web console shortcut (the default is prevented, Firefox's
  behaviour unchecked). The wiki's icon still saves as soon as it is set; the home
  page's three switches do not count as unsaved work.
- Personal spaces (WP5.54): the container stays, hidden, after the last personal space
  is deleted; sealing a personal space is allowed but changes nothing (the container
  grants nothing); over HTTP a `Space` body must carry all four new fields (the derived
  `FromJSON` has no defaults; client and server ship together); a turned-off personal
  space imported by a merge becomes an ordinary private, sealed space that only
  administrators read until someone grants it (the archive's users and grants do not
  come along).
- Avatars and readers (WP5.55): the server's prerendered page is compact until the
  application applies the browser's width choice (no inline script, by the CSP); a
  notification's actor has no avatar on the server, which stores the actor's name;
  the `wiki_blobs` metrics do not count avatar-only blobs; avatars do not travel in
  the archive and an import leaves them alone; the demo's own pages say "Last edited
  by" alone, their first version having no author; the operator is neither a reader
  nor a visitor; the width switch is hidden below 1200 px.
- The assistant at a gateway (WP5.57): nothing was tested against a real gateway or
  `api.anthropic.com` (the header and the address are covered by the Node test with a
  fake fetch); with a base URL and no key, "Test the connection" sends no auth header
  and the 401 says to paste a key; the settings' "Fetching from …" lines name the
  provider, not the host; a token that expires is pasted again, nothing refreshes it.
- `PUT admin/settings` bodies must carry every field (`FromJSON` is derived).
- WP5.58's TeX Live install (decision 40) was never run for real: the session's
  sandbox refused the downloaded installer, so the size, the minutes and the package
  list installing cleanly on the current TeX Live rest on its `texlive.tlpdb` and on
  a `-recorder` mapping of what the PDF tests read; the "y" path is tested with a
  fake installer only, and "y" at the terminal's question only with "n" through
  `script(1)`. The first real `--texlive` deploy should be watched. `mirror.ctan.org`
  may send the installer and the repository to different mirrors, and a lagging one
  makes `install-tl` refuse ("not compatible"): rerun, or name a mirror. `--status`
  waits up to 60 s on a looping engine. The deploy test's CI comment still says
  "about two minutes" where it took seven.
- WP5.56 (decision 41): a PDF opened from a `blob:` URL is saved by Chromium's viewer
  under the blob's name; a failing engine is logged as a warning, not in the status
  page's error list; a child process the engine starts during an export is not killed
  with the export (the probe kills its whole group; pandoc's handle is out of reach);
  every test server start runs the probe, so the server's SQLite suite takes about
  240 s instead of 150; the probe runs synchronously at start (about 1 s with a working
  TeX, up to 60 s with a hanging one), and a TeX repaired afterwards takes effect at
  "Check again" or a restart; the export buttons do nothing until the program has
  loaded, where the old links worked before it.
- The live channel's permission checks (WP5.69, #164). The flaky test "the live
  channel checks once for each user whether they may read a page an event is about"
  (`Test.Storage.Scale`) counted the checks of `Reading` events in its window: a
  tab's subscription changes who reads the page, `tellReaders` tells the other tabs
  through `tellSubscribers`, and its `Check` runs one `mayReadPage` per user like a
  save, whenever each tab's sending thread reaches it; the test also took any event
  for a heard save and closed tabs early. The test now counts only `PageChanged`,
  drains the queues with one uncounted save first and keeps the tabs open; the
  channel itself never checked twice. Left for the owner: every update of who reads
  or edits a page (`Reading`, `Editing`) costs one permission check per subscribed
  user although it carries no page content and is frequent on a busy page; whether
  those updates should skip the check is a design call. A test binary run by hand
  without `LC_ALL=C.UTF-8` (which `npm-command.sh` exports) fails three encoding
  tests; that is the runner, not the code.
- WP5.59 and WP5.60 (decisions 42 and 43): the crop dialog's backdrop click closes
  it as the link dialog's does but is not browser-tested (Playwright's click lands on
  the dialog's body); Escape during an upload in flight closes the dialog while the
  upload completes; the plain-HTTP warning in the assistant's settings now concerns a
  service only the administrator can change; the `--assistant-hosts` help text is
  long. `getBoundingClientRect` belongs in haskell-halogen's `Element` (decision 30);
  until it is there, `Wiki.App.Web.Rect` reads it through a newtype of its own: a
  follow-up for haskell-halogen, after which the newtype goes.
- WP5.61 (decision 44): CI tests the Perl build and the installer's clone with a fake
  `git` only (the real build from the GitHub clone was done by hand once, under
  four minutes; the clone is about 25 MB of `.git` and 120 MB checked out, the
  installer's about 20 MB and 70 MB); `--perl-source DIR` copies the directory as it
  is, build files included; the build's whole `make`
  output goes to the terminal as well as the log; the xelatex item of check-native
  (a second or two with a working engine, up to 20 s with one that hangs) is skipped
  with `--without-tex`, which a server deploy passes since its TeX step probes on the
  service's PATH anyway (#157); `bootstrap.sh native` still runs the check without
  it, so a `--backend-only` deploy probes once more; a server with `--no-pdf` keeps
  the PDFs off until the next deploy, even if a working TeX appears meanwhile;
  `check-tex.sh`'s default 20 s has no test of its own. Every `install-tl` and
  `tlmgr` call runs from `<toolchain>/texlive` with `TEXLIVE_INSTALL_NO_RESUME=1` and
  no standard input (#157: `install-tl` reads a stale `installation.profile` in its
  working directory before its options and asks on stdin, which hung a deploy with
  the question captured and unseen), and the TeX step first checks with curl that the
  mirror's `tlnet` answers, naming the mirror the redirect landed on, or stops with
  the `--texlive-mirror` hint; `install-tl` itself is still handed `mirror.ctan.org`
  when no mirror is named, so it may land on another mirror than curl did.
- WP5.62 (decision 45): a spoiler's open state is per browser, not per account; the
  `hashchange` and load paths that open a spoiler around a URL fragment are
  implemented but not in the browser suite (the test hash router cannot navigate to
  a fragment); the inline spoiler's `role="button"` with a fixed `aria-label` hides
  the revealed text from assistive technology; comment notification excerpts use
  the plain text, so they reveal inline spoilers; CodeMirror does not dim `||` or
  the marker lines; a heading inside a spoiler on a deck is not taken as the slide's
  title; the block button cannot keep the end marker's name in step with the
  start's; in exports a heading inside a footnote gets its automatic identifier in
  pandoc's order (at the reference) rather than the wiki's (end of page), where the
  two parsers disagree on what is a heading the export follows pandoc, and box
  identifiers (`box-tip-1`) are not reserved since exported boxes carry none; the
  guide's contents test ("lists a long page's headings…") failed 2 of 7 local runs
  once, apparently a timing race older than WP5.62 (Mermaid and TikZ finish about
  2 s after load and push the page down), which the guide's longer Spoilers section
  makes easier to hit; CI has not hit it.
- WP5.63 (decision 46): a Word export shows no line numbers (pandoc's Word writer
  ignores `numberLines`); if highlighting fails, the error text written into the
  `<code>` is what the button copies; the button covers the end of the first line
  of code; the gutter scrolls sideways with a long line rather than staying put; a
  fence whose first line is blank has no test on the prerendered page; with the
  islands script missing but scripting on, the button shows and does nothing; the
  browser suite stubs the clipboard, since hspec-halogen's browser context grants
  no clipboard permission, and only the smoke test uses the real one.
- WP5.64 (decision 47): a nameless heading spoiler is remembered by its heading's
  id, so renaming the heading forgets its open state, and an id equal to another
  spoiler's written name shares state with it; a marker pair that cuts a section
  inside a heading spoiler shows its error inside the closed box.
- WP5.67 (decision 48): two `--app-page` paths holding the same bytes share one
  cache entry, owned by the path deployed last; the screen-driven wizard test runs
  the real wizard through `script(1)` with sleeps between keys (about 15 s, skipped
  without `script`, and could be flaky on a very slow runner); the deploy test's
  "semopen" case can fail when the fake cabal's log lands in the same timestamp
  tick as the build's start (`find -newer`), a race older than the branch;
  `--hackage-mirror` is accepted with `--static`, where it has no effect.
- WP5.65 (decision 49): an island's place comes from a search of its block's text,
  not from source spans; four review rounds narrowed it case by case (occurrences on
  one line, delimiters in source order, whole matches, code spans), and the parser
  keeping spans for inline formulas would replace the search. A formula over quoted
  lines, whose `> ` markers are not in its source, is placed by its first line. TeX's
  `l.N` and Mermaid's "on line N" are not used to narrow a range. A new failure of
  an island the preview has not drawn yet appears with the next preview render.
- WP5.66 (decision 50): a pull request that changes only Markdown outside
  `changelog/` runs no workflow, so its entry is not checked; a bare `cabal build`
  without the stamp does not rebuild the server for a new entry, and a local build's
  version refreshes only when the server compiles for another reason;
  `Wiki.Server.Storage.Migrate`'s comment says cabal sees a new migration file,
  which it does not; the unseen dot is per browser, not per account, and appears a
  moment after the page shows; raw HTML in an entry keeps its own ids and `[[toc]]`
  lists them unprefixed.
- WP5.68c1 (decision 55): two copies of the native check, the shell's (which
  the deploy and the wizard run before there is a GHC) and the maker's;
  `test-bootstrap.sh` runs its check cases against both. A machine without libsodium or libpq learns it from `bootstrap
  native` only after GHC, cabal and the maker are built; the deploy's own check
  still comes first; both copies stay (the owner, 2026-11-06). The 9.10 job builds the maker but never runs `bootstrap native
  --system-tools` with that GHC.
- WP5.68c2a (decision 56): `deploy-lib.sh`'s firewall, `tailscale serve` and
  state functions have a second copy in the maker while `undeploy-local.sh` and
  `--status` stay in shell. A demo from GitHub now installs GHC and cabal it did
  not need before (c2b), a few minutes once. A `--no-build` deploy on a machine
  whose maker was never built builds it just before the old service stops, so a
  Hackage it cannot reach is found late (nothing has changed by then). The maker
  reads Tailscale's and the panel's JSON with aeson, where the shell used python3,
  jq or Node. Since c2d the maker, when it is not built yet, is built
  before the TeX step (c2c: right after it), still before anything of the wiki
  is built. The maker's encoding is UTF-8 with ROUNDTRIP whatever the locale,
  so its own messages print UTF-8 bytes on a terminal set to another encoding
  (the shell printed them as written, also UTF-8). Since c2e the page CI built
  is looked up after the bootstrap, since the maker exists only once GHC and
  cabal do: a REF with no page still stops the deploy before anything is built
  or changed, but after the toolchain is installed or checked, and a refused
  `--static --backend-only` leaves the Node the bootstrap installed.
- WP5.68c2 and d (decision 57, #183): the option reader, the layout and the
  state reads exist in both languages, the shell's for `--status`, `--stop`,
  `--help` and stage 1; `Maker.FrontSpec` and the oracle's wizard check hold
  both to `deploy-local.sh`'s header. No deploy test reaches stage 1 without
  `WIKI_MAKER` (the oracle always sets it); `bootstrap.sh maker` has only its
  `test-bootstrap.sh` case. On a machine with no cabal the first deploy runs
  the bootstrap twice (`maker`, then the deploy's mode). With
  `--system-tools` and no cabal, stage 1 stops at the bootstrap's own
  system-tools message, not the deploy's. `maker deploy --help` prints
  optparse's usage and points at `deploy-local.sh --help` for the options.
  The defaults resolved from the state are inline in `Front.front`, without
  unit tests of their own.
- WP5.71 (decision 50): the demo's version is `unknown` when its build has no
  `WIKI_BUILD_VERSION` and no git (the stamp records what
  `toolchain/changelog-stamp.sh` found), and a plain `cabal build` of
  `wiki-app` without the stamp does not rebuild it for a new entry, as with the
  server.
- WP5.68a (decision 51): the maker is built and tested only on GHC 9.14.1 so far;
  no mode builds it with another GHC yet (`--system-tools` modes do not run it), but
  (c) makes it run there (decision 53); CI's `env:` blocks (`build.yml`, `server-page.yml`) still repeat
  the pins of `toolchain/pins.env` with nothing checking they agree; no CI job builds
  the Dockerfile, so the maker's place in the image is untested.
- WP5.68b (decision 52): the results the wasm rules keep (`dist-newstyle/wasm/maker`)
  are not in CI's cache, so CI runs wasm-opt and the bundle every time; Shake runs
  one job at a time (wasm-opt and esbuild together would compete for a small
  machine's memory).
- Upgrades and rollback (WP5.73, #180, #181, #182): the server's attachment clean-up
  looks only at `data/backups`, not at the backup copy in `previous/`, so a rollback
  made after that backup was pruned may lack the files of attachments deleted since
  (`wiki-server restore` says how many). One deployment back is kept; a deploy
  into another directory keeps nothing. The firewall step of a
  rollback is tested only through its bookkeeping (the test deployments bind to
  127.0.0.1, which has no rule). The commit recorded is the last build's
  (`dist-newstyle/deployed-commit.<mode>`); a page downloaded from CI is not of it.
- `hh` wherever the element names are known when the code is written; combinators where
  data chooses the element (the Markdown renderer) and for helpers that make their own
  element (`Router.link`, `HH.slot`). A row named by a synonym and used at many sites is
  written flat (WP5.13).
- Upstream, a component that needs no `Typeable m` can be built with the `Component`
  constructor and `ComponentInfo {stateType = Nothing}`, which would also free the spec
  signatures (WP5.13).
- haskell-halogen: when the tree's loop is busy, a listener's work is queued and the
  listener returns first, so an action's focus, DOM read or `dataTransfer` read comes too
  late. `HE.preventingDefault` and `HE.stoppingPropagation` cover the two cases that
  matter most; the rest is upstream's to fix, low priority (HH-2).
- **Interactive SVGs (WP5.90, decision 73, #249).** An interactive SVG
  needs HTTPS or localhost: elsewhere the embed is the image, and a page
  the server prerendered with the frame is repaired when the program
  starts. WebRTC is not stopped in Chromium: an `RTCPeerConnection` with
  a STUN server of the SVG's choosing sends packets (`webrtc 'block'` is
  in the policy and Chromium does not know it); what can leave that way
  is the SVG's own content and what the reader types into the frame,
  never the wiki's. Offline, or on the kept copy, the image shows only if
  the browser has the plain file: the page does not fetch it as well
  while online. A server that goes away while a live page is open leaves
  a frame that fails on its next load, which the page cannot tell from
  success. `frame-src 'self'` is not narrowed to the attachments' path.
  The guide has no live interactive example. The pull request was merged
  on the owner's word before a CI run of its own head had finished (the
  runs before it stopped on #243's task boxes or were restarted by the
  stack's rebases); main's run on the merge is its first whole one.
- **TODO lists (WP5.91, decision 74, #243).** Left on purpose: an
  administrator switching a space between blog and ordinary while a
  reader has unsaved ticks on its home page loses those ticks (the shell
  swaps the two views on a successful reload); signing out unmounts an
  editor with unsaved text (its autosaved draft remains); a task box
  clicked before the program has loaded is ticked by the browser and set
  back by the program's first render, with nothing staged; commonmark
  reads an item without a box as the start of another list, so
  `{.sorted}` reaches only the run of tasks before it. The late answers
  left are WP5.95.
- **CI and the runners' Ubuntu mirror (#247).** On 2026-11-11 GitHub's
  runners could not resolve their mirror for hours. Every native job now
  restores the cache of apt archives and installs with no `apt-get
  update` and no network when the cache holds what the image's index
  names; otherwise the update runs bounded (45 seconds, no retries).
  When the mirror is down and the cache lacks a version the index names,
  the job fails, as before: installing older cached versions was built
  and cut, since it meant resolving dependencies by hand against apt.
- **GitHub's cache limit and main's dependency store.** The repository's
  10 GB of Actions caches hold about 1.3 GB for each open pull request
  (the two cabal stores and the two build snapshots). With six open on
  2026-11-11, GitHub evicted main's native dependency store, and every
  new pull request then built its dependencies from scratch (30 to 45
  minutes a job) until main saved one again. `ci-prune-caches.sh` keeps
  one copy a ref; nothing keeps the total down. A pull request that
  restored main's store and built no new dependency need not save a copy
  of its own.
- **Stacks (#246).** A stacked pull request's base is set before its
  branch is pushed: a run takes the base its pull request had when the
  push arrived, and a change of base starts none. After each merge of a
  stack GitHub rebases the branches above, so their CI starts again on a
  tree that has not changed.
- **Tests that fail under load, cause not shown.** The server's smoke
  test stopped in a sign-in step in 4 of 12 local runs on a loaded
  machine ("Sign in with Fake", `signInThroughTheForm`: the steps click
  `.sign-in-toggle` right after a plain `goto`; a click before the
  listener is attached is the guess). wiki-core's `HtmlCost` timing test
  ("elements nested deep") failed twice in whole-suite runs on the shared
  machine and passed alone.
- **The editor's folding (WP5.96, #252).** In the source editor a block
  spoiler and a section whose heading is a spoiler fold, by CodeMirror's
  own folding fed with ranges the wiki's parser names
  (`Wiki.Core.Markdown.Folds`; every block carries the first and last
  line of its source, `Ast.parseWithSpans`). A fold belongs to its first
  line: a line break put anywhere in that line opens it, and so does any
  edit inside it. Left: a heading in a quotation, a list or a box gets no
  fold (the parser gives no lines there); a text with `\r` gets none (the
  parser and CodeMirror count its lines differently); folds do not
  survive a reload; fold-all is not offered (AltGr sends Ctrl+Alt on
  Windows, and its keys would catch typed brackets).
- **A browser spec that depends on its neighbours.** Emoji's "inserts the
  emoji chosen in the toolbar's menu" fails when run in one group with the
  editor's other specs and passes alone, on `main` as on every branch
  (Enter in the empty emoji search is expected to be prevented and is
  not); CI's sharding happens to pass it. Nobody has looked for the cause.
- **Two pull requests merged without a run together broke `main`
  (2026-11-13, #261).** #255 added a top-level `writable` to
  `Wiki.App.View.Common` and #259 bound a local `writable` in
  `Editor.hs`; each was green alone, `-Werror=name-shadowing` refused
  the pair, and every job of `main` failed for two hours. A pull
  request's run tests its merge with the base as the base was when the
  run started: two pull requests green at once say nothing of the two
  together. A stack avoids it (each run includes the one below); so
  does merging one, then letting the other's run finish on the new
  base. And while `main` does not build, the `native (sqlite)` job of
  every pull request fails, the fix's own included: it builds the base
  branch's `wiki-server` first, for the upgrade's rehearsal.
- **The browser tests' bundle after #266 (WP5.107).**
  `wiki-app/test/web/bundle.sh` keeps a finished bundle under
  `dist-newstyle/wasm/test-bundle/<digest>/` and copies it while the
  contents of what it reads are unchanged (everything under `web/` and
  `wiki-app/test/web/`, both lockfiles, npm's record of what is
  installed, Node's version, `HALOGEN_BASE_PATH`); a small run went
  from about 20 s to 11 s. A directory under a digest's name is whole
  or absent: it gets the name by one rename and loses it by one rename
  before anything in it is deleted, and a copy is compared with the
  bundle's list of files before it is used. Not seen by the digest: a
  file changed by hand inside `node_modules`
  (`WIKI_TEST_BUNDLE_REBUILD=1` builds whatever the digest says).
  GitHub's runners restore nothing of that directory, so CI gains
  nothing and builds the bundle once per job as before. `mv -T` and
  `xargs -r` are GNU's: on another system the script would build every
  time rather than keep.
- **A move to another slide after #269 (WP5.105).** The cost was not
  the distance: any move of the cursor to another slide made the
  preview parse the whole unchanged deck twice (its render, and the
  look-up of the people mentioned), about 1.1 s each in wasm on 60
  slides of 100 lines. `Preview` now keeps `Parsed` (the text, its
  deck, the logins mentioned) and parses once for a text; a move costs
  about 0.1 s where it cost 2.2 to 2.8, and a browser example holds it
  under a second. `toolchain/measure-slide-jumps.mjs` times each move
  on a generated deck against the built demo. Left: of that 0.1 s, 60
  to 75 ms is the preview rendering every card and Halogen comparing
  them, which grows with the deck; the cards cannot be memoized at the
  pin, because a thunk that compares equal is skipped with its child
  slots unvisited (`Halogen.VDom.Thunk.patchThunk`) and the render
  pass finalizes every child not visited, so a memoized card's islands
  would be torn down (read in the code, not run; haskell-halogen
  should carry a skipped thunk's slots over). A keystroke's own
  handler on that deck is 47 to 90 ms. The pause after typing is
  WP5.108.
- **A view closed as it opens, after #268.** CI met it twice in a row:
  a view unmounted within milliseconds of its mount left one owner of
  attachments' addresses registered in the tab. Nothing of a view runs
  after its finalizer (the pinned haskell-halogen cancels its fibers
  and subscriptions); the hole was that `Body.ensureOwned` and
  `beginOwned` registered the owner through `lift`, on a worker
  thread, and wrote it into the view's state in the next step, which a
  close between the two never took. The rule, in `Body.Owners`: the
  backend's part and the write to the state are one step of the view's
  program (`H.liftEffect`), so a close comes before both or after
  both; `newUrlOwner` and `releaseUrls` must not wait. The embedded
  deck's watch had the same shape and was fixed by reading; the other
  views are WP5.109. The example that holds it closes each view at the
  hold of its first registering action: on the code before, another
  backend action straddling the registration could take the hold and
  that route would pass falsely (never seen).
- **Events the browser fires late (found by #268's CI run).** The
  Playwright driver's `settle` ends after one background task and an
  idle probe, which can be before an event the browser sends with the
  next animation frame: a modal `<dialog>`'s `close` after Escape (not
  yet fired in 19 runs of 40 on a bare page), `popstate` after a
  page's own `history.back()`. The program is idle then, so
  `waitQuiet` is no signal. A test whose read depends on such an event
  listens for it itself before the action and waits for it (`afterEvent`
  in `wiki-smoke/demo/Demo/Looks.hs`, through a promise: the page's
  policy refuses `waitForFunction`). The demo's suite was read for it
  (38 pairs, 3 fixed); `wiki-smoke/server/` and `wiki-smoke/src/` were
  not, and go with WP5.98 (d).
- **The server's smoke suite after #267 (WP5.98c).** Found by the port
  and left: "Back to editing" in the editor's preview, with an SVG
  there that navigates its own frame, undoes the frame's navigation;
  the SVG navigates again, and Back is stuck in the preview (inferred
  from the history's entries, not reproduced by hand). After its own
  comment on an encrypted page the page reads the threads twice (after
  the POST and, probably, when the live channel reports the comment).
  A failure in a smoke suite goes through `Wiki.Smoke.Api.failure` or
  `expectationFailure`, never `fail`: `fail` in `IO` carries a call
  stack only from GHC 9.14's base, so on 9.10 and 9.12 a `HasCallStack`
  above it is a redundant constraint, an error under `-Werror`, and the
  failure names no line. What the Playwright driver lacks, with what
  the wiki does instead, is written for haskell-halogen's owner
  (response bodies, CDP events, request bodies in the log,
  `waitForFunction` under the server's policy, a history step that
  moves a frame, `exposeFunction`, popups, a hold by resource type).
- **The editor's search after #263.** Codex ran eight rounds (3, 2, 2,
  2, 3, 2, 1, 0); most findings came from leaning on
  `@codemirror/search` for more than its cursors (its `test` and
  `wholeWord` options end a multiline search at the first rejection;
  its step and replace commands start a cursor at the selection; its
  replacement writes an unmatched group as "undefined"). What is left
  of the library is the query's parsing and its two regular-expression
  cursors; the wiki's own loop over the text would be about thirty
  lines, to consider if the cursors are found at fault. Left as they
  are: a plain query runs as an escaped regular expression, so no
  Unicode normalisation (a composed é does not match a decomposed
  one); the replacement is literal but for `$&`, `$1` to `$99` and
  `$$`, so a line break cannot be written with `\n`; the count stops
  at 1000 ("1000+", rows past it say "matches not counted"); "k of N"
  does not name a match of no length; repeated Replace and Replace all
  can differ where a match depends on its neighbours (whole word,
  look-around, word edges), as in any editor; Escape in the text closes
  the search and no longer makes one cursor of a selection; nothing
  opens the panel without a keyboard; the sticky panel's height when
  the toolbar wraps differently is not tested. A text with carriage
  returns has its slides now (fit marks, the preview's following),
  except one where two slides, or the preamble and a slide, start on
  one of CodeMirror's lines.
- **The slides' rows after #259 (decision 77).** Codex ran nine
  rounds (6, 2, 3, 1, 2, 1, 1, 1, 1 findings, most of one family: the
  caret the author sees and the master's selection in different
  places); the invariant and a seeded random walk in the browser
  (three seeds of fifty steps in the suite) hold that family. Left: a
  text with carriage returns is edited by rows and comes back byte for
  byte, but its rows have no fit marks and the preview does not follow
  the cursor's slide, since `Slides.slideSpans` gave no slides for a
  text with `\r` (fixed in #263, see the search's note). A drag of a slide is HTML5 drag
  and drop: none by touch. The focus a move of DOM takes from an
  editor is given back by watching the element for one second
  (Halogen has no hook after its patch). The textarea shows above the
  disabled rows while CodeMirror loads. The walk's quiet waits are
  fixed times, and its three examples add about 75 s to a browser
  shard that has 600. Not this package's, found by its measures: a
  code block of 500 lines stalls the page about a second after each
  pause in typing, in Raw as in a row (the check, the preview's
  highlighting and the slides' measures). The forwarding between the
  master and the rows is about 300 lines of JavaScript, glue around
  CodeMirror's dispatch that could not be Haskell's.
- **Encrypted spaces after #255 (decision 80).** Left on purpose or
  not possible: a reader who never read a page under its new
  encryption can be shown its old chain; grants of a space's key are
  sealed and not signed, so the server could seal a key of its own
  making to a reader (part 1's trust model); versions from before
  versions were numbered cannot be checked, comments are not chained,
  and the browser cannot tell a page the server leaves out of a
  conversion's or an export's list. On PostgreSQL the plain text of a
  converted space stays in the database's files until a vacuum. The
  search finds nothing of a space behind a gate not confirmed, and the
  server's search finds none of a space's plain pages until its
  conversion ends. A tab that believes a space plain lists only plain
  pages after a conversion started elsewhere, until a request is
  refused. Versions and threads a tab read plain stay cached there
  after the page was encrypted elsewhere. A history entry or tab title
  made before #255 can hold a decrypted title. A reader granted after
  the readers' list was fetched shows as a bare login until the key is
  opened again. The whole-wiki export names the encrypted spaces it
  leaves out; its note and the assistant's line ("what you ask about
  leaves this browser decrypted") have no browser spec. Not covered by
  tests: the lease's expiry by time, the "Take over here" button
  itself, attachments of encrypted pages fetched with `no-cache`.
  Moving a space to a destination the encryption rule refuses, and
  turning "private from parent" off under a plain parent, are offered
  and then refused. Codex's tenth round ran on the merged head and found
  one thing, fixed in #264 with what its own three rounds found: with
  the cached list of spaces emptied by a write, the plain route was
  chosen without the gate. The rule since: what a tab knows about gates
  does not depend on a cache a write can empty (the last list read is
  kept beside it); one function, `closedIn`, decides every gate; a list
  read from the server is the truth, and for a space it leaves out or
  shows plain everything held is let go; a search reads the list once
  and decides both its halves from it. Left by #264: a tab that has
  read no list takes the plain route unchecked (the shell always reads
  one first); a list gone stale through a change made elsewhere behaves
  as before; `postDetails`, `pageBacklinks`, `getDraft` and
  `fetchExport` have no gate of their own and are reached only after a
  gated read.
- **Encrypted spaces after #251 (decision 76).** The server still sees:
  the words a reader searches for (the search page's address carries
  them, and the server searches the plain spaces with them), sizes of
  ciphertexts, who comments and when, that a page has attachments, a
  page's kind, times and place, a space's name. Revoking a reader in a
  parent's dialog renews the parent at once; each subspace open to it
  waits for an administrator to open it, and sealing a subspace makes a
  renewal due with none run. A rotation carries at most 20,000 page keys
  and 5,000 readers. The browser's own "open image in new tab" on an
  encrypted SVG is a document of the wiki's origin (no inline script
  runs). A tab running the program from before gets a refusal on
  "Encrypt this space…" until it reloads. Not tested: the renewal notice
  after a space is moved; a search with subspaces over an encrypted
  subspace; the activity view's words for an encrypted subspace's
  creation. `sealed_attachments.staged_blob` is an unused column, kept
  for the conversion.
- **A view's start and the server's HTML (found on #251).** The server
  takes a page's HTML when every `Initialize` has reached its first
  wait. A lift into the backend as the first step of a view's
  `Initialize` (registering an owner of attachment addresses) came
  before the step that tells the shell which page is shown, and the
  front page's preview tags were then sometimes missing, depending on
  what else the process rendered. Nothing a view does before telling the
  shell may be a wait.
- **`toolchain/test-postgres-namespaces.sh` (#244, fixed in #251).** It
  killed a test run when it saw a database of the run's, which could be
  one an example drops at once; it now waits for the run's template
  database. One failure in 38 runs is not explained: sessions on the
  killed run's databases thirty seconds after the kill; the message now
  prints them. It failed the same way once more on #265's `native
  (postgres)` job (2026-11-13) and passed on the re-run: thirty seconds
  is a clock where the script needs a condition; it goes with the raced
  tests listed under WP5.98.
- **The compilers below the default (#265).** GHC 9.12.4 is built by a
  weekly job only (and by hand), so an error that only it reports is
  seen up to a week after its pull request: #265's was a local function
  in a test whose type 9.12 does not infer. GHC 9.12.4 is installed on
  the owner's machine: `cabal build -w ghc-9.12.4
  --builddir=dist-newstyle/native-912 <targets>` shows such an error
  before a push, and most of what the floor's GHC 9.10.3 reports too.
- **Presentations (WP5.97, decision 77, #253).** Left out: the detached
  preview window shows a presentation as a document; no theme from the
  space's settings and no look per slide; on a slide, and in the editor's
  document preview, an embed with the class is a link; an embed by an old
  version's address is a link; a presentation as a blog post is listed as
  a document; history does not record a change of kind; `[[!slides]]` is
  no longer read and old decks got no migration. Not pinned by a test:
  the viewer of a deck in an encrypted space; an answer read before a
  sign-out arriving after it (the viewer's generation check covers it in
  code). A viewer's id prefix is written at the two producers the
  renderer does not prefix itself (raw HTML, the generated contents),
  not in one pass over the rendered deck: the one pass broke navigation
  in the built program for a reason not found. The drag spec timed out
  once on CI waiting for the handle to be "visible and stable" and not
  again; no loop of measures was found (WP5.98's throttled run). A
  screen narrower than 1024 px can cut more than a slide's mark says. A
  Mermaid diagram not drawn yet is measured as it stands and again when
  drawn, so a mark can be green for a moment. (The editor's slides
  are rows since #259: see "The slides' rows after #259".)
- **Dependencies to watch (the audit of 2026-11-12, WP5.100).** 391
  packages over the native, wasm and maker builds; none deprecated, no
  open advisory against a version in use. cborg and serialise,
  postgresql-simple, webauthn and protolude build only through
  `allow-newer` (21 entries are still needed), so every GHC bump depends
  on them. tagsoup (2019) parses page HTML on the server and in the
  browser; xml (2015) comes with pandoc and texmath and can see MathML
  from a page during an export: both pure Haskell, so the risk is time
  and memory. cryptohash-md5 and -sha1 remain through other packages.
  Not tested after the bump: outbound TLS on tls 2.5.1 (SMTP with
  STARTTLS, a real OIDC provider), the Docker image's build, the refusal
  against a really old SQLite. cabal's "legacy fallback" lines come from
  six packages (appar, byteorder, erf, xml; entropy, xml-conduit) and
  mean only that each is built whole.

## Assumptions

- Attachments: at most 50 MB a file, on local disk.
- The admin listener is a second TCP port on loopback (`127.0.0.1:8081`); a Unix socket
  with file permissions would be stricter on a shared machine and is a small change if
  wanted.

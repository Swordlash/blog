# Plan: a Confluence-style wiki in Halogen

A wiki of spaces, subspaces and pages, written in Markdown, built on
[haskell-halogen](https://github.com/Swordlash/haskell-halogen). This document is the
working plan: what the wiki has to do, the decisions taken, the work still to do, and
what is known to be missing.

It does not keep the history of the work done. What each work package built, and why,
is in its pull request, in the commits and in the packages' `CHANGELOG.md` files. Code
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
   so neither is needed. `clay` is optional:
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
    `WIKI_TEST_WIZARD=1`, not in CI: it compiles brick).
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
    readable.
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

## How work is organised

The session the owner talks to implements every work package itself, one at a time,
without subagents (the owner, 2026-10-31: "Usuń wzmiankę o wykonywaniu zadań przez
subagentow opus, będziesz wykonywać wszystko sam"). Before a pull request merges, it is
reviewed with Codex, `gpt-6.1-sol` at high reasoning effort, with the owner's key, as
`AGENTS.md` says; the session fixes the real findings and pushes, for three rounds at
most (the owner, 2026-11-02: "Zmniejsz max liczbe przebiegów do 3"; four before). The owner merges; the session
merges only when asked ("nie merguj sam, chyba że poproszę"). The session may hand a
commit it has good reason to trust to CI rather than run the whole gate locally first,
when nothing else is waiting on CI (the owner, 2026-10-31).

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

- **WP5.63 A copy button on code blocks** (the owner, 2026-11-05; one pull request).
  Every fenced code block on a page, in the editor's preview and in the guide gets a
  button in its top right corner that copies the whole listing to the clipboard: the
  code's text exactly as written (not the highlighter's markup, not the button's own
  label, with the final newline as the fence had it), through the clipboard API. The
  button is unobtrusive (shown on hover and on keyboard focus, always reachable by
  keyboard, labelled for assistive technology), says "Copied" for a moment after a
  click and "Copy" again after, and never ends up in the copied text, in the plain
  text, in search, in exports or in the feed. It works on the server-rendered page
  before the application runs (a listener in `web/src/islands.js`, as the spoilers'),
  and the DOM the server renders and the one the application adopts stay the same
  (the smoke test's adoption of every prerendered page passes). The package chooses
  where the button lives (inside the `<pre>` positioned over the code, or a wrapper
  around it) and says why; a scrolling listing (`{rows=N}`) keeps its button in view.
  The guide's Markdown page mentions it under Code. Tests: wiki-core (the rendered
  shape, the plain text without the button), browser (a click copies the code, the
  label changes and changes back, the button is not in the page's text), the smoke
  test. Docs: README's Markdown section, wiki-app's CHANGELOG.

### Later, or waiting for the owner

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
- **Going public** (WP5.1 and WP5.2, done on the repository's side; the steps are the
  owner's). Confirm decision 24; make the repository public; in Settings, Actions, set
  fork pull request workflows to require approval for all external contributors; turn on
  secret scanning and push protection; set Pages to deploy from GitHub Actions
  (Settings, Pages, Source); run the workflow once with `runner: hosted`. Before the
  flip: the `maintainer` address in the `.cabal` files and the pull request texts (some
  name the tailnet host) become public.

## Known gaps and notes

What the work done so far left out, found and did not fix, or learnt that later work
needs. Each was true when its package merged; check before relying on one.

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
- The smoke tests open pages with `serviceWorkers: "block"` (their Playwright routes do
  not see a worker's traffic); new parts need the same or a context of their own.
- The demo's address is in the README's links and in `Test.Readme.demoAddress`, and the
  README's examples quote demo pages: a change to a demo page under an example, or a
  renamed heading, fails the test, so the two change together. After a change to the
  wiki's look: `npm run build-wasm`, then `npm run screenshots`, and commit.

**Building**
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
  decide what to rebuild; after each save `toolchain/ci-prune-caches.sh` deletes the
  ref's older copies, so each ref holds one copy per cache and the repository's 10 GB
  limit no longer evicts `main`'s. The hosted `native` and `wasm` jobs hold
  `actions: write` for it (the wasm job on the owner's machine too, since permissions
  are per job). A pull request's run sees only its own ref's copies and `main`'s;
  `main`'s hosted wasm copy comes from the weekly scheduled run, from pushes that find
  the owner's machine busy, and from runs by hand with `runner: hosted`, so a first
  hosted wasm run on a fresh ref is cold (about 35 minutes) until one of those has
  saved a copy. The stores keep a transitional restore key for the copies saved before
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
- A flaky server test (seen 2026-11-04 on #153, a run of `main`'s code): "the live
  channel checks once for each user whether they may read a page an event is about,
  not once for each tab" (`wiki-server/test/Test/Storage/Scale.hs`) counts the `BEGIN`
  statements while a hundred tabs hear an event and expects one per user; other
  transactions of the server that begin in that window (a "last seen" write, a
  notification) are counted too, so under load it sees more. Count the permission
  checks themselves, or the readers' transactions only, when it next fails.
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
  output goes to the terminal as well as the log; the xelatex item runs in every
  check-native call (a second or two with a working engine, up to 20 s with one that
  hangs) and, before the deploy's TeX step, shows the shell's PATH, which can differ
  from the service's; a server with `--no-pdf` keeps the PDFs off until the next
  deploy, even if a working TeX appears meanwhile; `check-tex.sh`'s default 20 s has
  no test of its own.
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

## Assumptions

- Attachments: at most 50 MB a file, on local disk.
- The admin listener is a second TCP port on loopback (`127.0.0.1:8081`); a Unix socket
  with file permissions would be stricter on a shared machine and is a small change if
  wanted.

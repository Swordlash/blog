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

- **Issue #120, the owner's editor improvements** (the owner, 2026-10-31, with answers
  the same evening). Cut into WP5.37 to WP5.45; WP5.37 to WP5.39, WP5.42 and WP5.43 are done, the rest
  follow below, in that order unless the owner says otherwise. Left out: C-like preprocessor macros (the owner: "probably not"; math
  macros and boxes cover the need); grammar checking beyond the browser's spelling,
  which CodeMirror already has on (later, perhaps LanguageTool; Grammarly offers no SDK
  any more). A multi-line `$$` block in a box that seemed to work only on one line
  works (the owner tried again; the parser reads every variant tried).
- **WP5.40 Boxes: numbers, titles, toolbar, colours.** Boxes are numbered per kind
  (Tip 1, Tip 2; Example 1 apart). A space chooses the form: within the page only
  (`3`), with the page's number (`2.3`: the page's position under its parent, in the
  space's order, by hand or not), or with the section too (`2.1.3`: `##` sections).
  `> [!TIP*]` is a box without a number, as LaTeX's `equation*`. Math in box titles
  (`$…$`, `$$…$$`). A "Box" button in the toolbar with the space's kinds in a list,
  and for an administrator "New kind…" there. A custom colour (a colour picker) beside
  the theme's.
- **WP5.41 An "Editor" tab in the settings.** The kinds of box move there from
  "Server". The built-in macros (`\Prob` and the rest) become a server setting there:
  a textarea filled with them on first opening, saved as typed, checked by KaTeX as
  the space's macros are (a sample formula typed under the block is typeset with it),
  and a warning naming the pages that use a macro being removed. In the editor, a
  button for the space's and the page's macros, editable by whoever may edit the whole
  space (the space's are on the space's page, "Math macros", today).
- **WP5.44 Stars and help.** A user stars pages (kept by the server, per user) and goes
  to them from a "Starred" list in the header. A help button (a "?" in a corner) opens
  a dialog with what the README and the guide say: TikZ, Mermaid, the kinds of box
  including the server's own.
- **WP5.45 Favicons from space icons, and an icon for the home page.** A space's icon
  can already be an uploaded image besides an emoji (`IconImage`, recorded in the audit
  log as "an uploaded image"). What is left: the home page gets an icon too, and the
  favicon follows them, the space's icon on the space's pages and the home page's icon
  for the wiki (today `web/index.html` names a fixed `icon.svg`). An SVG is served only
  as an image.

### Later, or waiting for the owner

- **Issue #122, the Web platform from Haskell** (the owner, 2026-11-02). The browser's
  own objects (window, navigator, crypto, history, location, document, elements,
  events) are read and called from Haskell through record fields, rather than through
  a one-line JavaScript function per field. Today `wiki-app/jsbits` has 141 functions in
  2012 lines, 96 of them three lines or shorter; about 50 of those only read a property
  or call one platform method (`navigator.onLine`, `history.go`, `event.key`,
  `event.detail`, `files[i].name`, `element.focus`, `URL.createObjectURL`). haskell-halogen
  core does the same in `Web.HTML.Window` and the other `Web.*` modules, through
  `browserJS` and `jsbits/web_browser.js`, and already has the newtypes (`Window`,
  `HTMLDocument`, `Element`, `Event`; `Foreign` is a `JSVal`). WP5.46, the fields in
  haskell-halogen (`Halogen.JSBits.Fields`, Swordlash/haskell-halogen#95), is done, and the
  wiki's pin is on it (#124). What is left:
  - **WP5.47 Use them in the wiki.** The one-line functions are replaced file by file (`browser.js`, `offline.js`, `object-url.js`,
    `search.js`, `slides.js`, `console.js`, and the platform parts of `editor.js`,
    `comments.js`, `assistant.js`), with the browser tests unchanged as the check. The
    wiki's own newtypes (a passkey's credential, the editor's host) use the same splice.
    Not moved, by decision 25: the glue around bundled libraries (`wikiIslands`, the
    CodeMirror editor object, `wikiArchive`, the assistant's SDKs, the vault's WebAuthn
    and WebCrypto flows) and the JavaScript-side handle tables (live listeners, preview
    watches, vault keys).
  It comes after WP5.40 to WP5.45.
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
- With the sidebar folded the editor should take the screen's width. In Chromium at
  1600px it does (1272px to 1528px); the owner saw it stay narrow, and the browser and
  window width are not known yet (WP5.37).
- Footnotes (WP5.42): in the editor's "Show preview" a footnote's number only scrolls
  to the note, with no history entry, since an entry there would take the Back that
  "Back to edit" makes. The hover is a native `title` with the note's plain text.
- Unclosed math in the editor (WP5.42): `$` before a number is read as a price when a
  word, punctuation or the line's end follows the number (`$5 each`, `$3.50`), so a
  formula such as `$5.` left open is not underlined. Multi-line `$$` or `\[` blocks are
  never checked.
- The server could cache `template.html` (optional, WP5.14).
- A second deployment (`--name`) on one machine cannot share port 443 and should use
  `--http` (WP4.18).

**Tests and CI**
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
- `PUT admin/settings` bodies must carry every field (`FromJSON` is derived).
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

# blog

A Confluence-style wiki, written in Haskell with
[haskell-halogen](https://github.com/Swordlash/haskell-halogen) and compiled to
WebAssembly for the browser.

What it is for: spaces and subspaces, each a tree of pages written in Markdown, with
Mermaid diagrams, LaTeX (inline and block), highlighted code, images, video and other
attachments, previewed live in the browser as you write. Users, groups and permissions
on spaces decide who may read, edit or administer what; a space can be public, which
makes the same application a blog.

How it is built: the browser application is Halogen components over a backend
interface, implemented once in memory (a serverless demo deployable as static files)
and once over HTTP to a Haskell server with persistence. Markdown is parsed and
rendered to Halogen HTML in the browser, so the preview never waits for a server.

So far there is the MVP demo: the whole reading and writing experience,
serverless, over an in-memory wiki seeded with demo content, deployable as static
files. Reloading the page starts it over: keeping pages is the server's job, in the
next phase. The plan of work is in [docs/PLAN.md](docs/PLAN.md): phases from the
serverless MVP demo through a server with persistence to authentication and
authorisation.

## What works

- Spaces in a tree, public or private, each holding a tree of pages; creating,
  renaming, moving and deleting spaces and pages as the permissions allow.
- Pages written in Markdown, whose syntax is described for authors in
  [docs/markdown.md](docs/markdown.md): GitHub's extensions, footnotes, alerts,
  wiki links, formulas drawn by KaTeX, diagrams by Mermaid, code highlighted by
  highlight.js, images, video and attachments.
- An editor with the Markdown beside a live preview, files dropped or chosen into
  it as attachments, Ctrl+S, a conflict shown in place when someone else saved
  first, and a guard against losing unsaved changes.
- Search by title and text from a box in the header (`/` to focus it), in every
  space or in one, with a page of results at an address of its own.
- Three demo users and nobody, switched between in the header instead of a
  sign-in, each seeing the wiki through their permissions.
- An address for every route, and a prerendered page for each route the demo
  starts with, so that a link or a reload lands on the page before the program
  has loaded.

## Running the demo

Build it and serve it on <http://127.0.0.1:8080>, with the toolchain below:

```sh
npm ci
npm run serve-wasm      # runs build-wasm first; or build-wasm alone, to build only
```

Or, without a toolchain, take the page a CI run built: download the `app`
artifact of a run of the `CI` workflow on GitHub (the run's page, under
*Artifacts*), unzip it, and serve the directory with any static server that
answers an address with no file of its own with the directory's `404.html`, as
GitHub Pages does. `npx http-server <dir>` does:

```sh
unzip app.zip -d app && npx http-server app -p 8080
```

The front page invites you to the tour, which says what to try. Nothing you do is
sent anywhere, and a reload starts the demo over.

## Working on it

`AGENTS.md` describes how the work is organised: a planning session cuts the plan into
work packages and delegates each to an implementing agent. Toolchain and conventions
follow haskell-halogen's.

## Toolchain

The toolchain is haskell-halogen's, at the same pins: GHC 9.14.1, cabal 3.16.1.0,
`wasm32-wasi-ghc` 9.14.1.20260731 from ghc-wasm-meta, Node 24 or later and Chromium
for Playwright. On x86_64 Linux one script checks what is available and installs
what is missing:

```sh
sh toolchain/bootstrap.sh
```

It reuses the pinned GHC, cabal and wasm compiler found on `PATH`, and any Node
24 or later with npm. When a compiler is missing, it installs ghcup into `~/.ghcup`
(unless one is already on `PATH`) and through it the pinned compiler, making it
ghcup's default. Missing tools go to: the wasm sysroot into `~/.ghc-wasm`; Node into
`~/.wiki-toolchain/node`; Chromium's headless shell where Playwright keeps its
browsers; and fourmolu, the formatter, into ghcup's bin directory (its release binary,
or built from Hackage where GitHub's downloads are refused, as in Claude Code's cloud
sessions); and native `alex` and `happy` (pinned, happy below 2.2) into the same
directory, which the wasm build of `ghc-lib-parser`, under the `hh` quoter, runs from
`PATH`. Debian packages it needs (GMP's headers, `zstd`, `jq` and a few more) it
installs with `apt-get` when it runs as root or with password-less `sudo`, and names
otherwise. Then it builds the dependencies of `cabal.project` and `cabal-wasm.project`
into the cabal store, so the first build compiles only this repository.

The wasm sysroot is reused when its `.paladyn-rev` matches the pinned ghc-wasm-meta
revision (or a previous bootstrap marked that revision) and its tools and libc are
present and working. An existing unrecognised or incomplete sysroot is refused before
any changes: inspect it and move it aside yourself if you want a fresh install.
The bootstrap reuses the project's installed Playwright when it matches the lockfile,
otherwise keeps its own installation under `~/.wiki-toolchain`. It reuses Chromium's
cache using the executable path reported by that Playwright's browser registry, and
checks that the browser launches on each install-mode run. The formatter and parser
generators must match their exact pins; alex and happy are detected with `--version`.

Inspect the decisions without downloading tools, writing logs or changing installations:

```sh
sh toolchain/bootstrap.sh check
```

This lists tools to reuse or install and exits unsuccessfully for a blocked sysroot.
For a strict check of the current shell and the npm dependencies a command uses:

```sh
sh toolchain/bootstrap.sh ready build-wasm  # or build-native / serve-wasm / test-native / test-wasm
```

`npm run build`, `npm run serve`, `build-native`, `build-wasm`, `serve-wasm` and the
test commands (`test-native`, `test-wasm`, `test`, `dev-test`) automatically load an
existing `~/.wiki-toolchain/env`, then run this check before compiling, testing or
starting a server. No manual environment loading is needed for these npm
commands; if the file is missing, an already configured `PATH` still works.
Managed Node and ghcup directories take precedence even if they were already later
on `PATH`. npm also applies the current environment directives after loading an old
generated env file, so existing installations need no bootstrap reinstall for this fix.
`build` and `serve` are aliases
for the wasm commands and accept the same extra cabal arguments after `--`. The gate
checks the complete pinned toolchain, including the formatter, parser generators and
Chromium cache; browser launch validation stays in install mode. It checks package
entry points and local executables needed by the selected command (`http-server` for
serve, and the islands packages and esbuild for wasm), without downloads or writes.
Missing tools or incompatible versions stop with instructions to run
`sh toolchain/bootstrap.sh toolchain`, then retry. Missing npm dependencies require
`npm ci` separately. A direct `bootstrap.sh ready` check uses the caller's `PATH`
without loading the environment; for direct tool commands in an unloaded shell,
run `. ~/.wiki-toolchain/env`. The wasm environment is checked in a subshell and is still
loaded automatically by the wasm scripts; do not export its wasm `CC` globally.

Install modes also check system packages and the cabal index. Each step checks whether
its tool is already there and working, so running it again is quick and repairs missing
tools. Commands' output goes to
`~/.wiki-toolchain/bootstrap.log`. For direct `ghc` and `cabal` commands, put
`. ~/.wiki-toolchain/env` in your shell profile to load their `PATH`; npm build/serve
commands load it themselves. The build scripts source
`~/.ghc-wasm/env` for the wasm tools themselves. `sh toolchain/bootstrap.sh toolchain`
skips the store.

The discovery and reuse regression tests run with fake tools and isolated temporary
homes, without downloads or changes to your installations:

```sh
sh toolchain/test-bootstrap.sh
```

Claude Code cloud sessions run it from the `SessionStart` hooks in `.claude/`: the
toolchain before the session starts, the store in the background. A command that needs
the store complete can wait for that with `sh toolchain/bootstrap.sh warm`.

## CI

`.github/workflows/build.yml` runs three jobs on every pull request to `main` and every
push to it: `native` (build and test natively), `wasm` (build for wasm, run the test
suites and the smoke test in headless Chromium, and on a hosted runner keep the built
page as the run's `app` artifact) and `format` (`npm run format-check`).

They run on the self-hosted runner registered for this repository (`runs-on: self-hosted`
in every job); GitHub's hosted runners are refused by the account's Actions budget. To go
back to them, change `runs-on` to `ubuntu-latest`: the hosted steps are kept. On a hosted
runner the toolchain comes from `haskell-actions/setup`, `setup-node`, ghc-wasm-meta
and caches of the cabal store and the wasm tools, as in haskell-halogen. On a
self-hosted runner every job runs `sh toolchain/bootstrap.sh toolchain` instead, which
installs the toolchain into the runner user's home the first time (a while: GHC, the
wasm compiler, Node, Chromium, fourmolu) and only checks it afterwards, and puts it on
`PATH` with `sh toolchain/bootstrap.sh path`. Nothing is cached or uploaded to GitHub
there (the account's artifact storage quota refuses uploads): the toolchain, the cabal
store and the built page stay on the machine. One runner runs one job at a time, so
the three jobs queue.

To run CI on a machine of your own (x86_64 Linux, Debian or Ubuntu):

1. Register a runner for this repository (Settings, Actions, Runners, New self-hosted
   runner, Linux x64), running as an ordinary user. Its own user is best: the
   bootstrap makes the pinned GHC and cabal ghcup's defaults for whoever runs it.
2. Install, once, the Debian packages the bootstrap and Chromium need, since the
   runner cannot `sudo`. The bootstrap's own are `build-essential curl git jq unzip
   xz-utils zstd libgmp-dev`. Chromium's are those `npx playwright install-deps
   --dry-run chromium` names in a checkout after `npm ci` (and that the bootstrap
   prints when Chromium does not start); on Ubuntu 24.04 they are `libasound2t64
   libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64
   libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0
   libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0
   libxrandr2`; on Ubuntu 22.04 and Debian 12 they are the same without the `t64`
   suffixes, and 22.04 adds `libwayland-client0`.
3. Re-run the workflow.

## Layout

| Directory | Package | What it is |
| --- | --- | --- |
| [wiki-core/](wiki-core/) | `wiki-core` | The domain: types, Markdown rendering, permission rules. Native and wasm. |
| [wiki-api/](wiki-api/) | `wiki-api` | Request and response types (aeson), shared by the client and the server. |
| [wiki-app/](wiki-app/) | `wiki-app` | The Halogen application: `wiki-app` (the wasm program) and `wiki-app-prerender` (native: writes the page with the application already rendered into it). |
| [wiki-server/](wiki-server/) | `wiki-server` | The server, native only. A placeholder until Phase 2. |
| [web/](web/) | | The page around the application: `index.html`, `index.js` (loads `app.wasm`), CSS, and `bundle.sh`, which bundles the islands' libraries from `web/src/`. |
| [toolchain/](toolchain/) | | Build and test scripts, adapted from haskell-halogen's. |

haskell-halogen's packages come from one `source-repository-package` stanza in
`cabal.project`, pinned to a commit. `cabal.project` builds every package natively;
`cabal-wasm.project` imports it and builds for wasm with the pinned cross compiler.

## Commands

```sh
npm ci                          # once: Playwright, http-server, esbuild, KaTeX, Mermaid, highlight.js
npm run build-native            # every package, host GHC, into dist-newstyle/native
npm run test-native             # the test suites, natively
npm run build-wasm              # wiki-app to wasm, a prerendered page per route, the islands bundle, into dist-newstyle/wasm/public/app
npm run serve-wasm              # build-wasm, then serve it on http://127.0.0.1:8080
npm run test-wasm               # the test suites on wasm, under Node; wiki-app-browser-test in Chromium
npm run test                    # test-native, then test-wasm
npm run smoke-test              # the built page in headless Chromium: every prerendered route, a walk with back, forward and reload, dark and phone
npm run dev-test                # wiki-app-browser-test in browser GHCi, rerun on save (needs ghciwatch)
npm run format                  # fourmolu over every package
npm run format-check            # the same, failing on what it would change (as CI does)
npm run clean                   # remove dist-newstyle/wasm/public
```

The islands bundle is `web/bundle.sh <output-dir>`: esbuild bundles KaTeX and
highlight.js (with `web/src/islands.js`) into `islands.js`, which publishes
`globalThis.wikiIslands`; Mermaid into `islands/` as ES modules that `islands.js`
imports the first time it draws a diagram; and KaTeX's stylesheet and fonts into
`islands.css` and `fonts/`. `build-wasm` runs it into the page it builds, and
the browser suite's `wiki-app/test/web/bundle.sh` into the test page. npm 11
runs esbuild's install script only because `package.json`'s `allowScripts`
approves it (`npm install-scripts approve esbuild`).

The browser suite, `wiki-app-browser-test`, is a wasm reactor built with
hspec-halogen: `toolchain/wasm-test-wrapper.sh` recognises it and hands it to
the `hspec-halogen` executable (built natively by `toolchain/build-hspec-halogen.sh`),
which loads it into headless Chromium. Natively it builds and reports that it
skipped. `npm run dev-test` runs it in browser GHCi under ghciwatch;
`sh toolchain/dev-test.sh --repl` and `--open-browser` (from another terminal)
do the same by hand, with `:main` typed into GHCi.

The application routes by path (`/s/<space path>/p/<page path>/`, see
`Wiki.App.Route`) under the page's `<base href>`, which `wiki-app-prerender` writes
from `HALOGEN_BASE_PATH` (default `/`), so the built directory can be served from a
sub-path: `HALOGEN_BASE_PATH=/wiki/ npm run build-wasm`. It writes an `index.html` for
every route the demo starts with and a `404.html` for the rest, which GitHub Pages and
http-server serve for an address with no file.

`serve-wasm` opens the page in a browser; set `PORT` for another port, `NO_OPEN=1` to
not open one. Builds go to `dist-newstyle/native` and `dist-newstyle/wasm`; always
build for wasm through the `toolchain/` scripts, which pass the cross compiler to
cabal explicitly and keep the wasm tools' `CC` away from native builds.

The test suites are hspec, each `main-is: Test.hs` aggregating `Test.*` modules; a
new test module goes into the suite's `other-modules` and `test/Test.hs`. Run one
suite, or one test, with hspec's `--match`:

```sh
cabal test wiki-core:test:wiki-core-test --builddir=dist-newstyle/native \
  --test-options='--match "/Slug/"'
sh toolchain/test-wasm.sh --test-options='--match "/Slug/"'   # extra args go to cabal
```

`npm run format` needs fourmolu 0.21.0.0 on `PATH`; `toolchain/bootstrap.sh` installs it.

## License

Proprietary; see `LICENSE`.

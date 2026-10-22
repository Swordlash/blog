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

So far there is the scaffold: a placeholder page that builds and runs. The plan of work is in
[docs/PLAN.md](docs/PLAN.md): phases from a serverless MVP demo through a
server with persistence to authentication and authorisation.

## Working on it

`AGENTS.md` describes how the work is organised: a planning session cuts the plan into
work packages and delegates each to an implementing agent. Toolchain and conventions
follow haskell-halogen's.

## Toolchain

The toolchain is haskell-halogen's, at the same pins: GHC 9.14.1, cabal 3.16.1.0,
`wasm32-wasi-ghc` 9.14.1.20260731 from ghc-wasm-meta, Node 24 and Chromium for
Playwright. On x86_64 Linux one script installs all of it:

```sh
sh toolchain/bootstrap.sh
```

It installs ghcup into `~/.ghcup` (unless one is already on `PATH`) and through it GHC
and cabal, making them ghcup's defaults; the wasm sysroot into `~/.ghc-wasm` and the
cross compiler through ghcup, as haskell-halogen's CI does; Node into
`~/.wiki-toolchain/node`; and Chromium's headless shell where Playwright keeps its
browsers. Debian packages it needs (GMP's headers, `zstd`, `jq` and a few more) it
installs with `apt-get` when it runs as root or with password-less `sudo`, and names
otherwise. Then it builds the dependencies of `cabal.project` and `cabal-wasm.project`
into the cabal store, so the first build compiles only this repository.

Each step checks whether its tool is already there and working, so running it again is
quick and quiet, and finishes an install that was interrupted. Commands' output goes to
`~/.wiki-toolchain/bootstrap.log`. Afterwards, put `. ~/.wiki-toolchain/env` in your
shell profile for `ghc`, `cabal` and Node 24 on `PATH`; the build scripts source
`~/.ghc-wasm/env` for the wasm tools themselves. `sh toolchain/bootstrap.sh toolchain`
skips the store.

Claude Code cloud sessions run it from the `SessionStart` hooks in `.claude/`: the
toolchain before the session starts, the store in the background. A command that needs
the store complete can wait for that with `sh toolchain/bootstrap.sh warm`.

## Layout

| Directory | Package | What it is |
| --- | --- | --- |
| [wiki-core/](wiki-core/) | `wiki-core` | The domain: types, Markdown rendering, permission rules. Native and wasm. |
| [wiki-api/](wiki-api/) | `wiki-api` | Request and response types (aeson), shared by the client and the server. |
| [wiki-app/](wiki-app/) | `wiki-app` | The Halogen application: `wiki-app` (the wasm program) and `wiki-app-prerender` (native: writes the page with the application already rendered into it). |
| [wiki-server/](wiki-server/) | `wiki-server` | The server, native only. A placeholder until Phase 2. |
| [web/](web/) | | The page around the application: `index.html`, `index.js` (loads `app.wasm`), CSS. |
| [toolchain/](toolchain/) | | Build and test scripts, adapted from haskell-halogen's. |

haskell-halogen's packages come from one `source-repository-package` stanza in
`cabal.project`, pinned to a commit. `cabal.project` builds every package natively;
`cabal-wasm.project` imports it and builds for wasm with the pinned cross compiler.

## Commands

```sh
npm install                     # once: Playwright, http-server, esbuild
npm run build-native            # every package, host GHC, into dist-newstyle/native
npm run test-native             # the test suites, natively
npm run build-wasm              # wiki-app to wasm, prerendered, into dist-newstyle/wasm/public/app
npm run serve-wasm              # build-wasm, then serve it on http://127.0.0.1:8080
npm run test-wasm               # the test suites on wasm, under Node (browser suites in Chromium)
npm run test                    # test-native, then test-wasm
npm run smoke-test              # the built page in headless Chromium: it renders, mounts, counts clicks
npm run format                  # fourmolu over every package
npm run clean                   # remove dist-newstyle/wasm/public
```

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

`npm run format` needs `fourmolu` on `PATH` (`cabal install fourmolu`).

## License

Proprietary; see `LICENSE`.

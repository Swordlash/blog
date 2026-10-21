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

Nothing is built yet. Work is planned in phases, from a serverless MVP demo through a
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

## License

Proprietary; see `LICENSE`.

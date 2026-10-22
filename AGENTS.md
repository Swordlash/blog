# AGENTS.md

This file provides guidance to AI coding agents working with code in this repository.

## What this is

A Confluence-style wiki built on [haskell-halogen](https://github.com/Swordlash/haskell-halogen):
spaces, subspaces and Markdown pages (Mermaid, LaTeX, highlighted code, attachments) with a
live preview rendered in the browser, users and groups with permissions on spaces, and a server
with persistence behind a backend interface the browser application is written against. The
plan of work, with the decisions taken and the work packages, is `docs/PLAN.md`; read it
before anything else. The repository layout, once it exists, is the one the plan describes:
`wiki-core` (domain, Markdown rendering, permission rules), `wiki-api` (shared request and
response types), `wiki-app` (the Halogen application), `wiki-server` (servant, SQLite), `web/`
(page, bundle script, CSS) and `toolchain/` (build and test scripts).

## How work is organised

Two roles, two kinds of session.

**The planning session** (the one the owner talks to) owns `docs/PLAN.md`. It does not
implement work packages itself. It cuts the plan into work packages, writes a brief for each,
delegates it to an implementing agent, reviews what comes back, and amends the plan: a
decision confirmed or changed, acceptance criteria met or carried over. It may make small
edits of its own (the plan, a README line, a one-line fix found in review). Changes to
`docs/PLAN.md` alone go straight to `main`, without a pull request; code goes through one.

**An implementing agent** does one work package. It is a subagent of the planning session.
In Claude Code, start it with the `implementer` definition in
`.claude/agents/implementer.md`: Opus 5.5 at high reasoning effort. In Codex, start a
subagent with model `gpt-6.1-sol` and reasoning effort `high`, following the same
implementer instructions; the Claude model setting does not apply to Codex.
One package per agent, one agent per package; independent packages may run in parallel,
each on its own branch.

A brief contains, in this order:

1. The work package's goal and acceptance criteria, verbatim from the plan.
2. What to read first: `docs/PLAN.md`, haskell-halogen's `AGENTS.md`, and the haskell-halogen
   modules the package builds on, named by path.
3. What is already decided (the relevant items of the plan's "Decisions"), so the agent does
   not reopen them, and what it is free to choose, which it must report.
4. The verification gate (below).
5. The branch to work on, the commit style, and that the result is one draft pull request.

An implementing agent reports back with what it built, the choices it made, what it could not
do and why, and what the next package should know. It does not edit `docs/PLAN.md`; the
planning session does, from the report.

## Verification gate

An implementing agent reports done only when all of these hold, and says so with the output:

- `npm run build-native` and `npm run test-native` pass.
- `npm run build-wasm` passes, and `npm run test-wasm` once there are browser tests.
- fourmolu reports nothing (`npm run format` changes nothing).
- No warnings on either backend. `-Wall -Wextra` live in each `.cabal` file and `-Werror` in
  `cabal.project` only, as in haskell-halogen; CPP gives each backend different code, so a
  warning in one does not show in the other.
- Tests for what the package adds: native hspec for pure code (domain, Markdown rendering,
  permission rules, backend contracts), hspec-halogen in a real browser for components.

A gate that cannot be run (toolchain missing, network down) is reported as not run, never as
passed.

## Toolchain

Pins follow haskell-halogen exactly and are bumped together with its `source-repository-package`
pin: GHC 9.14.1 natively, cabal 3.16.1.0, `wasm32-wasi-ghc-9.14.1.20260731` from the
ghc-wasm-meta revision haskell-halogen's `.github/workflows/build.yml` names, Node 24 or later,
Chromium for Playwright. Targets are native GHC and wasm; the GHC JavaScript backend is not a
target here. Cloud sessions start without GHC: the `SessionStart` hook under `.claude/` installs
the toolchain, and a session where it has not run should run it before building.
The hook runs `toolchain/bootstrap.sh` (`sh toolchain/bootstrap.sh` by hand; see the README).

Only `haskell-halogen-core` is on Hackage, so every haskell-halogen package comes from a
`source-repository-package` stanza in `cabal.project` pinned to one commit. Bumping the pin is
its own commit, with the reason in its body.

## Conventions

Those of haskell-halogen's `AGENTS.md` apply unchanged, in short:

- fourmolu formatting (`fourmolu.yaml`: 2-space, leading commas and arrows); `GHC2021` plus
  the `default-extensions` list each `.cabal` carries; `NoFieldSelectors`,
  `OverloadedRecordDot`, `DuplicateRecordFields`, `StrictData`.
- Components, specs and helpers are polymorphic in the monad with class constraints
  (`MonadWiki m`, `MonadBrowserTest m`); only an entry point picks one.
- `RefLabel`s come from `H.newRefLabel` in `initialState`, never a literal.
- Browser logic lives in `jsbits`-style JavaScript declared once with `browserJS`; a library
  that needs npm packages is bundled by `web/bundle.sh` and called through globals, as
  haskell-halogen's material package does.
- Markdown is rendered to Halogen `HTML` values, never to an HTML string set through
  `innerHTML`. Mermaid, KaTeX and highlighting fill elements Halogen holds by ref and does not
  look inside.
- Haddocks and comments explain why, in full sentences. Commit subjects are short imperative
  sentences, optionally prefixed with the package (`wiki-core: …`); bodies say why.
- Each package keeps a `CHANGELOG.md` with an `Unreleased` section once it has users.

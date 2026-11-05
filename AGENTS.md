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

One session, the one the owner talks to, owns the work (the owner, 2026-10-31): it owns
`docs/PLAN.md`, cuts the plan into work packages, sees each one through, and amends
the plan as it goes: a decision confirmed or changed, acceptance criteria met or
carried over. Who writes the code depends on the session's model (the owner,
2026-11-03): a session on Fable (`claude-fable`) plans, briefs and reviews, and never
implements itself: for each work package it runs one Opus subagent (model `opus`,
every effort `high`) in a worktree of its own, with the package's text, the files to
read and the verification to run, and takes its report; a session on another model
implements itself. Either way the session is the one that opens the pull request,
handles the review rounds and amends the plan. Changes to `docs/PLAN.md` alone go
straight to `main`, without a pull request; code goes through one, one per work package,
opened ready for review, not as a draft, on its own branch.

Before a pull request merges, the session reviews it with Codex on the pushed head
(`codex exec review --base <merge-base> -m gpt-6.1-sol -c model_reasoning_effort=high`,
in a detached checkout of the head, with the owner's key given on standard input and the
saved credential removed afterwards; a model or effort below that is not a review). A
session without the key, or whose key has run out of quota, asks the GitHub Codex bot
instead, with a comment of `@codex review` on the pull request, and waits for its answer
(the owner, 2026-11-02); its review counts as a round. The
session verifies each finding, fixes the real ones and pushes, and every push of fixes
is followed by another round, however small the fixes, until a round finds nothing
(the owner, 2026-11-03: a round is never skipped because the fixes were small). Every
pull request, every time. Three rounds at most (the owner, 2026-11-02, down from
four): the fixes after the third are made and described in the pull request, not
reviewed again, except when the third round's finding is of the same kind as an
earlier round's (the same mechanism, another case of it): then one more round is run
after the fix, so that the family of findings is closed by a review (the owner,
2026-11-04).

Every pull request adds one changelog entry, `changelog/<number>-<slug>.md`
(the owner, 2026-11-05; the grammar is the README's "Changelog entries"):
what the pull request changed, for the wiki's users, in plain language, with
an example of each new feature. The number is the entry's `pr` with zeros in
front to five digits, so that the files list in order. The session writes it
with the branch as `00000-<slug>.md` with `pr: 0`, and in one more commit,
once it has opened the pull request and before the review, fills in the
number and renames the file to match (`00169-<slug>.md`, `pr: 169`); CI's
`changelog` job checks both. The label `no-changelog` exempts a pull request; it is the owner's, and
the session never applies it.

The owner merges. The session does not merge a pull request unless the owner asks it
to. When `main` has moved, the session rebases the branch onto it (and force-pushes:
work-package branches belong to the session) so CI runs on the rebased head.

When a work package is done, its pull request's description says what was built, the
choices made, and what differs from the plan. The plan keeps no log of the work (the
owner, 2026-10-31): the package leaves "Open work", a decision taken or changed goes
under "Decisions", and what could not be done, or was found and left, goes under "Known
gaps and notes" for the packages after it.

## Verification gate

A work package is done only when all of these hold, and the session says so with the output:

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

A change that touches no Haskell of the repository's own packages (a pin bump of
haskell-halogen, a toolchain script, a workflow, documentation) needs only the native
type-check locally (`npm run build-native`, or the session's type-check script); CI
runs the tests on the pushed head (the owner, 2026-11-03: "wystarczy typecheck i CI
niech robi testy"). The full gate above is for a work package that changes the
packages.

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
- The browser's own objects are read and called through haskell-halogen's Web types and
  their fields (`w.history.go`, `event.key`; decision 30 in `docs/PLAN.md`), and the
  wiki's own objects through wiki newtypes with `jsFields`. JavaScript of the wiki's own
  lives in `jsbits` declared once with `browserJS`; a library that needs npm packages is
  bundled by `web/bundle.sh` and called through globals, as haskell-halogen's material
  package does.
- Markdown is rendered to Halogen `HTML` values, never to an HTML string set through
  `innerHTML`. Mermaid, KaTeX and highlighting fill elements Halogen holds by ref and does not
  look inside.
- Haddocks and comments are plain, direct English, written for someone who does not know
  this code. The first sentence says what the thing is, in ordinary words and with its name
  from the code (`Cache` is the HTTP backend's cache of API answers); the next ones say why
  it exists and when it changes. Short sentences. Technical words rather than paraphrases
  (cache, fetch, invalidated, render), no pronouns the reader has to resolve ("what it has
  read", "as the reads return them", "let go"), no ornament. The test: a reader new to the
  module understands each sentence on one reading. They still explain why rather than
  restate the code, but a comment that explains why in riddles explains nothing. Commit
  subjects are short imperative sentences, optionally prefixed with the package
  (`wiki-core: …`); bodies say why, in the same plain English.
- Libraries over hand-rolled code (decision in `docs/PLAN.md`, 2026-10-29): where a
  maintained package covers a need (a protocol, a format, a browser capability), use it;
  write by hand only what is this wiki's own and the glue a library needs. Nothing is
  vendored when a package exists on Hackage or npm. A package that does not build on wasm
  is a reason to look for another, not to reimplement it; if nothing exists, say so in the
  report so the plan records it. Keep JavaScript to `browserJS` bindings and a few lines
  around a library's call.
- Each package keeps a `CHANGELOG.md` with an `Unreleased` section once it has users.

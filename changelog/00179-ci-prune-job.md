---
pr: 179
title: CI keeps its cabal stores for every job of a run
technical: true
---

## Other changes

The pull request checks no longer build every Haskell dependency from
scratch in one of their jobs. The job that saves the cabal store used to
delete the previous copy right after saving the new one, while another
job could still be looking it up; that job then found no store at all.
The older copies are now deleted by a job of their own, which runs once
every other job has ended.

The build of the pages for a release (main-latest and tags) keeps its
own store of dependencies too, so it no longer compiles every one of
them again on each run.

A pull request whose page is built on GitHub's own runners, when the
owner's machine is busy, now finds the wasm dependencies built for main
there too: every push to main keeps them up to date on GitHub's runners.

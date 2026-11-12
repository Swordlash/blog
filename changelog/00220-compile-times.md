---
pr: 220
title: Faster builds, and no surprise rebuilds of the dependencies
technical: true
---

## Other changes

- The everyday native build (`npm run build-native`, and CI's native jobs)
  compiles the wiki's own packages without optimisation, which takes a
  fraction of the time. What is deployed is built as before: the server
  at `-O2`, and the browser's application with optimisation.
- The Hackage index the build reads is pinned in `cabal.project`. A
  `cabal update`, which the bootstrap and every deploy run, no longer
  makes the next build compile pandoc, servant and the rest of the
  dependencies again because Hackage received something new. The pin is
  bumped on purpose, in a commit of its own.
- CI tests the deploy scripts in a job of their own, beside the others,
  and builds the base branch's server for the upgrade's rehearsal once
  rather than twice, so a pull request's checks finish sooner.

---
pr: 227
title: The server's OPAQUE package moves to a repository of its own
technical: true
---

## Other changes

- The server's side of signing in with a password (OPAQUE, through which
  your browser proves that it knows your password without sending it) now
  lives in a repository of its own, [opaque-hs](https://github.com/Swordlash/opaque-hs),
  where its tests run. Nothing about signing in or setting a password
  changes, and existing passwords keep working.
- A build of the wiki fetches opaque-hs from GitHub at one pinned commit, as
  it already fetches haskell-halogen, so a machine that builds the server
  needs to reach github.com for it.

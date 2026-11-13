---
pr: 266
title: The browser tests build their bundle only when its sources change
technical: true
---

## Other changes

- The browser tests (`npm run test-wasm`) no longer bundle the islands'
  libraries again at every run, which took about ten seconds each time.
  The bundle is kept in the build directory and reused for as long as
  nothing it is built from has changed: the web sources, the bundle
  scripts, the lockfile, the installed packages, Node's version and the
  base path. A line says which happened:

  ```text
  test bundle: reused 882d95e48c63 (the inputs are unchanged)
  test bundle: building 3c1f0a9b27de (changed since the bundle used last: web/src/islands.js)
  ```

  `WIKI_TEST_BUNDLE_REBUILD=1` builds it again in any case.

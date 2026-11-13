---
pr: 0
title: The server's smoke test is written in Haskell and waits on the page
technical: true
---

## Other changes

- The server's smoke test, which drives the server's build of the page
  against a real server (a walk through the wiki as its administrator, a
  visitor and a user who signs in with a provider, every page adopted
  without a repair, the demo's pages imported, interactive SVGs, encrypted
  spaces with their canary, reading offline), and the smoke test of the
  passkeys, which syncs the writing assistant's keys with real passkeys
  from the browser's virtual authenticator, are now Haskell suites on
  haskell-halogen's test driver, as the demo's smoke test is. Where the
  JavaScript tests waited a fixed time, or retried for up to thirty
  seconds, they now wait until the page says it has finished. `npm run
  smoke-test` runs them after the demo's, the server's on SQLite and, when
  `WIKI_TEST_DATABASE_URL` names a PostgreSQL server, on PostgreSQL too;
  each runs alone with:

  ```sh
  sh toolchain/smoke-suite.sh passkeys
  sh toolchain/smoke-suite.sh server
  sh toolchain/smoke-suite.sh server-postgres
  ```

- The step of the server's test that went back from the editor's preview
  of interactive SVGs timed out now and then: an SVG that moves its own
  frame elsewhere adds an entry to the browser's history, and the browser's
  Back then took that frame back instead of the page. The test now waits
  for the frame and goes back over both entries.

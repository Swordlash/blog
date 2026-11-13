---
pr: 0
title: The server's smoke test is written in Haskell and waits on the page
technical: true
---

## Other changes

- The smoke test of the passkeys, which syncs the writing assistant's keys
  with real passkeys from the browser's virtual authenticator against a
  real server, is now a Haskell suite on haskell-halogen's test driver, as
  the demo's smoke test is. Where the JavaScript test waited for a page or
  retried for up to thirty seconds, it now waits until the page says it
  has finished. `npm run smoke-test` runs it after the demo's; it runs
  alone with:

  ```sh
  sh toolchain/smoke-suite.sh passkeys
  ```

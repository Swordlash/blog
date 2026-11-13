---
pr: 0
title: The demo's smoke test is written in Haskell and waits on the page
technical: true
---

## Other changes

- The demo's smoke test, which drives the built page in Chromium (every
  prerendered page adopted, a long walk with back, forward and reload,
  export and import, a dark scheme and a phone, slides, the clipboard,
  reading offline and the writing assistant), is now a Haskell suite on
  haskell-halogen's test driver. Where the JavaScript test waited a fixed
  time, or retried for up to thirty seconds, it now waits until the page
  says it has finished. `npm run smoke-test` runs it, as before, followed by
  the server's smoke test; it runs alone with:

  ```sh
  sh toolchain/smoke-suite.sh demo
  ```

- Once a week, and when CI is started by hand, CI runs the same suite with
  the browser's processor slowed down four times, to find tests that only
  pass on a quick machine:

  ```sh
  HALOGEN_PLAYWRIGHT_THROTTLE=4 sh toolchain/smoke-suite.sh demo
  ```

- The writing assistant's answer now counts as work the page is doing until
  it has ended, so a test that waits for the page to finish after Send
  reads the whole answer. Nothing changes for someone using the assistant.

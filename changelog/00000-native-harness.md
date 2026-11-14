---
pr: 0
title: Views are tested natively on one harness, with pauses on the test's clock
technical: true
---

## Other changes

- The bell's component is tested on the in-memory DOM through a harness
  every view's native spec can use: clicks, keys and a press outside the
  list bubble as in a page, the page is read with CSS selectors, and the
  test waits for the bell's own program, never on a clock. It runs beside
  the rest of the native tests, and the bell's list closing on a press
  outside and on Escape is tested there instead of in a browser.
- The bell's suite in Chromium over haskell-halogen-remote is gone: the
  native spec checks all it checked of the wiki.
- The pauses a test waits for (the searches' debounce, the editor's
  preview, check and draft, the backups' next look) follow a native test's
  own clock, and the users' search is tested with no real wait.

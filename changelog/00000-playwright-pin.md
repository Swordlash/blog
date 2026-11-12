---
pr: 0
title: The README's screenshots are taken by a Haskell test that waits on the page
technical: true
---

## Other changes

- The wiki now builds on a newer haskell-halogen, which comes with a test
  driver for Chromium written in Haskell. The driver waits after every
  click and key until the page says it has finished, rather than for a
  fixed time, so that the browser tests stop failing on a slow machine.
- The README's screenshots are taken by a new test suite on that driver
  (`npm run screenshots`, as before), and CI now takes them on every run,
  checking that each is under 300 KB. A second small suite checks, in CI,
  that the waits hold on the wiki's own pages.
- The "Saved", "Copied" and export notices, and the writing assistant's
  seconds counter, are timed in a way the driver knows not to wait for.
  They look and last as before.

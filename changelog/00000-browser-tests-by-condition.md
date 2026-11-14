---
pr: 0
title: Browser tests that failed by chance on a loaded machine wait for what they check
technical: true
---

## Other changes

- The browser tests' stand-in for the server's live channel now answers a
  page's subscription with who edits and who reads it, as the server
  does, so that a test no longer fails by chance when signing in gives
  the tab a new connection.
- The tests of the bell's notifications tell a notification once the
  bell's connection is open, rather than before, when it was lost.
- The random walks over the slides' editor wait, between steps, until
  the editor has finished what the step set off, rather than for a fixed
  time that a loaded machine did not always give.
- Two more browser tests wait for what they check to have happened: a
  page's subscription before the server tells it its comments changed,
  and the tab's reload after another tab's sign-out before checking that
  unsaved text was kept.

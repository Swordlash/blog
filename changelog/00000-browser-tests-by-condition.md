---
pr: 0
title: Browser tests learn who edits a page on the tab's new socket, as from the server
technical: true
---

## Other changes

- The browser tests' stand-in for the server's live channel now answers a
  page's subscription with who edits and who reads it, as the server
  does, so that a test no longer fails by chance when signing in gives
  the tab a new connection.
- Two browser tests wait for what they check to have happened: a page's
  subscription before the server tells it its comments changed, and the
  tab's reload after another tab's sign-out before checking that unsaved
  text was kept.

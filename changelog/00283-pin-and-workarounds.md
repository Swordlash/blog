---
pr: 283
title: The smoke tests lean on the newer test driver's waits
technical: true
---

## Other changes

- The smoke tests run on a newer haskell-halogen test driver. After each
  action it now also waits for a dialog closed by Escape and for a step
  back through the page's history, so the tests no longer listen for those
  events themselves. A page's requests are counted from what that page
  itself asked for. Nothing changes on the wiki's pages.

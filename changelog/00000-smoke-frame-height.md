---
pr: 0
title: The server's smoke test no longer fails on an HTML block's height
---

## Other changes

- The server's smoke test no longer reports as a repair the height the page
  measures for an HTML block once the block has loaded, which made it fail
  now and then on pull requests that had nothing to do with it.

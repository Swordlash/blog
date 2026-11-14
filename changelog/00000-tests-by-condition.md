---
pr: 0
title: Two tests that failed by chance wait for a condition or count, not a clock
technical: true
---

## Other changes

- The server's smoke test waits for who is editing a page, and for a
  comment, where they reach a second user's tab over the WebSocket,
  instead of reading the page as soon as its own requests are answered.
  It failed by chance on PostgreSQL in CI when the server's answer came
  an instant later.
- The test that finding where a code block left open starts costs time
  in proportion to the slide now counts the memory the work takes, at
  three sizes, instead of timing it against three seconds, which a busy
  CI machine went over.

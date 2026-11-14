---
pr: 0
title: The server's smoke suite waits for what reaches a tab over the WebSocket
technical: true
---

## Other changes

- The server's smoke test waits for who is editing a page, and for a
  comment, where they reach a second user's tab over the WebSocket,
  instead of reading the page as soon as its own requests are answered.
  It failed by chance on PostgreSQL in CI when the server's answer came
  an instant later.

---
pr: 0
title: The embedded presentation's viewer is a state machine
technical: true
---

## Other changes

- The logic of a presentation embedded in a page is now a pure state
  machine, tested natively on thousands of generated orders of sign-ins
  and sign-outs, reloads, the embed naming another page, the viewer's
  watch telling, the server's answers and other people's changes. Two of
  its guards, against an extra watch of the link and against a page read
  for an earlier reader, are now rules the tests check rather than
  conventions in the code.
- The application counts the reader's sessions, so that a view can tell
  the same user signed out and in again from one who stayed: the
  embedded presentation reads its page again in that case.

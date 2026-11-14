---
pr: 287
title: An embedded presentation is read again after you sign in again
---

## Bug fixes

- A presentation embedded in a page is read again after you sign out
  and sign in as the same user. Before, it could stay as it was, with
  pictures that no longer loaded.

## Other changes

- The logic of a presentation embedded in a page is now a pure state
  machine, tested natively on thousands of generated orders of sign-ins
  and sign-outs, reloads, the embed naming another page, the viewer's
  watch telling, the server's answers and other people's changes. Two of
  its guards, against an extra watch of the link and against a page read
  for an earlier reader, are now rules the tests check rather than
  conventions in the code.

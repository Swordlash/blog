---
pr: 284
title: A page's comments keep every change, in its place
---

## Bug fixes

- A comment someone else posts while the page is reading its comments
  again (after you save it, for example) no longer disappears when that
  read comes back.
- A thread you open on one page no longer shows up on another page you
  went to before the server answered.
- Your own thread or reply no longer comes back as you first wrote it
  after someone replied to it, edited it or deleted it in the moment
  before the server answered you; and it no longer stays on the page
  after someone else deleted it.
- Your reply now takes its place in the order the server keeps, also
  when someone else replied to the same thread just before you: the page
  reads its comments again after each of your writes when it cannot
  tell where yours belongs.
- When reading a page's comments again fails, the comments you were
  reading stay on the page under the line "Comments could not be
  refreshed." and a "Try again" button, instead of turning into an error.
  The line goes once the comments are read again, or the page is told
  them anew.

## Other changes

- The logic of a page's comments is now a pure state machine, tested
  natively on thousands of generated orders of your writes, other
  people's, the server's answers and the live channel's messages, over
  the HTTP backend's cache too.

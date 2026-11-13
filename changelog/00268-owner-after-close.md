---
pr: 268
title: Nothing kept for a page closed the instant it opens
technical: true
---

## Other changes

- A page, its editor, its slides or its live preview closed in the instant
  it opens (a Back right after a click, a redirect) no longer leaves behind
  in the tab the record it had just made to hold its attachments'
  addresses. A presentation embedded in a page and closed in the instant
  it is watched no longer leaves its watch running. Neither could be seen
  on a page; the browser tests found the first now and then, and now test
  it every time.

---
pr: 208
title: The server page's build tidies its cache again
technical: true
---

## Other changes

The job that deletes the older copies of the server page's build cache
failed after every change to `main`, because it was given an empty name
for the copy to keep. It now keeps the copy the build has just saved and
deletes the others, so the cache no longer grows.

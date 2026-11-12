---
pr: 230
title: The browser signs in with the same OPAQUE package as the server
technical: true
---

## Other changes

- Signing in with a password, and setting one, now runs in your browser on
  the same OPAQUE package the server uses,
  [opaque-hs](https://github.com/Swordlash/opaque-hs), in place of the
  wiki's own code around the OPAQUE library. Nothing changes in what you
  see: your password still never leaves your browser, existing passwords
  keep working, and signing in still works on a wiki served over plain
  HTTP, where the browser offers the page no encryption.

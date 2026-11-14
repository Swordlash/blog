---
pr: 276
title: No password key or half-added passkey left behind, and no late jump back
---

## Bug fixes

- When signing in with your password, the page holds a key made from the
  password while it brings your encryption keys up to date. If the
  sign-in control went from the page in that time (the wiki could not be
  read again just after the sign-in, say), that key stayed in the page
  until the tab closed. It is now let go of.
- Adding a passkey in the account's panel and closing the panel before
  the server had answered left the new passkey on your device, unknown to
  the wiki: it was offered at sign-in and signed nobody in. The passkey is
  now registered all the same.
- Choosing a filter or a page size in the administration's list of users,
  a pause in typing its search, a link followed from the help dialog, and
  the page shown after "Save and close" could each put their address in
  place a moment late, undoing a link you had followed in that instant.

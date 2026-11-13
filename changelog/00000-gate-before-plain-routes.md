---
pr: 0
title: A space that asks each time asks while its encryption is turned off
---

## Bug fixes

- A space set to "ask for a passkey or the password each time this space
  is opened" could show its pages without asking while its encryption was
  being turned off. The pages decrypted already were shown, in the space's
  list of pages and at their addresses, to a reader who had not confirmed,
  right after something was saved anywhere in the wiki, or after a save
  that failed. Now the space asks first, whatever was saved before: for
  example, while such a space is being decrypted, save a page in another
  space, then follow a link to a page of the first space that is plain
  already; the wiki asks for the passkey or the password, and shows
  nothing of the page, nor of the space's list of pages, until you give
  it.

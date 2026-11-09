---
pr: 209
title: Encrypted spaces
---

## New features

A private space can now be encrypted: the titles and texts of its pages,
and their histories, are encrypted in its members' browsers, and the
server keeps only what it cannot read. Open a new private space's settings,
choose **Permissions**, then **Encrypt this space…** and **Encrypt**. For
example, a space "Board" made only for the board's members, encrypted
before anything is written in it, shows its pages to its members as any
space does, while the server stores only ciphertext, such as this title:

```
{"nonce":"q7Gf0pXo2mB1c9Kd","ciphertext":"Vd3x…kQ"}
```

Members are those the permissions let read the space. Each gets the
space's key from another member's browser, the next time a member opens
the space; until then the space says that it waits for the key. On a
device that does not hold your keys yet, the space shows as locked and
offers to unlock your keys there, with a passkey or your password.

Searching finds words in encrypted pages too: your browser searches the
encrypted spaces whose key you hold, after decrypting their pages.

## Other changes

What needs the server to read a page cannot be done in an encrypted space
yet, and is not offered there: comments, attachments, drafts, exports,
feeds, link previews, templates, moving pages in or out (a page moves
within the space as usual), importing into it, and subspaces. Leaving the
editor with unsaved changes offers to discard them or go on editing, since
no draft is kept. The writing assistant works there as in any page, and
what you ask it about goes to its provider. The
space's name stays readable. Removing a member does not yet change the
space's key, and the permissions say so. Encrypted spaces need the wiki's
HTTPS address.

A password reset now also warns that your encrypted pages will be
destroyed for you, unless another member shares the key again.

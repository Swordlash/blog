---
pr: 251
title: Encrypted spaces: comments, attachments, rollbacks caught, new keys
---

## New features

- Pages of an encrypted space now have comments and attachments, both
  encrypted in your browser like the page: the server keeps the
  comments, the text they quote, and the files with their names, only as
  ciphertext. Select text on the page and choose **Comment**, or attach
  a file in the editor, as on any page. For example, select "the launch
  date" in a page, choose **Comment** and write "Moved to Tuesday?": your
  browser encrypts both before they are sent. Those watching the page are
  told under the bell that you commented on "an encrypted page", without
  the comment's text. A mention in such a comment notifies nobody, since
  the server cannot read it.

- In an encrypted space, your browser now notices when the server sends
  a page older than the one you read before, another version under the
  same number, or a history with a version missing. The page is shown
  with a banner over it, and cannot be edited in that tab until you
  reload:

  ```text
  The server sent an older version of this page (version 2) than this
  browser has read before (version 3). What is shown may not be the
  latest, so the page cannot be edited here until it is reloaded.
  ```

  Each version now names its number and the version before it inside its
  encryption, so the server cannot change either. A browser that never
  read the page cannot tell, and versions saved before this change are
  not numbered.

- Removing someone from an encrypted space now gives it a new key, so
  that nothing written after can be read with the key they kept. If you
  administer the space and hold its key, your browser does it as you
  remove them; otherwise the space's administrators are told under the
  bell, and the next one to open the space renews it. Until then, a save
  says why it cannot be made:

  ```text
  This space's key must be renewed before anything more is written in
  it: someone who held the key can no longer read the space.
  ```

## Other changes

- The server's smoke test now encrypts a space, writes a page in it,
  attaches a file and comments on it, shares its key with a reader and
  unlocks it in a browser without the keys, and checks that what the
  space protects is found nowhere in the server's files, its database or
  what it sends.

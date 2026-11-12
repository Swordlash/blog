---
pr: 255
title: Encrypted spaces: an export decrypted in your browser
---

## New features

- An encrypted space can now be exported, decrypted in your browser. In
  the space's list of pages, choose **Export, decrypted here**: your
  browser reads the space and each of its subspaces whose key it holds,
  decrypts them, and saves one file with the latest title and text of
  every page, their attachments, and their comments with their authors'
  names. The file leaves out older versions, drafts, the wiki's users and
  groups, and who may read or edit the spaces; a subspace whose key your
  browser does not hold is left out, and the export says which. The
  server never sees the file, so keep it as safe as the pages.

  ```text
  Secret → Pages → Export, decrypted here → Export
  Saved secret-decrypted-2026-11-12.zip: 4 pages of 2 spaces, decrypted.
  ```

  A wiki imports the file as plain spaces, in its administration's "The
  wiki as one file". Do it before a password reset that would delete your
  keys: the page that resets a password now says so.

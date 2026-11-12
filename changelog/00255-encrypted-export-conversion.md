---
pr: 255
title: Encrypted spaces: a decrypted export, and encrypting a space with pages
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

- A space that already has pages can now be encrypted, and an encrypted
  space can be made plain again. In the space's settings, under
  **Permissions**, choose **Encrypt this space…**: your browser encrypts
  its pages one by one, with their histories, comments and attachments,
  and the spaces below it too. **Turn encryption off…** does the same the
  other way. Until it is done nothing else can be written in the space; if
  you close the tab, an administrator who holds the key picks it up where
  it stopped:

  ```text
  Encrypting its pages stopped, with 12 pages left. [Continue]
  ```

  Each encrypted page gets a new address; its link by id keeps working.
  Backups made before keep the plain text until they are pruned. A
  conversion can always be turned back: **Stop and turn back** converts
  the pages done so far back, and the space ends as it began. A page that
  stops a conversion is named, with why:

  ```text
  The page p-3f2a9c of Plans was not converted: … Mend it and continue,
  or stop and turn back.
  ```

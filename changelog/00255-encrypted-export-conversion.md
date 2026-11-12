---
pr: 255
title: Encrypted spaces: a decrypted export, encrypting pages, asking each time
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

- An encrypted space can now ask for a passkey or your password each time
  it is opened. Its administrators turn on **Ask for a passkey or your
  password each time this space is opened** in its **Permissions**. It
  guards against someone using your unlocked computer: nothing of the
  space is shown until you open it, and leaving it forgets it again. It
  does not stop someone who opens the browser's developer tools on a
  device where your keys are unlocked.

  ```text
  Secret
  This space asks for a passkey or your password each time it is opened.
  [Open with a passkey]
  ```

- The bell and your starred pages now show the titles of pages in
  encrypted spaces, decrypted in your browser, where they said "an
  encrypted page" before. Where your browser does not hold the space's
  key, or the space asks for a passkey or your password and you have not
  opened it, they still say "an encrypted page". Notification mails and
  the feed always do.

  ```text
  🔔 Bea Reader replied in a thread of yours · Launch plans
  ```

## Other changes

- Signing out now deletes your keys from the device, in every tab, and
  closes every encrypted space open in another tab; so does opening the
  wiki once your session has ended. Signing in with your password unlocks
  them again by itself; after signing in with a provider, unlock them with
  a passkey before reading an encrypted space.
- In an encrypted space, the wiki no longer offers what the server cannot
  do there: **Use as template**, **Show as a blog**, the **Public** switch,
  and moving a page to another space. While a space's pages are being
  encrypted or decrypted, nothing that writes is offered in it, and a line
  above the page says why:

  ```text
  This space's pages are being encrypted in the browser of one of its
  administrators, so nothing else can be written in it until that is done,
  its settings included but for continuing, stopping and turning back the
  conversion.
  ```

- In an encrypted space, a mention is named from the space's readers: no
  login found in an encrypted page or comment, nor letters typed after an
  @, are sent to the server. The writing assistant's panel says that what
  you ask it about leaves your browser decrypted, to the provider named:

  ```text
  This page is encrypted. What you ask the assistant about leaves this
  browser decrypted, to Anthropic.
  ```

- The wiki's export now says which encrypted spaces it leaves out, and
  how to export each.

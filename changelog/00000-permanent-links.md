---
pr: 0
title: Permanent links: an address that follows a page when it moves
---

## New features

- Every page has a permanent address, made of its id rather than its place
  in the wiki. It keeps leading to the page after the page is moved, under
  another page or to another space, where the page's ordinary address would
  lead nowhere. Open it and the wiki takes you to the page where it is now,
  to the same section:

  ```text
  /l/4f1c9a2e-7b3d-4c11-9e0a-5d2f6b8c1a3e/#setup
  ```

- **Copy permanent link**, among a page's buttons, copies the page's
  permanent address, and says "Link copied" as the other copies do.

  ```text
  Copy permanent link   →   https://wiki.example.org/l/4f1c9a2e-…/
  ```

- The `#` at the end of a heading or a box now copies the permanent address
  of that section, so a link you send keeps working when the page moves.
  Middle-clicking the `#` still opens the section at the page's ordinary
  address.

  ```text
  # on "Setup"   →   https://wiki.example.org/l/4f1c9a2e-…/#setup
  ```

- The editor's **Link to a page** (Ctrl+Shift+K) has a new box, **Permanent
  link**. It is off at first, since an ordinary address says in the text
  which page it is; ticked, the link is written with the page's permanent
  address, with the section you chose:

  ```markdown
  See [the setup](/l/4f1c9a2e-7b3d-4c11-9e0a-5d2f6b8c1a3e/#setup).
  ```

  You can write one by hand too, and as a wiki link:

  ```markdown
  [[/l/4f1c9a2e-7b3d-4c11-9e0a-5d2f6b8c1a3e/|the setup]]
  ```

## Other changes

- A permanent link to a page you may not see, or to one that has been
  deleted, shows the wiki's usual "There is nothing here", exactly as for
  an address that names nothing: it does not tell anyone that the page
  exists. Someone who is not signed in sees the same, and arrives at the
  page once they sign in.
- A permanent link to a page in another space is never shown as a broken
  link: the wiki finds the page when the link is followed.
- The PDF and Word exports treat a permanent link as they treat an ordinary
  link to the same page: a link inside the document when the page is in it,
  and the wiki's address otherwise.
- An archive imported into a wiki that already has content gives its pages
  new ids, so a permanent link in the imported text still leads to the page
  that had the id where the archive came from.

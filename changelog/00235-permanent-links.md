---
pr: 235
title: Permanent links to a version of a page
---

## New features

- **Copy permanent link**, among a page's buttons, copies a link to the page
  as it is at that moment. The link keeps showing that version, the same
  text, after the page is edited, and keeps working after the page is moved,
  under another page or to another space. The notice says "Link to this
  version copied":

  ```text
  https://wiki.example.org/l/4f1c9a2e-7b3d-4c11-9e0a-5d2f6b8c1a3e/?version=2026-11-10T09%3A30%3A12Z
  ```

- The page such a link opens says which version it is, with a link to the
  page as it is now:

  ```text
  This is the page as it was saved on 10 November 2026. See the page as it is now
  ```

  A page's history has **Read this version** beside each version, to read
  it as the page showed it, and copy its permanent link from there.

- A permanent link can be written in a page as any link, with a section
  after it, and as a wiki link:

  ```markdown
  See [the setup](/l/4f1c9a2e-7b3d-4c11-9e0a-5d2f6b8c1a3e/?version=2026-11-10T09%3A30%3A12Z#setup).
  ```

  Written without the version, `/l/<page id>/` leads to the page as it is
  now, wherever it has moved.

## Bug fixes

- A link in a page to a section of another page, such as
  `[the macros](/s/docs/p/markdown-guide/mathematics/#macros)`, now opens
  that page at the section, and the address shows the section. Before, it
  opened the page at its top.

## Other changes

- A permanent link to a page you may not see, or to one that has been
  deleted, or to a version the page does not have, shows the wiki's usual
  "There is nothing here", exactly as for an address that names nothing: it
  does not tell anyone that the page exists. Someone who is not signed in
  sees the same, and arrives at the page once they sign in.
- A permanent link to a page in another space is never shown as a broken
  link: the wiki finds the page when the link is followed.
- The PDF and Word exports treat a permanent link without a version as they
  treat an ordinary link to the same page: a link inside the document when
  the page is in it, and the wiki's address otherwise. A link to a version
  always goes to the wiki's address, since the document holds the page's
  text as it is now.
- A permanent link in an imported archive is kept as it was written. An
  import into a wiki that already has content gives the pages it brings new
  ids, so such a link still names the page it named where the archive came
  from: on that wiki it leads there, and on another one most likely to
  nothing.

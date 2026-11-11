---
pr: 0
title: See which pages link to a page
---

## New features

- Each page lists the pages that link to it, under **Linked from** in the
  sidebar, below the space's pages. A click on one opens it. If a page
  called "Glossary" is linked from "On-call" and "Onboarding", reading the
  Glossary shows:

  ```text
  Linked from
    Onboarding
    On-call
  ```

  A link counts however it is written, as long as it leads to the page when
  you click it: a path, a wiki link, a permanent link, an embedded page or
  a link in a page's HTML:

  ```markdown
  See the [[Glossary]], the [terms](/team/glossary) or [the version I read](/l/4f1c9a2e-7b3d-4c11-9e0a-5d2f6b8c1a3e/?version=2026-11-10T09%3A30%3A12Z).
  ```

  A page that links twice is listed once, and a page's links to itself are
  not listed. A page nothing links to shows no section.

## Other changes

- The list follows the links as they lead now. A page written with a link
  to a page that does not exist yet is listed as soon as that page is
  made. A page moved elsewhere is no longer listed for links by its old
  address, but still is for its permanent links, and a page made where a
  deleted one was is listed for the links to that address.
- The list holds only the pages you may read, and says nothing about the
  others.
- An encrypted space's pages have no list, and are not listed on any
  other page's: the server cannot read what they link to.
- The list is updated when the page is opened again, not while you read
  it.
- After the upgrade, the server reads every page's links once when it
  starts, which on a large wiki takes a few seconds.

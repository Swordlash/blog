---
pr: 229
title: A space's home page holds all its other pages
---

## New features

- A space's home page is now the top of its pages: every other page of the
  space is under it. The home page has no address of its own any more: it
  is at the space's address, and so are its editor, its source, its history,
  its slides and its live preview:

  ```text
  /s/docs/                the home page
  /s/docs/edit/           its editor
  /s/docs/source/         its Markdown
  /s/docs/history/        its history
  /s/docs/slides/         its slides
  /s/docs/live-preview/   its live preview
  ```

- Every other page keeps the address it had. A page that was at the top of
  the space stays at `/s/docs/p/markdown-guide/`, though it is now under the
  home page. A page that was under the home page loses the home page's part
  of its address, and an address from before still leads to it:

  ```text
  before:  /s/docs/p/home/notes/
  now:     /s/docs/p/notes/      (the old address still opens it)
  ```

## Other changes

- The sidebar shows the home page as the space itself, the link with the
  space's name, and the pages under it as the space's pages. The space's
  list of pages ("Space settings") shows them the same way.
- "New page" without a page to put it under, and moving a page to "Its top
  level", put the page under the home page. The move dialog no longer lists
  the home page itself, since "Its top level" is under it.
- When the server is upgraded, each space's pages are arranged this way
  once. The pages that were at the top go under the home page, in the order
  they were in, before the pages that were under it already. A home page
  that was under another page comes out from under it. Where a page that was
  at the top and a page under the home page had the same address ending
  (`notes`), the page that was at the top keeps it, and the other one gets
  the next free one (`notes-2`). No page's text changes.
- A link written in a page is still read from the page's address. On the
  home page, and on a page that was under it, a link that climbs with `..`
  starts one level higher than before, and may lead elsewhere.
- A blog's posts are the pages under its home page. A space's export gives
  every page that was at the top the heading level it had. A box numbered
  with its page's number counts the pages under the home page from 1: the
  home page itself is page 0.
- An archive exported before this change is imported the same way: its
  spaces' pages go under their home pages. The guide, the demo's wiki kept
  in your browser and the wiki's backups follow too.
- An encrypted space and the container "User subspaces" have no home page,
  and keep their pages as they were.

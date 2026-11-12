---
pr: 218
title: Live updates of who reads a page cost the server less
technical: true
---

## Other changes

- On a busy page, the server no longer checks every reader's permissions
  each time someone opens or closes the page or its editor. It checks them
  again when a permission changes instead: a grant, a group's members, a
  user, a space, the wiki's settings, or a page moved. Someone who may no
  longer read a page stops receiving its live updates at once, and the
  other readers stop seeing them among the page's readers. Changes to a
  page's text and comments are still checked each time they are sent.

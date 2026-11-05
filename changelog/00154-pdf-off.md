---
pr: 154
title: PDFs turned off when the server has no TeX
---

## New features

- `wiki-server serve --no-pdf` makes no PDFs: the server does not look for
  a TeX engine, offers no PDF export, and the administration's Server
  section says that PDFs are off and what turns them on. The deploy
  sets the option itself when it finds no TeX that works and installs
  none, and drops it once one works:

  ```sh
  wiki-server serve --data data --no-pdf
  ```

- When TeX Live's installer needs Perl and the machine has none, the
  deploy builds Perl under the toolchain directory first, after one
  question that covers both.

## Bug fixes

- A deploy that could not install TeX no longer starts a server that
  offers PDFs it cannot make.
- The server waits at most 20 seconds for its TeX engine when it starts,
  instead of a minute.

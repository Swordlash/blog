---
pr: 149
title: Exports that say what went wrong
---

## New features

- The server tries its TeX engine before it offers PDF exports. It
  typesets a small document when it starts, and offers the PDF formats
  only when that works. The administration's Server section says what it
  found: the engine works, it was not found, or it fails, with what the
  engine printed and the usual causes. "Check again" tries it once more,
  for example after you installed a TeX Live:

  ```sh
  # Install a TeX the server can use, then press "Check again"
  # in the administration's Server section.
  sudo apt install texlive-xetex
  ```

- An export is now fetched by the page. A document is saved under the
  file name the server gives it (`Team-notes.docx`), a PDF opens in a new
  tab, and while a document is being made its entry in the Export menu
  says so.

## Bug fixes

- An export that fails no longer saves the error as the document. The
  page shows the server's reason in a notice instead, and saves nothing.
- A long PDF export is no longer cut off after 30 seconds.

---
pr: 259
title: A presentation's slides as rows, each with its own editor
---

## New features

- In the editor of a presentation, "Slides" now shows a list of rows, one per
  slide: its number, its title, a dot that says whether it fits, and how many
  problems it has. Click a row to open it: it holds an editor of that slide's
  Markdown alone. Open as many rows as you like; click a row's header again to
  close it. The slide your cursor starts in is open when the editor opens.

  ```text
  1. Quarterly review   ●
  2. Where we are       ●   ← click: the slide's Markdown opens below
  3. Next steps         ●  1 problem
  ```

- The rows share one text and one history. Ctrl+Z undoes your last change
  wherever it was: if it was in another slide, that slide's row opens with
  the cursor at the change, and the row you were in closes. Ctrl+Y redoes, and
  both work on a row's header too.

- Typing a `##` heading in the middle of a slide splits its row in two, once
  you pause; deleting a slide's heading joins it to the slide above. A code
  block or a box you have not closed yet stays within its own slide's row; the
  editor marks it, as in the presentation it takes in the slides after it.

- "N problems" opens the row of the next problem and puts the cursor on it. A
  spoiler's section or block folds and unfolds inside an open row, with the
  marks beside the text. The toolbar writes in the row your cursor is in, and
  its buttons wait while no row is open.

- "Raw" still shows the whole Markdown; back in "Slides", the rows you had
  open open again. Text with Windows line endings is cut into rows too.

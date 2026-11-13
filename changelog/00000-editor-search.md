---
pr: 0
title: Find and replace in the editor, over the whole text
---

## New features

- Ctrl+F (Cmd+F on a Mac) in the editor now opens the editor's own search,
  above the text, or above the slides of a presentation. It searches the
  whole page: folded spoilers, slides whose rows are closed and text far
  down the page included, which the browser's own find did not see. It
  starts with what you had selected, and says which match is selected and
  how many there are.

  ```text
  Find  [ theta          ] [Aa] [.*] [W]   3 of 12   [↑] [↓] [×]
        [ \vartheta      ]  Replace   Replace all
  ```

- Enter or F3 goes to the next match, and Shift+Enter or Shift+F3 to the
  previous one; after the last match it goes on from the start, and says so.
  In a presentation edited slide by slide, a match in a closed slide opens
  that slide's row with the match selected; the rows you opened stay open,
  and each closed row's header says how many matches it holds ("3 matches").
  Escape closes the search and puts your cursor at the match.

- The toggles match case, read what you type as a regular expression, and
  match whole words only. Replace changes the selected match and goes to the
  next one; Replace all changes every match at once, in every slide, and one
  Ctrl+Z takes it all back. A regular expression's replacement can use its
  groups:

  ```text
  Find (regular expression):  (\w+)@example\.org
  Replace with:               [[people/$1]]
  ```

## Bug fixes

- A presentation saved with Windows line breaks now has its fit marks on
  its slides' rows, and its preview follows the slide your cursor is in.

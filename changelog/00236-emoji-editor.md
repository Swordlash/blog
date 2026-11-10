---
pr: 236
title: Emoji in the editor
---

## New features

- In the editor, a colon at the start of a word opens a list of emoji.
  Type a few letters of the name and the list narrows; Tab or a click
  writes the emoji's name between colons, and so does Enter once two
  letters are typed. Typing

  ```text
  Shipped :roc
  ```

  and pressing Tab gives `Shipped :rocket:`, which the page shows as
  "Shipped 🚀". A colon after a letter or a digit (`10:30`, `Note:`) opens
  nothing, and a colon or a smiley such as `:p` at the end of a line,
  then Enter, is a new line as before.

- Escape closes the list and writes a backslash before the colon, so that
  the colon stays text. Typing `:ta` and pressing Escape leaves

  ```markdown
  \:ta
  ```

  and one undo takes the backslash back.

- `-:` at the start of a line opens the same list and writes a list item
  that starts with the emoji, with the cursor after it. Typing `-:bug`,
  Enter, then `Fix the crash` writes

  ```markdown
  - :bug: Fix the crash
  ```

  `-:` left alone stays as typed.

- The toolbar has an "Emoji" button, a smiling face. It opens a field to
  search the names, and a grid of the emoji found; a click, or Enter,
  writes the one chosen at the cursor. Searching for `check mark` finds
  ✅, which it writes as `:white_check_mark:`.

- An item of a bulleted list that starts with an emoji shows the emoji in
  place of its bullet:

  ```markdown
  - :white_check_mark: Written
  - :construction: Being reviewed
  - Not started
  ```

  A task keeps its box, a numbered list its numbers, and the PDF and Word
  exports their bullets. A list item that already starts with an emoji now
  shows it as its bullet.

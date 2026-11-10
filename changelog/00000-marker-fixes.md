---
pr: 0
title: Two fixes to the wiki's own blocks
---

## Bug fixes

- An end marker right after indented code now ends its block. This page
  no longer shows its box as never closed:

  ```markdown
  [[!div]]{.summary}
      code
  [[/div]]
  ```

  The same holds for `[[/spoiler]]` after indented code, for a block of HTML
  of one line before an end marker, and for an end marker on the line that
  ends a list item inside the block. An end marker inside a fenced code
  block that is still open, or inside a block of HTML, is still text.
- A block whose marker lines are indented with a tab, as in a list item
  written with a tab after its `-`, is now a block in an exported document
  too, as it is on the page. The marker lines used to be printed as text:

  ```markdown
  -	[[!notes]]
  	Say it.
  	[[/notes]]
  ```

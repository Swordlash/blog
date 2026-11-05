---
pr: 158
title: A copy button on code blocks, and numbered listings
---

## New features

- Every code block has a button in its top right corner that copies the
  code, on pages, in the editor's preview, in comments and on slides. It
  shows when you point at the block.
- The class `numbered` on a code block shows a number before each line;
  it works with `rows` too:

  ````markdown
  ```haskell {.numbered rows=10}
  greet :: Text -> Text
  greet name = "Hello, " <> name
  ```
  ````

  PDF exports number the lines as well.

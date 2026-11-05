---
pr: 155
title: Spoilers, and code listings that scroll
---

## New features

- An inline spoiler hides a few words until the reader clicks them:

  ```markdown
  The murderer is ||the butler||.
  ```

- A block spoiler hides any blocks, behind a description the reader
  clicks to open it. It is a pair of marker lines with a name, and
  spoilers nest. The page remembers in your browser which ones you
  opened:

  ```markdown
  [[spoiler]]{answer}(Show the answer)
  The answer is **42**.
  [[/spoiler]]{answer}
  ```

  A marker line that is wrong is shown in red with the reason. The
  toolbar has a button for each kind of spoiler.

- `{rows=N}` on a code block shows at most N lines, and the rest scrolls:

  ````markdown
  ```haskell {rows=5}
  main :: IO ()
  main = mapM_ print [1 .. 100]
  ```
  ````

## Bug fixes

- In an exported document, a link to a heading of the page leads to the
  same heading as on the page, also when two headings have the same text.

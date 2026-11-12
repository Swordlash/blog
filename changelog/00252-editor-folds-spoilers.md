---
pr: 252
title: The editor folds spoilers
---

## New features

- In the page's editor, a spoiler can be folded away while you work on the
  rest of the page. A small arrow beside the first line of a block spoiler,
  or of a heading spoiler, folds it: the first line stays, with a mark
  where the rest is hidden, and a click on the mark, or on the arrow again,
  unfolds it. Ctrl+Shift+[ and Ctrl+Shift+] (Cmd+Option+[ and Cmd+Option+]
  on a Mac) fold and unfold the spoiler on the cursor's line.

  ```markdown
  [[!spoiler]]{answer}(The answer)
  Forty-two.
  [[/spoiler]]

  ## [[!spoiler]] Question

  Everything down to the next heading of this level folds with it.
  ```

  Folding only changes what the editor shows: the preview, your draft and
  the saved page keep the whole text. Typing before the mark leaves the
  fold closed; anything that would change the hidden lines opens it first.
  Folds are not kept when the page is opened again.

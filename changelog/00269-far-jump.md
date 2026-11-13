---
pr: 269
title: Going to another slide of a long presentation no longer holds the page
---

## Bug fixes

- In a long presentation, edited slide by slide, every move of the cursor
  to another slide held the page for seconds: going to the next problem,
  stepping to a match of the search in another slide, or clicking into
  the text of another slide. The page did not answer the keyboard or the
  mouse until it was over. On a presentation of 60 slides of 100 lines
  each, each such move took about 2.3 seconds, whether the slide was the
  next one or the last; it takes about a tenth of a second now. The
  preview no longer reads the whole presentation again to show another of
  its slides. (The pause after typing in such a presentation, while the
  editor checks the text, still holds the page for some seconds.)

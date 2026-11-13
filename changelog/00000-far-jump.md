---
pr: 0
title: Moving to another slide of a long presentation no longer freezes the page
---

## Bug fixes

- In a long presentation, edited slide by slide, every move of the cursor
  to another slide froze the page for seconds: going to the next problem,
  stepping to a match of the search in another slide, or clicking into
  another slide's text. The page did not answer the keyboard or the mouse
  until it was over. On a presentation of 60 slides of 100 lines each, each
  such move took about 2.3 seconds, near or far; it takes about a tenth of
  a second now. The preview no longer reads the whole presentation again
  to show another of its slides.

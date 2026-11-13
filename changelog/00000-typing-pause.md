---
pr: 0
title: Typing in a long presentation no longer freezes the page after each pause
---

## Bug fixes

- In a long presentation, edited slide by slide, the page froze a moment
  after you stopped typing, while the editor checked the text, counted
  each slide's problems and fits on its row and measured the slides. On a
  presentation of 60 slides of 100 lines each, one key typed and a pause
  froze the page for 7 to 11 seconds at a stretch, and for 12 to 18
  seconds in all; a key pressed or a click in that time waited until it
  was over. Now the longest stretch is under half a second, and the
  page is busy for one to a few seconds in all, in short pieces between
  which it answers: the editor and its preview read the presentation
  twice for each pause, where they read it about a dozen times.

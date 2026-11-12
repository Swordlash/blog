---
pr: 0
title: Readable problem boxes in the dark, and fewer false slide warnings
---

## Bug fixes

- In the dark colour scheme, the box that opens when you hover over a problem
  marked in the editor (a warning or an error) was white with nearly white
  text. It now has the wiki's own colours in both schemes, as the lists of
  mentions and emoji already had. The column of marks beside the text is dark
  in the dark scheme too.
- The editor of a presentation no longer marks a slide as one that "may be
  cut" when the slide has room left at its foot. The room a slide has now goes
  down to where the slide really cuts its text, so a slide with half a line or
  more to spare there is shown as fitting. The guide's slide of keys for
  presenting was one of these.

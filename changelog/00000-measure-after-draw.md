---
pr: 0
title: Two browser examples about long and drawn slides wait as a loaded machine needs
technical: true
---

## Other changes

- The browser example that checks a slide is measured again once its
  diagram is drawn waited two seconds for the diagram to be fetched, drawn
  and measured; on a busy machine that takes up to three, and the example
  failed with the diagram drawn and its measure a moment away. It waits up
  to fifteen seconds now. A new example holds the diagram until every
  slide is measured, then lets it draw with nothing else changing, and
  checks that the slide is measured again and marked as cut: the slides
  were always measured again after a late diagram, and are held to it now.
  The example of the far jump across sixty slides waits for the editor as
  long as such a deck takes to load on a busy machine.

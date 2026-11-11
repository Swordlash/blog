---
pr: 0
title: Interactive SVGs, such as flame graphs, in a frame of their own
---

## New features

- An SVG attachment that needs its scripts, such as a flame graph that
  zooms when you click a frame and searches, can now run them: add
  `{.interactive}` after it.

  ```markdown
  ![Where the time goes](attachment:flame.svg){.interactive}
  ```

  The SVG is shown in a frame as wide as the text and 500 pixels high, or
  as high as you say (`{.interactive height=700}`), and you can drag its
  corner to make it taller. **Open in a new tab**, under it, shows the
  file alone. Its scripts run cut off from the wiki: they cannot read your
  session or anything of the page, cannot send anything to the wiki or
  anywhere else, and cannot open tabs or dialogs. Opened alone in a tab,
  the file is held the same way, except that, like any web page, it can
  send that tab to another address. Without `{.interactive}` an SVG stays an image, in which
  nothing runs. Only an SVG attached to the page is framed, not one at an
  address on the web. The demo, which has no server to send the rules
  that keep the scripts in, shows the image; so do feeds and exports.

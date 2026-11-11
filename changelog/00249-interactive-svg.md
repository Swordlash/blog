---
pr: 249
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
  corner to make it taller. The link under it downloads the file. Its
  scripts run cut off from the wiki: they cannot read your session or
  anything of the page, the usual ways a page loads or sends data are
  closed to them, and they cannot open tabs or dialogs. The file runs
  only in the frame: its address opened in a tab is a download. The frame
  needs the wiki on HTTPS (or on localhost); over plain HTTP the SVG
  stays an image, and so it does when you are offline, and inside a link.
  Without `{.interactive}` an SVG stays an image, in which
  nothing runs. Only an SVG attached to the page is framed, not one at an
  address on the web. The demo, which has no server to send the rules
  that keep the scripts in, shows the image; so do feeds and exports.

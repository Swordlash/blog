---
pr: 165
title: What's new? A page of what changed
---

## New features

- The page "What's new?", linked at the very bottom of the sidebar, shows
  the version of the wiki's server, the day it was built, and what the
  latest versions changed, newest first, each with a link to its pull
  request on GitHub. A dot on the link means there is something there you
  have not read yet; opening the page clears it.
- An administrator who does not want the page turns it off when deploying,
  or in the configuration wizard:

  ```sh
  sh toolchain/deploy-local.sh --server --no-whats-new
  # and to show it again:
  sh toolchain/deploy-local.sh --server --whats-new
  ```

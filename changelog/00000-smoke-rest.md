---
pr: 0
title: The smoke tests wait for what the browser does late
technical: true
---

## Other changes

- The server's smoke test now waits for two events the browser sends a
  moment after the action that causes them, as the demo's already did:
  the close of the user dialog after Escape, and the history's step back
  from the editor's preview of interactive SVGs. Before, a test could read
  the page before the wiki had heard of them, and fail on a slow machine.
- The README has one section on the smoke tests: the suites, how to run
  each, the variables they read, the weekly run on a slowed-down
  processor, the rules they are written by, and why the few node scripts
  left are still in node:

  ```sh
  sh toolchain/smoke-suite.sh server
  HALOGEN_PLAYWRIGHT_THROTTLE=4 sh toolchain/smoke-suite.sh server
  ```

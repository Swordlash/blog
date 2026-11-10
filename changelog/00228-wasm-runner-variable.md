---
pr: 228
title: CI can send its browser build to GitHub's machines with one setting
---

## Other changes

- The owner can now send the browser build of every pull request and every
  change to the main branch to GitHub's own machines with one repository
  variable, `WASM_RUNNER` set to `hosted`, without changing any code, for the
  times when the owner's machine is busy with other work and would build more
  slowly. Nothing changes in the wiki itself.

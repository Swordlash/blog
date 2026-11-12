---
pr: 153
title: Faster builds in CI
technical: true
---

## Other changes

- The continuous integration keeps one copy of each build cache per
  branch, and restores it whatever changed, so a pull request whose build
  runs on GitHub's machines no longer compiles every dependency from
  nothing. Nothing changes in the wiki itself.

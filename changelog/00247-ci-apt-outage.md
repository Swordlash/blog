---
pr: 247
title: CI installs its system packages without the mirror when it can
technical: true
---

## Other changes

- The continuous integration installs the system packages its tests need
  from the copies it keeps, without asking GitHub's Ubuntu mirror anything,
  when those copies are the versions it needs, so a pull request no longer
  fails when the mirror cannot be reached; when they are not, it still does.

---
pr: 0
title: CI installs its system packages from its cache when the mirror fails
---

## Other changes

- When GitHub's machines cannot reach the Ubuntu mirror, the continuous
  integration installs the system packages its tests need from the copies it
  keeps, when it has them, instead of failing every pull request.

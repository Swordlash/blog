---
pr: 221
title: The server's checks on PostgreSQL run faster
technical: true
---

## Other changes

- The server's tests on PostgreSQL no longer build the wiki's database
  from nothing for each test: they copy one that is already set up. CI
  finishes sooner, so a change reaches the wiki sooner.

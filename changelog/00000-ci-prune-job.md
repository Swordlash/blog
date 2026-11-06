---
pr: 0
title: CI keeps its cabal store for every job of a run
---

## Other changes

The pull request checks no longer build every Haskell dependency from
scratch in one of their jobs. The job that saves the cabal store used to
delete the previous copy right after saving the new one, while another
job could still be looking it up; that job then found no store at all.
The older copies are now deleted by a job of their own, which runs once
every other job has ended.

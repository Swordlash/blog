---
pr: 278
title: The smoke tests run one after another again, in their own CI job
technical: true
---

## Other changes

- CI's smoke job runs the smoke suites one after another again, as before
  the last change, rather than side by side, where each ran about twice
  as slow and two of them failed by chance. The job stays beside the wasm
  tests, so the run still takes about a quarter of an hour.
- `npm run smoke-test` runs its suites one after another too; on a machine
  with cores to spare, several can run side by side:

  ```sh
  WIKI_SMOKE_JOBS=3 npm run smoke-test
  ```

- The time budget of each test suite in CI's summary is now set from the
  hosted runs; a suite over its budget still only warns.

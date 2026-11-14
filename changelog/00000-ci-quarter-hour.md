---
pr: 0
title: CI's run takes a quarter of an hour again, and says which tests take the time
technical: true
---

## Other changes

- The smoke tests run in a CI job of their own, beside the wasm tests
  rather than after them, and side by side rather than one after another.
  The run had grown from 13 to 27 minutes in two days.
- `npm run smoke-test` runs its suites side by side too, from programs it
  builds once:

  ```sh
  npm run smoke-test
  WIKI_SMOKE_EXTRA="waits screenshots" npm run smoke-test
  ```

- The wasm run of wiki-core's tests runs a quarter of each property's
  cases; the native run keeps the full count. The test of the cost of
  deeply nested HTML times smaller inputs.
- Each CI run's summary lists every wasm and smoke test suite with its
  time, its budget and its five slowest examples, and warns of a suite
  over its budget.

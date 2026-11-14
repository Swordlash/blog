---
pr: 285
title: The browser tests wait for the program after every action, as the smoke tests do
technical: true
---

## Other changes

- The browser tests' harness, haskell-halogen's, now waits after every
  click or key until the program has done what it set off, and waits for
  the program to be quiet with its own `waitQuiet`. The tests' own waits
  use it, and the tests whose actions keep the program busy for longer
  (changing the reader on the Markdown guide, loading it over HTTP) say
  how long they wait, with what was measured.
- The smoke tests again fail on a console error about a script blocked in
  a sandboxed frame: the driver no longer causes one.

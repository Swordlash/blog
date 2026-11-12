---
pr: 175
title: The deploy's builds run in the maker
technical: true
---

## Other changes

More of `sh toolchain/deploy-local.sh` now runs in the maker: building the
page and wiki-server, checking what was built, choosing the Node that
serves the demo, finding out whether HTTPS can be served through
Tailscale, checking that the ports are free, moving an old deployment's
state under `--prefix`, and starting PostgreSQL. What it prints and does
is the same.

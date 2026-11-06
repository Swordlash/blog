---
pr: 0
title: The demo's deploy goes through the maker too
---

## Other changes

`sh toolchain/deploy-local.sh --static --backend-only`, which serves the
demo's page CI built, now installs GHC and cabal besides Node, with the new

    sh toolchain/bootstrap.sh static

so that the maker does the last part of this deploy as it does for every
other. It still compiles nothing of the wiki; the maker is built once.

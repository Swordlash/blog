---
pr: 0
title: CI checks the oldest supported GHC
---

## New features

The wiki's native build is now checked with GHC 9.10, the oldest version a
deploy with `--system-tools` accepts, on every change, and with GHC 9.12
every week. A machine whose GHC comes from its administrators can rely on
it:

```sh
sh toolchain/deploy-local.sh --system-tools --backend-only
```

## Other changes

CI keeps two cabal stores instead of one per compiler, and a workflow run by
hand deletes one when it grows too large.

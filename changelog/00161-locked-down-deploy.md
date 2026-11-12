---
pr: 161
title: A deploy for a locked-down machine
technical: true
---

## New features

A server that may install nothing from the internet can now be deployed. With
`--system-tools` the deploy uses the machine's own GHC, cabal and Node and
downloads no compilers; it checks them before anything else and names any that
is missing or too old. `--npm-registry` and `--hackage-mirror` name the
company's mirrors for npm's and Hackage's packages; the Hackage mirror goes into
the deployment's own cabal configuration, never into `~/.cabal`.
`--bundle-locally` builds the page's JavaScript and CSS on the machine and
compares them, file by file, with the page CI built, and `--app-page` takes that
page from a file for a machine that cannot reach GitHub. All of them are on the
configuration wizard's screens and remembered for the next deploy.

```sh
sh toolchain/deploy-local.sh --server --sqlite --prefix /srv/wiki \
  --system-tools \
  --npm-registry https://npm.example.org/ \
  --hackage-mirror https://hackage.example.org/ \
  --backend-only=main --bundle-locally
```

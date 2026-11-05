---
pr: 0
title: The toolchain's second stage in Haskell
---

## New features

The bootstrap now hands over to a program of its own once GHC and cabal are
installed: the maker, written in Haskell on Shake, installs the rest of the
toolchain and warms the cabal store, with the same messages as before. It
also tells you where each part of the toolchain stands:

```sh
sh toolchain/maker.sh status
sh toolchain/maker.sh tui
```

## Other changes

The pinned versions of the toolchain are now in one file,
`toolchain/pins.env`, which the bootstrap, the maker and the deploy read.
The first run of `sh toolchain/bootstrap.sh` after this change builds the
maker once, which takes a few minutes.

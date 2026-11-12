---
pr: 172
title: Installing for the server goes through the maker too
technical: true
---

## Other changes

`sh toolchain/bootstrap.sh native`, which a server deploy runs to install
GHC and cabal, now builds the maker after them and lets it do the rest, as
the other modes already did. The shell script installs only what GHC
itself needs (on Debian `build-essential curl libgmp-dev xz-utils`); the
maker installs the packages of the C libraries the server links (libpq,
libsodium, zlib) and checks them. The same check can be run by hand:

    sh toolchain/maker.sh check native --without-postgres

It prints the same lines as `toolchain/check-native.sh`, which a deploy
still runs first.

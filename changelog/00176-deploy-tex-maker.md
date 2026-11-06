---
pr: 176
title: The deploy's TeX step runs in the maker
---

## Other changes

The step of `sh toolchain/deploy-local.sh --server` that checks whether the
server can make PDFs, and offers to install TeX Live (with a Perl built
first when the machine has none that works) under the toolchain
directory, now runs in the maker. What it asks, prints and installs is
the same:

    sh toolchain/deploy-local.sh --server --texlive

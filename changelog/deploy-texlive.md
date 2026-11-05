---
pr: 150
title: The deploy installs a TeX that works
---

## New features

- `toolchain/deploy-local.sh --server` checks the TeX that makes the PDF
  exports, as the service will find it, before it builds. When there is
  none, or it fails, the deploy offers to install TeX Live under the
  toolchain directory (about 250 MB, a few minutes). `--texlive` installs
  it without asking, `--no-texlive` never does, and the answer is
  remembered for the next deploy:

  ```sh
  sh toolchain/deploy-local.sh --server --texlive
  # or from another CTAN mirror:
  sh toolchain/deploy-local.sh --server --texlive --texlive-mirror https://ctan.example.org
  ```

- `toolchain/check-tex.sh` runs the same check by hand, and says whether
  the engine works:

  ```sh
  sh toolchain/check-tex.sh /usr/bin/xelatex
  ```

- The configuration wizard (`sh toolchain/configure.sh`) asks about the
  TeX on its database screen.

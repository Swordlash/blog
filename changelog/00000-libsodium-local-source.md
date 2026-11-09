---
pr: 0
title: libsodium's source from a file, for a deploy that downloads nothing
---

## New features

- A deploy on a machine that installs nothing from the internet can now be
  given libsodium's release tarball as a file. Until now the toolchain
  downloaded it even with `--system-tools`, since it always builds the
  pinned release from source. Copy `libsodium-1.0.22.tar.gz` onto the
  machine and name it:

  ```sh
  sh toolchain/deploy-local.sh --server --sqlite --prefix /srv/wiki \
    --system-tools --backend-only=main \
    --libsodium-source /srv/incoming/libsodium-1.0.22.tar.gz
  ```

  The file is checked against the same pinned checksum as a download, and
  a file with another checksum stops the deploy before anything is built.
  It is needed only once: later deploys reuse the libsodium already built.
  The configuration wizard has a field for it, `toolchain/configure.sh`
  takes the same option, and the bootstrap takes it as
  `--libsodium-source=FILE` in its `native` and `build` modes.

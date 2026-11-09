---
pr: 0
title: The server carries its own libsodium
---

## Other changes

- The server no longer needs libsodium from the machine. The toolchain now
  builds one pinned release of libsodium (1.0.22) from source, checks the
  download against a fixed checksum, and links it into `wiki-server`. A
  deploy no longer asks for `libsodium-dev`, and the server runs without
  `libsodium23`; the Docker image no longer installs it either. The first
  run of the bootstrap after this change spends under a minute building it.
  `toolchain/check-native.sh` now reports libsodium as built by the
  bootstrap and does not count it:

      --       libsodium   not needed from the system: the bootstrap builds libsodium 1.0.22 from source (toolchain/libsodium.sh; not counted)

- Passwords are checked with libsodium's own HKDF rather than a copy of it
  written in Haskell, now that every build has a libsodium recent enough to
  have one. Nothing changes for anyone signing in.

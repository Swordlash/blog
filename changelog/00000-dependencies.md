---
pr: 0
title: The server runs on the system's SQLite and newer HTTP and TLS libraries
technical: true
---

## Other changes

- The server now uses the machine's own SQLite library instead of a copy built
  into it, which dated from January 2024. The machine that builds `wiki-server`
  needs SQLite's development files, and the one that runs it the library,
  version 3.32.0 or later:

  ```sh
  sudo apt-get install libsqlite3-dev    # Debian, Ubuntu
  sudo dnf install sqlite-devel          # RHEL, Fedora
  ```

  The bootstrap installs the package on Debian and Ubuntu, and
  `toolchain/check-native.sh` names it when it is missing. The server says
  which SQLite it runs on when it starts (`event=sqlite version=3.45.1` in its
  log) and in the first line of `wiki-server check`, and a wiki in SQLite does
  not start on an older one, saying why. The Docker image installs the
  library itself.
- The server's HTTP and TLS libraries are newer, with their security fixes. A
  request over HTTP/1.1 without a `Host` header, or any request with two, is
  now answered `400 Bad Request`. Browsers, `curl` and the deploy's checks
  always send one; a probe or proxy of your own that writes raw HTTP must too.
- SHA-256 is computed by another library. The digests are the same, so stored
  attachments, sessions and keys are found as before.

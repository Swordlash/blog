---
pr: 0
title: The deploy checks the SQLite library the server will load
technical: true
---

## Other changes

- `toolchain/check-native.sh` and `maker check native` now run a small
  program built with `sqlite3.h` and `-lsqlite3`, and judge the library it
  loads as the server does: its version (3.32.0 or later) and how it was
  built. The line names the library's file, and the header's version when
  the two differ, since the build and the run then find SQLite in different
  places:

  ```text
  missing  SQLite      sqlite3.h is 3.53.2 and the library a program built with -lsqlite3 loads is 3.26.0 (/usr/lib64/libsqlite3.so.0): wiki-server needs SQLite 3.32.0 or later
  ```

- Before it stops the running server, and with `--no-rehearsal` too, the
  deploy asks the new server which SQLite it loads in the service's own
  environment, not the shell's. A server that cannot find the library there,
  or that refuses it for a wiki in SQLite, stops the deploy with the running
  wiki untouched. The same answer is a command of its own, which opens no
  wiki:

  ```sh
  wiki-server sqlite
  ```

- The deploy copies the shell's `LD_LIBRARY_PATH` into the service's unit at
  each deploy. A machine with a SQLite of its own beside the distribution's
  runs every deploy with it, or puts the library's directory on the loader's
  own path (`/etc/ld.so.conf.d`, then `sudo ldconfig`).

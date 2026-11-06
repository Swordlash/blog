---
pr: 0
title: wiki-server migrate and wiki-server check
---

## New features

Two commands of the server, for the operator, which a later deploy runs
before it starts a new version. `wiki-server migrate` brings the
database to the program's version and does nothing else; `wiki-server
check` reads the whole wiki as the program does, changes nothing, and
says which table or record does not read:

```text
$ wiki-server check --data ~/wiki/data
users: 12 rows
...
Every table and every record read.
```

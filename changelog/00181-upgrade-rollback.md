---
pr: 0
title: Upgrades that check the database, and go back when it fails
---

## New features

A deploy over a running server now checks the upgrade before it serves
it. After the backup, the new server migrates the database and reads the
whole wiki back. If either fails, or the new server does not answer, the
deploy goes back to the version before by itself: the database comes back
from the backup, the old program and page come back, and the deploy says
which commit to check out until the cause is fixed:

```text
deploy-local: the migrated database does not read back (wiki-server check, above): rolled back to the previous deployment, of commit 3f2a…, its database restored from ~/wiki-demo/data/backups/20261106T101500Z.sqlite. Deploy that commit again (git checkout 3f2a…) until the cause is fixed
```

The version before is kept after a successful upgrade too, in
`~/wiki-demo/previous/`, in case something goes wrong only later. Going
back by hand asks first, because what was written since the upgrade is
lost:

```sh
sh toolchain/deploy-local.sh --rollback
```

Each deployment now records the commit it was built from, and `--status`
says it, and which deployment `--rollback` would go back to.

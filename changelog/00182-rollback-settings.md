---
pr: 182
title: Going back after an upgrade that changed the port
technical: true
---

## New features

An upgrade that moves the wiki to another port, or moves PostgreSQL to
another port, can now be undone too. Going back puts `tailscale serve`
and the firewall rule back on the old port, moves PostgreSQL back to
its old port, and restores the database there. Before, such an upgrade
kept nothing to go back to.

```sh
sh toolchain/deploy-local.sh --port 8090      # the upgrade moves the wiki
sh toolchain/deploy-local.sh --rollback       # back on the old port, as it was
```

Going back also leaves the wiki as it found it: a wiki taken down with
`--stop` before the upgrade stays stopped, and loses the unit the
upgrade wrote.

---
pr: 173
title: The deploy's last steps run in the maker
---

## Other changes

`sh toolchain/deploy-local.sh` now hands the steps that change the running
wiki (the backup, copying the files, the systemd unit, the restart, the
checks that it answers, `tailscale serve`, the firewall and the summary at
the end) to the maker, the toolchain's program in Haskell. What it prints
and does is the same. A deploy that builds the server or the page builds
the maker first if it is not there yet; that takes a minute, once.

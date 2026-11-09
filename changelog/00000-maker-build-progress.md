---
pr: 0
title: The deploy shows the maker's build as it goes
---

## Other changes

The first deploy on a machine builds the maker, the program that does the
rest of the deploy, with its libraries. That took minutes with nothing on
the screen. The deploy now shows cabal's progress as it builds them, as it
already did for the wiki's own build:

```sh
sh toolchain/deploy-local.sh   # "Building library for …", then the maker's modules
```
